# Wall-clock dependency injected into anything that needs to enforce a
# deadline. Tests substitute a FakeClock that lets them advance `now`
# manually so timeout-driven code paths run without real waiting.

class Clock
  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def sleep(seconds)
    Kernel.sleep(seconds)
  end
end
