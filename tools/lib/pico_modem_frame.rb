# Value object for one PicoModem frame: command byte + payload bytes.
# Knows how to encode itself onto the wire (`to_s`) and how to parse the
# next frame off the head of a byte buffer (`read_from_buffer!`).

class PicoModemFrame
  STX = 0x02
  ACK = 0x06

  FILE_READ  = 0x01
  FILE_WRITE = 0x02
  CHUNK      = 0x04
  ABORT      = 0xFF

  FILE_DATA = 0x81
  FILE_ACK  = 0x82
  CHUNK_ACK = 0x84
  DONE_ACK  = 0x8F
  ERROR     = 0xFE

  OK    = 0x00
  READY = 0x01
  FAIL  = 0xFF

  ProtocolError    = Class.new(StandardError)
  CrcMismatchError = Class.new(ProtocolError)

  attr_reader :cmd, :payload

  class << self
    # ── Outgoing factories (host → device) ──────────────────────────────

    def file_write(path:, size:)
      new(FILE_WRITE, [size].pack('N') + path.b)
    end

    def file_read(path:)
      new(FILE_READ, path.b)
    end

    def chunk(data)
      new(CHUNK, data.b)
    end

    def abort
      new(ABORT)
    end

    # ── Outgoing factories (device → host) ──────────────────────────────

    def file_data(data, total: nil)
      payload = total ? [total].pack('N') + data.b : data.b
      new(FILE_DATA, payload)
    end

    def file_ack(status: READY)
      new(FILE_ACK, [status].pack('C'))
    end

    def chunk_ack(status: OK)
      new(CHUNK_ACK, [status].pack('C'))
    end

    def done_ack(crc32:, status: OK)
      new(DONE_ACK, [status, crc32].pack('CN'))
    end

    def error(message)
      new(ERROR, message.to_s.b)
    end

    # ── Parsing ─────────────────────────────────────────────────────────

    # Read and parse one frame from `serial`. `serial` must provide
    # `read(n)` that blocks until exactly n bytes are returned (each side
    # handles its own waiting strategy — sleep on real serial, Fiber
    # yield on the test-side device). Bytes are consumed as they are
    # read; on protocol failure the bytes consumed so far are gone.
    # Raises ProtocolError if the first byte isn't STX, or
    # CrcMismatchError if the CRC-16 didn't match.
    def read_from_serial!(serial)
      stx = serial.read(1)
      raise ProtocolError, 'frame must start with STX' unless stx.getbyte(0) == STX

      body_len = serial.read(2).unpack1('n')
      rest = serial.read(body_len + 2)
      body = rest.byteslice(0, body_len)
      recv_crc = rest.byteslice(body_len, 2).unpack1('n')

      raise CrcMismatchError, 'crc16 mismatch' if crc16(body) != recv_crc

      new(body.getbyte(0), body.byteslice(1..) || ''.b)
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

  def initialize(cmd, payload = ''.b)
    @cmd = cmd
    @payload = payload.b
  end

  # Wire-format bytes of this frame: STX + len(2 BE) + cmd + payload + crc16(2 BE).
  def to_s
    body = [@cmd].pack('C') + @payload
    [STX, body.bytesize].pack('Cn') + body + [self.class.crc16(body)].pack('n')
  end
end
