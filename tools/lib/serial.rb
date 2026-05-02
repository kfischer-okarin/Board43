require 'serialport'

# Thin wrapper around the `serialport` gem exposing the three-method
# interface the rest of the CLI talks to: write / read_some / close.

class Serial
  Closed = Class.new(IOError)

  # Open the serial port at `path` and configure it for the firmware's
  # 115200 8N1 link with no flow control. Reads are non-blocking.
  def initialize(path)
    @sp = SerialPort.new(path, 115200, 8, 1, SerialPort::NONE)
    @sp.read_timeout = 0
    @sp.flow_control = SerialPort::NONE
    @closed = false
  end

  # Write all bytes to the line. Returns the number of bytes written.
  # Raises Closed if the serial has been closed.
  def write(bytes)
    raise Closed, 'closed serial' if @closed

    @sp.write(bytes)
    bytes.bytesize
  end

  # Return up to `max` bytes that have arrived from the device, or '' if
  # nothing is available right now. Read-and-gone: returned bytes are
  # consumed from the buffer and won't appear on subsequent reads.
  # Raises Closed if the serial has been closed.
  def read_some(max = 4096)
    raise Closed, 'closed serial' if @closed

    @sp.read_nonblock(max).b
  rescue IO::WaitReadable, EOFError
    ''.b
  end

  def close
    return if @closed

    @sp.close
    @closed = true
  end
end
