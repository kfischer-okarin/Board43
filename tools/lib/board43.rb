require 'zlib'

require_relative 'clock'
require_relative 'pico_modem_frame'

class Board43
  CHUNK_SIZE      = 512
  ACK_TIMEOUT_S   = 5.0
  POLL_INTERVAL_S = 0.001
  SHELL_IDLE_S    = 0.005
  RUN_PATH        = '/home/run.rb'
  PROMPT          = '$> '
  SHELL_EXIT_KEY  = 0x1d

  AckTimeout    = Class.new(StandardError)
  PromptTimeout = Class.new(StandardError)

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

  def run(local_path)
    upload(local_path, RUN_PATH)
    read_until_prompt
    @serial.write("#{RUN_PATH}\r")
  end

  def shell
    loop do
      drain_serial_to_stdout
      bytes = read_stdin_or_nil
      if bytes && !bytes.empty?
        if (idx = bytes.bytes.index(SHELL_EXIT_KEY))
          pre_exit = bytes.byteslice(0, idx)
          @serial.write(pre_exit) unless pre_exit.empty?
          drain_serial_to_stdout
          return
        end

        @serial.write(bytes)
        next
      end

      @clock.sleep(SHELL_IDLE_S)
    end
  end

  private

  def drain_serial_to_stdout
    bytes = @serial.read_nonblock(4096)
    return if bytes.empty?

    # Raw mode disables ONLCR, so bare \n from the device moves the
    # cursor down without returning to column 0. Translate to \r\n so
    # output renders correctly on a real terminal. (Doubling on \r\n
    # already in the stream is harmless.)
    @stdout.write(bytes.gsub("\n", "\r\n"))
  end

  def read_stdin_or_nil
    bytes = @stdin.read_nonblock(64, exception: false)
    bytes.is_a?(String) ? bytes : nil
  end

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

  def read_until_prompt
    deadline = @clock.now + ACK_TIMEOUT_S
    buf = ''.b
    until buf.end_with?(PROMPT)
      raise PromptTimeout, "no '#{PROMPT}' after #{ACK_TIMEOUT_S}s" if @clock.now > deadline

      buf << @serial.read_nonblock(64)
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
