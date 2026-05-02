require 'zlib'

# Test-side stand-in for a real Board43 board. Watches bytes the client
# writes, drives the PicoModem state machine, and produces high-level
# io_events the test asserts on.

class Device
  STX = 0x02
  ACK = 0x06
  FILE_WRITE = 0x02
  CHUNK = 0x04
  FILE_ACK = 0x82
  CHUNK_ACK = 0x84
  DONE_ACK = 0x8F
  OK = 0x00
  READY = 0x01

  attr_reader :io_events

  def initialize(serial)
    @serial = serial
    @serial.attach_device(self)
    @inbuf = ''.b
    @state = :shell
    @io_events = []
    @pending_write = nil
  end

  def feed(bytes)
    @inbuf << bytes.b
    process
  end

  private

  def process
    loop do
      case @state
      when :shell  then break unless handle_shell
      when :modem  then break unless handle_modem
      end
    end
  end

  def handle_shell
    return false if @inbuf.bytesize < 1
    @inbuf = @inbuf.byteslice(1..) || ''.b
    emit_bytes([ACK].pack('C'))
    @state = :modem
    true
  end

  def handle_modem
    frame = take_frame
    return false unless frame
    cmd, payload = frame
    case cmd
    when FILE_WRITE then handle_file_write(payload)
    when CHUNK      then handle_chunk(payload)
    end
    true
  end

  def handle_file_write(payload)
    size = payload.byteslice(0, 4).unpack1('N')
    path = (payload.byteslice(4..) || ''.b).force_encoding('UTF-8')
    @io_events << [:picomodem, 'FILE_WRITE', path, size]
    @pending_write = { size: size, data: ''.b }
    send_frame(FILE_ACK, [READY].pack('C'))
  end

  def handle_chunk(payload)
    @io_events << [:picomodem, 'CHUNK', payload.dup]
    @pending_write[:data] << payload
    send_frame(CHUNK_ACK, [OK].pack('C'))
    return if @pending_write[:data].bytesize < @pending_write[:size]
    finish_write
  end

  def finish_write
    send_frame(DONE_ACK, [OK, Zlib.crc32(@pending_write[:data])].pack('CN'))
    @io_events << [:picomodem, 'DONE']
    @pending_write = nil
    @state = :shell
  end

  def take_frame
    return nil if @inbuf.bytesize < 5
    body_len = (@inbuf.getbyte(1) << 8) | @inbuf.getbyte(2)
    return nil if @inbuf.bytesize < 3 + body_len + 2
    body = @inbuf.byteslice(3, body_len)
    @inbuf = @inbuf.byteslice(3 + body_len + 2..) || ''.b
    [body.getbyte(0), body.byteslice(1..) || ''.b]
  end

  def send_frame(cmd, payload = ''.b)
    body = [cmd].pack('C') + payload.b
    emit_bytes([STX, body.bytesize].pack('Cn') + body + [crc16(body)].pack('n'))
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
