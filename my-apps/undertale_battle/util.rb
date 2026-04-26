require 'eval'

# ================================================================
# MusicPlayer — byte-decoding monophonic song player
# ================================================================
#
# Song data is a packed byte stream with 4 bytes per event:
#   bytes 0-1: frequency Hz (little-endian, 0 = rest)
#   bytes 2-3: duration ms  (little-endian)
# Articulation gaps between same-pitch repeats are baked in already,
# so #tick does no parsing and no table lookups.
#
# Callers pass a pre-converted Array<Integer> (obtained once at boot
# via `SOME_SONG_DATA.bytes`). The player never allocates during
# playback or track switching — `#play` just swaps the reference.
#
#   player = MusicPlayer.new(buzzer)
#   player.play(SONGS[:megalovania])
#   loop do
#     player.tick(dt)
#     # ... draw your frame ...
#   end
class MusicPlayer
  def initialize(buzzer)
    @buzzer    = buzzer
    @bytes     = nil
    @count     = 0
    @cursor    = 0
    @remaining = 0
  end

  # Swap to a different song. `song_bytes` is a pre-converted int
  # array; no allocation happens here. Safe to call mid-playback.
  def play(song_bytes)
    @bytes     = song_bytes
    @count     = song_bytes.length / 4
    @cursor    = 0
    @remaining = 0
  end

  # Advance playback by elapsed_ms. Common-case cost: one subtract +
  # one compare. Uses a while loop so multiple short events that fit
  # inside a single tick don't get dropped.
  def tick(elapsed_ms)
    return unless @bytes
    @remaining -= elapsed_ms
    while @remaining <= 0
      i = @cursor * 4
      freq = @bytes[i] | (@bytes[i + 1] << 8)
      dur  = @bytes[i + 2] | (@bytes[i + 3] << 8)
      @buzzer.frequency(freq)
      @remaining += dur
      @cursor += 1
      @cursor = 0 if @cursor >= @count
    end
  end

  def stop
    @buzzer.frequency(0)
  end
end

# ================================================================
# ThrottledTrigger — periodic firing while a condition holds
# ================================================================
#
# Generic helper: while the caller signals `active`, the trigger
# fires once every `interval_ms` and #tick returns the number of
# fires that completed this frame (usually 0 or 1, but multiple
# can coalesce on a long dt). When `active` flips false the
# accumulator resets, so brief brushes don't add up across
# separate activations.
#
# This is a building block; it deliberately knows nothing about
# the domain. The MainScene wires one up as `@damage_trigger` to
# convert "heart is touching white" into "1 HP per 250 ms", but
# the same primitive could drive a shot cooldown, an animation
# step, a heat-tick, etc.
#
#   t = ThrottledTrigger.new(250)
#   loop do
#     hp -= t.tick(dt, heart_touching_white?)
#   end
class ThrottledTrigger
  def initialize(interval_ms)
    @interval = interval_ms
    @timer    = 0
  end

  def tick(elapsed_ms, active)
    if active
      @timer += elapsed_ms
      n = 0
      while @timer >= @interval
        @timer -= @interval
        n += 1
      end
      n
    else
      @timer = 0
      0
    end
  end
end

# ================================================================
# LiveRepl — dev REPL over USB CDC, ticks once per frame
# ================================================================
#
# Connect a serial terminal (the playground console, `tio`, or
# `screen /dev/cu.usbmodem*`) and type a line of Ruby + Enter.
# Lines run via Kernel#eval, which on mruby/c spawns the snippet
# in a fresh task and returns nil immediately. We side-channel
# the value (or rescued exception) back through globals and spin
# on a `done` flag until the spawned task completes.
#
# Caveat: a snippet that loops forever will hang the game; the
# eval task is created with preemption disabled, so there's no
# way to interrupt it from here.
class LiveRepl
  def initialize
    @buf = ''
    puts '[live-repl ready]'
  end

  def tick
    chunk = STDIN.read_nonblock(64)
    return if chunk.nil? || chunk.empty?
    # Echo + edit per character: app runs without a tty echoing
    # for it, so we mirror typed bytes back over the same USB CDC
    # and intercept BS/DEL so they actually erase from @buf.
    i = 0
    len = chunk.length
    while i < len
      handle_char(chunk[i])
      i += 1
    end
    # Same line-splitting shape as upstream picoruby-shell/pipeline.rb:
    # take 0..idx, then re-bind @buf to the tail. PicoRuby's String
    # has these range slices but not `slice!`.
    while (idx = @buf.index("\n"))
      line = (@buf[0..idx] || '').chomp.strip
      @buf = @buf[(idx + 1)..-1] || ''
      eval_line(line) unless line.empty?
    end
  rescue => e
    puts "!! repl(tick): #{e.message} (#{e.class})"
  end

  private

  # macOS Terminal sends DEL (0x7f) on backspace; some terminals
  # send BS (0x08) — handle both. "\b \b" wipes the cell visually
  # (move left, overwrite with space, move left again).
  def handle_char(c)
    case c
    when "\b", "\x7f"
      return if @buf.empty?
      @buf = @buf[0..-2] || ''
      print "\b \b"
    when "\r", "\n"
      @buf << "\n"
      print "\n"
    else
      @buf << c
      print c
    end
  end

  # Kernel#eval on mruby/c discards the spawned task's return
  # value, so we wrap the user line so its result (or rescued
  # exception) lands in $_repl_result, and flip $_repl_done last
  # to signal the main task it can read.
  def eval_line(line)
    $_repl_result = nil
    $_repl_done = false
    eval("begin; $_repl_result = (#{line}); rescue => __e; $_repl_result = __e; end; $_repl_done = true")
    sleep_ms 5 until $_repl_done
    r = $_repl_result
    if r.is_a?(Exception)
      puts "!! #{r.message} (#{r.class})"
    else
      puts "=> #{r.inspect}"
    end
  rescue SyntaxError, StandardError => e
    # SyntaxError raised inline by Kernel#eval is a sibling of
    # StandardError, not a child, so it slips past a bare `rescue`.
    puts "!! repl(eval): #{e.message} (#{e.class})"
  end
end
