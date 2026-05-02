# Test-only stand-in for Serial. Inherits `read` (the blocking
# poll-loop) and `Closed` from the real thing; overrides everything that
# touches a real serial port to talk to a FakeDevice instead.

class FakeSerial < Serial
  def initialize(device)
    @device = device
    @closed = false
  end

  def write(bytes)
    raise Closed, 'closed serial' if @closed

    @device.feed(bytes.b)
    bytes.bytesize
  end

  def read_nonblock(max)
    raise Closed, 'closed serial' if @closed

    @device.consume_outgoing(max)
  end

  def close
    @closed = true
  end
end
