# Test-only stand-in for the real Serial wrapper. Wires a FakeDevice in
# as the other end of the line: each `write` is fed straight into the
# device, and `read_some` drains whatever the device has produced.

class FakeSerial
  Closed = Serial::Closed

  def initialize(device)
    @device = device
    @closed = false
  end

  # Write all bytes to the line. Returns the number of bytes written.
  # Raises Closed if the serial has been closed.
  def write(bytes)
    raise Closed, 'closed serial' if @closed

    @device.feed(bytes.b)
    bytes.bytesize
  end

  # Return up to `max` bytes that have arrived from the device, or '' if
  # nothing is available right now. Read-and-gone: returned bytes are
  # consumed from the buffer and won't appear on subsequent reads.
  # Raises Closed if the serial has been closed.
  def read_some(max = 4096)
    raise Closed, 'closed serial' if @closed

    @device.consume_outgoing(max)
  end

  def close
    @closed = true
  end
end
