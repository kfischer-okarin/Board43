require 'zlib'

require_relative 'clock'
require_relative 'pico_modem_frame'

class Board43
  CHUNK_SIZE      = 512
  ACK_TIMEOUT_S   = 5.0
  POLL_INTERVAL_S = 0.001

  AckTimeout = Class.new(StandardError)

  def initialize(serial:, stdin:, stdout:, logger_io:, clock: Clock.new)
    @serial = serial
    @stdin = stdin
    @stdout = stdout
    @logger_io = logger_io
    @clock = clock
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
    send_chunks(data)
    read_frame
  end

  def send_chunks(data)
    offset = 0
    while offset < data.bytesize
      chunk = data.byteslice(offset, [CHUNK_SIZE, data.bytesize - offset].min)
      send_frame(PicoModemFrame.chunk(chunk))
      read_frame
      offset += chunk.bytesize
    end
  end

  def handshake
    @serial.write([PicoModemFrame::STX].pack('C'))
    read_until_ack
  end

  def read_until_ack
    deadline = @clock.now + ACK_TIMEOUT_S
    loop do
      raise AckTimeout, "no ACK after #{ACK_TIMEOUT_S}s" if @clock.now > deadline

      bytes = @serial.read_nonblock(64)
      return if bytes.bytes.include?(PicoModemFrame::ACK)

      @clock.sleep(POLL_INTERVAL_S)
    end
  end

  def send_frame(frame)
    @serial.write(frame.to_s)
  end

  def read_frame
    PicoModemFrame.read_from_serial!(@serial)
  end
end
