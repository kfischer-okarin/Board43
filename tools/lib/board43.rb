require 'zlib'

require_relative 'pico_modem_frame'

class Board43
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
    send_frame(PicoModemFrame.file_write(path: remote_path, size: data.bytesize))
    read_frame
    send_frame(PicoModemFrame.chunk(data))
    read_frame
    read_frame
  end

  def handshake
    @serial.write([PicoModemFrame::STX].pack('C'))
    read_until_ack
  end

  def read_until_ack
    loop do
      return if @serial.read(1).getbyte(0) == PicoModemFrame::ACK
    end
  end

  def send_frame(frame)
    @serial.write(frame.to_s)
  end

  def read_frame
    PicoModemFrame.read_from_serial!(@serial)
  end
end
