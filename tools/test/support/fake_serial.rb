# In-memory bidirectional byte queue. The client side exposes the same
# write/read_some/close interface the real Serial wrapper does. The Device
# attaches itself as the other end and processes bytes synchronously
# whenever the client writes.

class FakeSerial
  def initialize
    @from_device = ''.b
    @device = nil
  end

  def attach_device(device)
    @device = device
  end

  def write(bytes)
    @device.feed(bytes.b)
    bytes.bytesize
  end

  def read_some(max = 4096)
    n = [max, @from_device.bytesize].min
    out = @from_device.byteslice(0, n)
    @from_device = @from_device.byteslice(n..) || ''.b
    out
  end

  def from_device(bytes)
    @from_device << bytes.b
  end

  def close; end
end
