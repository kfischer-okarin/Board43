require 'zlib'

class Board43
  STX = 0x02
  ACK = 0x06
  FILE_WRITE = 0x02
  CHUNK = 0x04

  def initialize(serial:, stdin:, stdout:, logger_io:)
    @serial = serial
    @stdin = stdin
    @stdout = stdout
    @logger_io = logger_io
  end

  def push(local_paths)
    local_paths.each { |path| upload(path, "/home/#{File.basename(path)}") }
  end

  private

  def upload(local_path, remote_path)
    data = File.binread(local_path)
    handshake
    file_write(remote_path, data)
    send_chunk(data)
    read_frame
  end

  def handshake
    @serial.write([STX].pack('C'))
    read_until_ack
  end

  def file_write(remote_path, data)
    header = [data.bytesize].pack('N') + remote_path.b
    send_frame(FILE_WRITE, header)
    read_frame
  end

  def send_chunk(data)
    send_frame(CHUNK, data)
    read_frame
  end

  def read_until_ack
    loop do
      bytes = @serial.read_some(64)
      return if bytes.bytes.include?(ACK)
    end
  end

  def send_frame(cmd, payload)
    body = [cmd].pack('C') + payload.b
    @serial.write([STX, body.bytesize].pack('Cn') + body + [crc16(body)].pack('n'))
  end

  def read_frame
    read_exact(1)
    body_len = read_exact(2).unpack1('n')
    rest = read_exact(body_len + 2)
    body = rest.byteslice(0, body_len)
    [body.getbyte(0), body.byteslice(1..) || ''.b]
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

  def read_exact(n)
    buf = ''.b
    buf << @serial.read_some(n - buf.bytesize) while buf.bytesize < n
    buf
  end
end
