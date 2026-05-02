# Test-only Clock that doesn't actually wait. `sleep(s)` advances `now`
# by s, so polling loops drive their deadline themselves and tests
# complete in zero real time.

class FakeClock
  attr_accessor :now

  def initialize(now: 0.0)
    @now = now
  end

  def sleep(seconds)
    @now += seconds
  end
end
