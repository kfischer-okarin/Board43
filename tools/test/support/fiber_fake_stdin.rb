# Test-side stand-in for $stdin during shell attach. read_nonblock yields
# the current Fiber while the buffer is empty — when the test running
# the shell pump in a Fiber sets new content via `string=` and resumes,
# the next read_nonblock returns the bytes.

class FiberFakeStdin
  def initialize
    @buffer = ''.b
  end

  def string=(s)
    @buffer = s.b.dup
  end

  def read_nonblock(maxlen, exception: false)
    Fiber.yield while @buffer.empty?

    n = [maxlen, @buffer.bytesize].min
    out = @buffer.byteslice(0, n)
    @buffer = @buffer.byteslice(n..) || ''.b
    out
  end
end
