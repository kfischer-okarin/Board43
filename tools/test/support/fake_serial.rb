# Test-only stand-in for the real Serial wrapper. Front side mirrors the
# production Serial interface; back side has helpers the Device uses to
# observe and respond to client traffic.

class FakeSerial
  Closed = Serial::Closed

  def initialize
    @from_device = ''.b
    @device = nil
    @closed = false
  end

  # ── Production interface (matches the real Serial wrapper) ────────────

  # Write all bytes to the line. Returns the number of bytes written.
  # Raises Closed if the serial has been closed.
  def write(bytes)
    raise Closed, 'closed serial' if @closed

    @device&.feed(bytes.b)
    bytes.bytesize
  end

  # Return up to `max` bytes that have arrived from the device, or '' if
  # nothing is available right now. Read-and-gone: returned bytes are
  # consumed from the buffer and won't appear on subsequent reads.
  # Raises Closed if the serial has been closed.
  def read_some(max = 4096)
    raise Closed, 'closed serial' if @closed

    n = [max, @from_device.bytesize].min
    out = @from_device.byteslice(0, n)
    @from_device = @from_device.byteslice(n..) || ''.b
    out
  end

  def close
    @closed = true
  end

  # ── Test helpers (used only by Device) ────────────────────────────────

  # Wire up the device that owns the other end of this serial line. With
  # no device attached, written bytes are silently dropped.
  def attach_device(device)
    @device = device
  end

  # Append bytes the device produced, to be read by the client via
  # `read_some`. Called by the Device while it processes a feed.
  def from_device(bytes)
    @from_device << bytes.b
  end
end
