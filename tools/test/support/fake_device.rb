require 'zlib'

# Test-side stand-in for a real Board43 board running R2P2. Faithfully
# implements the slice of behavior the CLI cares about:
#   * Shell-mode line input. Bytes typed at the prompt accumulate into a
#     line buffer; CR/LF "executes" it, surfacing a [:shell, :command, line]
#     io_event. We don't actually run shell commands.
#   * STX (Ctrl-B) intercept. Echoes "\n^B\n" + ACK and hands off to a
#     PicoModem session for one operation, then returns to shell mode.
#   * PicoModem session. Implements FILE_WRITE, FILE_READ, and ABORT
#     against an in-memory @filesystem hash.
#
# A FakeDevice is byte-in / byte-out: `feed(bytes)` consumes bytes the
# client wrote; `consume_outgoing(max)` drains bytes the device has
# produced for the client to read. The two are decoupled — the device may
# emit bytes the client hasn't read yet, just like a real serial line.
# FakeSerial wires these into write / read_nonblock.
#
# Why a Fiber: the device drives the protocol in a straight-line style
# (read STX, recv frame, loop on chunks…) but its only input is feed —
# bytes the client trickled over the line. The Fiber lets us write linear
# read code; whenever it asks for more bytes than have arrived, it yields
# and resumes on the next feed. Tests therefore can't deadlock waiting for
# "the device to do its part" — every byte the client writes synchronously
# advances the device as far as it can go, then yields.

class FakeDevice
  attr_reader :io_events, :filesystem

  def initialize
    @inbuf = ''.b
    @outbuf = ''.b
    @io_events = []
    @filesystem = {}
    @line_buffer = ''.b
    @fiber = Fiber.new { run }
    @fiber.resume
  end

  # Consume bytes the client wrote. Bytes the device produces in
  # response accumulate in the outgoing buffer; pull them with
  # `consume_outgoing`.
  def feed(bytes)
    @inbuf << bytes.b
    @fiber.resume if @fiber.alive?
  end

  # Return up to `max` bytes the device has produced, consuming them.
  def consume_outgoing(max)
    n = [max, @outbuf.bytesize].min
    out = @outbuf.byteslice(0, n)
    @outbuf = @outbuf.byteslice(n..) || ''.b
    out
  end

  # Block (via Fiber.yield) until exactly n bytes have been fed in, then
  # return them. PicoModemFrame.read_from_serial! uses this when this
  # device is the io.
  def read(n)
    buf = ''.b
    while buf.bytesize < n
      Fiber.yield while @inbuf.empty?

      take = [n - buf.bytesize, @inbuf.bytesize].min
      buf << @inbuf.byteslice(0, take)
      @inbuf = @inbuf.byteslice(take..) || ''.b
    end
    buf
  end

  private

  # ── Top-level loop ────────────────────────────────────────────────────

  def run
    loop do
      byte = read(1).getbyte(0)
      case byte
      when PicoModemFrame::STX then run_modem_intercept
      when 0x0D, 0x0A          then handle_line_ended
      else                          @line_buffer << byte
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
    emit_bytes([PicoModemFrame::ACK].pack('C'))
    info = run_modem_session
    emit_bytes("\n[PicoModem] #{info}\n$> ".b)
  end

  def run_modem_session
    frame = recv_frame
    return 'timeout' unless frame

    case frame.cmd
    when PicoModemFrame::FILE_WRITE then handle_file_write(frame.payload)
    when PicoModemFrame::FILE_READ  then handle_file_read(frame.payload)
    when PicoModemFrame::ABORT      then 'abort'
    else
      send_frame(PicoModemFrame.error('Unknown command'))
      'error'
    end
  end

  # ── FILE_WRITE ────────────────────────────────────────────────────────

  def handle_file_write(payload)
    if payload.bytesize < 5
      send_frame(PicoModemFrame.error('Invalid FILE_WRITE payload'))
      return 'error'
    end

    total = payload.byteslice(0, 4).unpack1('N')
    path = (payload.byteslice(4..) || ''.b).force_encoding('UTF-8')
    @io_events << [:picomodem, 'FILE_WRITE', path, total]
    send_frame(PicoModemFrame.file_ack)
    receive_chunks_for_write(path, total)
  end

  def receive_chunks_for_write(path, total)
    data = ''.b
    while data.bytesize < total
      frame = recv_frame
      unless frame
        send_frame(PicoModemFrame.error('Timeout receiving chunk'))
        return 'error'
      end

      case frame.cmd
      when PicoModemFrame::CHUNK
        @io_events << [:picomodem, 'CHUNK', frame.payload.dup]
        data << frame.payload
        send_frame(PicoModemFrame.chunk_ack)
      when PicoModemFrame::ABORT
        return 'abort'
      else
        send_frame(PicoModemFrame.error('Unexpected command during transfer'))
        return 'error'
      end
    end
    finalize_write(path, data)
  end

  def finalize_write(path, data)
    @filesystem[path] = data
    @io_events << [:picomodem, 'DONE']
    send_frame(PicoModemFrame.done_ack(crc32: Zlib.crc32(data)))
    "write #{path}"
  end

  # ── FILE_READ ─────────────────────────────────────────────────────────

  CHUNK_SIZE = 480

  def handle_file_read(payload)
    path = (payload || ''.b).force_encoding('UTF-8')
    unless @filesystem.key?(path)
      send_frame(PicoModemFrame.error("File not found: #{path}"))
      return 'error'
    end

    @io_events << [:picomodem, 'FILE_READ', path]
    data = @filesystem[path]
    return 'abort' unless stream_file_data(data)

    @io_events << [:picomodem, 'DONE']
    send_frame(PicoModemFrame.done_ack(crc32: Zlib.crc32(data)))
    "read #{path}"
  end

  def stream_file_data(data)
    offset = 0
    first = true
    while offset < data.bytesize
      chunk_size = [CHUNK_SIZE, data.bytesize - offset].min
      chunk = data.byteslice(offset, chunk_size)
      send_frame(PicoModemFrame.file_data(chunk, total: first ? data.bytesize : nil))
      first = false
      ack = recv_frame
      return false unless ack && ack.cmd == PicoModemFrame::CHUNK_ACK

      offset += chunk_size
    end
    true
  end

  # ── Frame I/O ─────────────────────────────────────────────────────────

  def recv_frame
    PicoModemFrame.read_from_serial!(self)
  rescue PicoModemFrame::ProtocolError
    nil
  end

  def send_frame(frame)
    emit_bytes(frame.to_s)
  end

  def emit_bytes(bytes)
    @outbuf << bytes.b
  end
end
