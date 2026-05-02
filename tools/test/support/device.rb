require 'zlib'

# Test-side stand-in for a real Board43 board running R2P2. Faithfully
# implements the slice of behavior the CLI cares about:
#   * Shell-mode line input. Bytes typed at the prompt accumulate into a
#     line buffer; CR/LF "executes" it, surfacing a [:shell, :command, line]
#     io_event. We don't actually run shell commands.
#   * STX (Ctrl-B) intercept. Echoes "\n^B\n" + ACK and hands off to a
#     PicoModem session for one operation, then returns to shell mode.
#   * PicoModem session. Implements FILE_WRITE, FILE_READ, and ABORT
#     against an in-memory @filesystem hash. Frame parsing matches
#     picoruby-picomodem (CRC-16/CCITT-FALSE, big-endian length).
#
# Why a Fiber: Device drives the protocol in a straight-line style
# (read STX, recv frame, loop on chunks…) but its only input is feed() —
# bytes the client trickled over the line. The Fiber lets us write linear
# read code; whenever it asks for more bytes than have arrived, it yields
# and resumes on the next feed. Tests therefore can't deadlock waiting for
# "the device to do its part" — every byte the client writes synchronously
# advances the device as far as it can go, then yields.

class Device
  STX        = 0x02
  ACK        = 0x06
  FILE_READ  = 0x01
  FILE_WRITE = 0x02
  CHUNK      = 0x04
  ABORT      = 0xFF
  FILE_DATA  = 0x81
  FILE_ACK   = 0x82
  CHUNK_ACK  = 0x84
  DONE_ACK   = 0x8F
  ERROR      = 0xFE
  OK         = 0x00
  READY      = 0x01

  CHUNK_SIZE = 480

  attr_reader :io_events, :filesystem

  def initialize(serial)
    @serial = serial
    @serial.attach_device(self)
    @inbuf = ''.b
    @io_events = []
    @filesystem = {}
    @line_buffer = ''.b
    @fiber = Fiber.new { run }
    @fiber.resume
  end

  def feed(bytes)
    @inbuf << bytes.b
    @fiber.resume if @fiber.alive?
  end

  private

  # ── Top-level loop ────────────────────────────────────────────────────

  def run
    loop do
      byte = read_exact(1).getbyte(0)
      case byte
      when STX        then run_modem_intercept
      when 0x0D, 0x0A then handle_line_ended
      else                 @line_buffer << byte
      end
    end
  end

  def handle_line_ended
    return if @line_buffer.empty?

    @io_events << [:shell, :command, @line_buffer.dup]
    @line_buffer = ''.b
  end

  def run_modem_intercept
    emit_bytes("\n^B\n".b)
    emit_bytes([ACK].pack('C'))
    info = run_modem_session
    emit_bytes("\n[PicoModem] #{info}\n$> ".b)
  end

  def run_modem_session
    frame = recv_frame
    return 'timeout' unless frame

    cmd, payload = frame
    case cmd
    when FILE_WRITE then handle_file_write(payload)
    when FILE_READ  then handle_file_read(payload)
    when ABORT      then 'abort'
    else
      send_frame(ERROR, 'Unknown command')
      'error'
    end
  end

  # ── FILE_WRITE ────────────────────────────────────────────────────────

  def handle_file_write(payload)
    if payload.bytesize < 5
      send_frame(ERROR, 'Invalid FILE_WRITE payload')
      return 'error'
    end

    total = payload.byteslice(0, 4).unpack1('N')
    path = (payload.byteslice(4..) || ''.b).force_encoding('UTF-8')
    @io_events << [:picomodem, 'FILE_WRITE', path, total]
    send_frame(FILE_ACK, [READY].pack('C'))
    receive_chunks_for_write(path, total)
  end

  def receive_chunks_for_write(path, total)
    data = ''.b
    while data.bytesize < total
      frame = recv_frame
      unless frame
        send_frame(ERROR, 'Timeout receiving chunk')
        return 'error'
      end

      cmd, payload = frame
      case cmd
      when CHUNK
        @io_events << [:picomodem, 'CHUNK', payload.dup]
        data << payload
        send_frame(CHUNK_ACK, [OK].pack('C'))
      when ABORT
        return 'abort'
      else
        send_frame(ERROR, 'Unexpected command during transfer')
        return 'error'
      end
    end
    finalize_write(path, data)
  end

  def finalize_write(path, data)
    @filesystem[path] = data
    @io_events << [:picomodem, 'DONE']
    send_frame(DONE_ACK, [OK, Zlib.crc32(data)].pack('CN'))
    "write #{path}"
  end

  # ── FILE_READ ─────────────────────────────────────────────────────────

  def handle_file_read(payload)
    path = (payload || ''.b).force_encoding('UTF-8')
    unless @filesystem.key?(path)
      send_frame(ERROR, "File not found: #{path}")
      return 'error'
    end

    @io_events << [:picomodem, 'FILE_READ', path]
    data = @filesystem[path]
    return 'abort' unless stream_file_data(data)

    @io_events << [:picomodem, 'DONE']
    send_frame(DONE_ACK, [OK, Zlib.crc32(data)].pack('CN'))
    "read #{path}"
  end

  def stream_file_data(data)
    offset = 0
    first = true
    while offset < data.bytesize
      chunk_size = [CHUNK_SIZE, data.bytesize - offset].min
      chunk = data.byteslice(offset, chunk_size)
      frame_payload = first ? [data.bytesize].pack('N') + chunk : chunk
      first = false
      send_frame(FILE_DATA, frame_payload)
      ack = recv_frame
      return false unless ack && ack[0] == CHUNK_ACK

      offset += chunk_size
    end
    true
  end

  # ── Frame I/O ─────────────────────────────────────────────────────────

  def recv_frame
    stx = read_exact(1)
    return nil unless stx.getbyte(0) == STX

    len = read_exact(2).unpack1('n')
    body_and_crc = read_exact(len + 2)
    body = body_and_crc.byteslice(0, len)
    recv_crc = body_and_crc.byteslice(len, 2).unpack1('n')
    return nil if crc16(body) != recv_crc

    [body.getbyte(0), body.byteslice(1..) || ''.b]
  end

  def send_frame(cmd, payload = ''.b)
    body = [cmd].pack('C') + payload.to_s.b
    emit_bytes([STX, body.bytesize].pack('Cn') + body + [crc16(body)].pack('n'))
  end

  # Block until @inbuf has n bytes, yielding to the client between feeds.
  def read_exact(n)
    Fiber.yield while @inbuf.bytesize < n
    out = @inbuf.byteslice(0, n)
    @inbuf = @inbuf.byteslice(n..) || ''.b
    out
  end

  def emit_bytes(bytes)
    @serial.from_device(bytes)
  end

  def crc16(data)
    crc = 0xFFFF
    data.each_byte do |b|
      crc ^= (b << 8)
      8.times do
        crc = (crc & 0x8000).zero? ? (crc << 1) : ((crc << 1) ^ 0x1021)
        crc &= 0xFFFF
      end
    end
    crc
  end
end
