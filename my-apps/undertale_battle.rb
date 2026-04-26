# Board43 App: Undertale Battle (v3)
#
# Dodge-box prototype: a red downward-triangle "SOUL" moves with the
# four buttons while a short melody loops on the piezo. Song data is
# pre-compiled to packed bytes by my-apps/songs/build.py; this file
# never parses note names at runtime.
#
#   SW3: Left
#   SW4: Up
#   SW5: Down
#   SW6: Right
#
# Features: Switches (GPIO) + WS2812 16x16 matrix + Buzzer (PWM)

require 'ws2812-plus'
require 'gpio'
require 'pwm'
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
# Hazards — self-managed game-world objects
# ================================================================
#
# Each hazard object owns its lifecycle and presentation:
#
#   #tick(dt)         — advance internal state by `dt` ms
#   #finished?        — true once it should be removed from the scene
#   #render(led)      — paint non-damaging visuals (e.g. an outline);
#                       no-op for hazards that have nothing visual
#                       beyond their danger pixels
#   #paint_danger(d)  — write damaging pixels into the danger map
#                       (a flat 16x16 boolean array). Called every
#                       frame, so animation falls out naturally from
#                       reading the hazard's current state
#
# The MainScene holds an Array of these and treats them
# polymorphically — to add a new hazard variant you only define a
# new class with these four methods (plus a constructor) and an
# event in the timeline that instantiates it.

# Visual-only red outline rectangle. Used to flag where bones are
# about to appear.
class WarningRect
  COLOR_R = 200
  COLOR_G = 0
  COLOR_B = 0

  def initialize(x, y, w, h, lifetime_ms)
    @x = x
    @y = y
    @w = w
    @h = h
    @lifetime = lifetime_ms
    @age = 0
  end

  def tick(dt)
    @age += dt
  end

  def finished?
    @age >= @lifetime
  end

  # Outline (top + bottom rows + side columns excluding corners,
  # which the top/bottom rows already covered). For h <= 2 the side
  # loop is empty and we degenerate cleanly to a 2-row frame.
  def render(led)
    col = 0
    while col < @w
      x = @x + col
      led.set_rgb(@y * GRID_W + x, COLOR_R, COLOR_G, COLOR_B)
      led.set_rgb((@y + @h - 1) * GRID_W + x, COLOR_R, COLOR_G, COLOR_B)
      col += 1
    end
    row = 1
    while row < @h - 1
      y = @y + row
      led.set_rgb(y * GRID_W + @x, COLOR_R, COLOR_G, COLOR_B)
      led.set_rgb(y * GRID_W + (@x + @w - 1), COLOR_R, COLOR_G, COLOR_B)
      row += 1
    end
  end

  # Visual only — never damages.
  def paint_danger(_danger)
  end
end

# Vertical white "bones" rising from the bottom of a rect into its
# full height. 1-px wide sticks at every other column inside the
# rect (so a 1-px gap between consecutive bones); rise from height
# 0 → @h over RISE_MS, then sit at full height until @stay_ms more
# has elapsed, then finish.
class UpBones
  RISE_MS = 300

  def initialize(x, y, w, h, stay_ms)
    @x = x
    @y = y
    @w = w
    @h = h
    @stay_ms = stay_ms
    @age = 0
  end

  def tick(dt)
    @age += dt
  end

  def finished?
    @age >= RISE_MS + @stay_ms
  end

  # No direct render — we draw exclusively via the danger map so
  # that "what hurts" and "what's drawn white" can never disagree.
  def render(_led)
  end

  def paint_danger(danger)
    h = current_height
    return if h <= 0
    bottom = @y + @h - 1
    top    = bottom - h + 1
    bone_offset = 0
    while bone_offset < @w
      x = @x + bone_offset
      row = top
      while row <= bottom
        danger[row * GRID_W + x] = true
        row += 1
      end
      bone_offset += 2   # 1-px wide bones with 1-px gaps
    end
  end

  def current_height
    return @h if @age >= RISE_MS
    (@age * @h) / RISE_MS
  end
end

# ================================================================
# Song data — generated by `uv run my-apps/songs/build.py <this-file>`.
# Add another song by dropping `<name>.song` into my-apps/songs/ and
# inserting another `# BEGIN SONG: <name>` / `# END SONG` pair below.
# ================================================================
# BEGIN SONG: megalovania
# 531 notes -> 547 events, 2188 bytes
MEGALOVANIA_DATA = \
  "\x26\x01\x73\x00\x00\x00\x0a\x00\x26\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00" \
  "\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x06\x01\x73\x00" \
  "\x00\x00\x0a\x00\x06\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00" \
  "\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\xf7\x00\x73\x00\x00\x00\x0a\x00" \
  "\xf7\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00" \
  "\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\xe9\x00\x73\x00\x00\x00\x0a\x00\xe9\x00\x7d\x00" \
  "\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00" \
  "\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x26\x01\x73\x00\x00\x00\x0a\x00\x26\x01\x7d\x00\x4b\x02\x7d\x00" \
  "\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00" \
  "\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x06\x01\x73\x00\x00\x00\x0a\x00\x06\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00" \
  "\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00" \
  "\x5d\x01\x7d\x00\x88\x01\x7d\x00\xf7\x00\x73\x00\x00\x00\x0a\x00\xf7\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00" \
  "\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00" \
  "\x88\x01\x7d\x00\xe9\x00\x73\x00\x00\x00\x0a\x00\xe9\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00" \
  "\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00" \
  "\x26\x01\x73\x00\x00\x00\x0a\x00\x26\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00" \
  "\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x06\x01\x73\x00" \
  "\x00\x00\x0a\x00\x06\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00" \
  "\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\xf7\x00\x73\x00\x00\x00\x0a\x00" \
  "\xf7\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00" \
  "\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\xe9\x00\x73\x00\x00\x00\x0a\x00\xe9\x00\x7d\x00" \
  "\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00" \
  "\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x26\x01\x73\x00\x00\x00\x0a\x00\x26\x01\x7d\x00\x4b\x02\x7d\x00" \
  "\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00" \
  "\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00\x06\x01\x73\x00\x00\x00\x0a\x00\x06\x01\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00" \
  "\xb8\x01\x7d\x00\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00" \
  "\x5d\x01\x7d\x00\x88\x01\x7d\x00\xf7\x00\x73\x00\x00\x00\x0a\x00\xf7\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00" \
  "\x00\x00\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00" \
  "\x88\x01\x7d\x00\xe9\x00\x73\x00\x00\x00\x0a\x00\xe9\x00\x7d\x00\x4b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\xfa\x00" \
  "\x9f\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\x5d\x01\xfa\x00\x26\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x7d\x00" \
  "\xba\x02\x5e\x00\x00\x00\x7d\x00\xba\x02\x5e\x00\x00\x00\x3e\x00\xba\x02\x5e\x00\x00\x00\x9c\x00\x93\x02\x7d\x00\x00\x00\x7d\x00" \
  "\xba\x02\x5e\x00\x00\x00\x9c\x00\x4b\x02\x5e\x00\x00\x00\x9c\x00\x4b\x02\x32\x02\x00\x00\x3e\x00\xba\x02\x3e\x00\x00\x00\xbc\x00" \
  "\xba\x02\x3e\x00\x00\x00\x3e\x00\xba\x02\x3e\x00\x00\x00\xbc\x00\x10\x03\x3e\x00\x00\x00\xbc\x00\x3f\x03\xfa\x00\x10\x03\x1f\x00" \
  "\xba\x02\x1f\x00\x3f\x03\x1f\x00\x10\x03\x1f\x00\xba\x02\x3e\x00\x00\x00\x3e\x00\x4b\x02\x3e\x00\x00\x00\x3e\x00\xba\x02\x7d\x00" \
  "\x10\x03\x3e\x00\x00\x00\x38\x01\xba\x02\x5e\x00\x00\x00\x9c\x00\xba\x02\x5e\x00\x00\x00\x1f\x00\xba\x02\x5e\x00\x00\x00\x9c\x00" \
  "\x10\x03\x5e\x00\x00\x00\x9c\x00\x3f\x03\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\x9c\x00\x17\x04\x5e\x00\x00\x00\x9c\x00" \
  "\x70\x03\x77\x01\x97\x04\x5e\x00\x00\x00\x7d\x00\x97\x04\x5e\x00\x00\x00\xbc\x00\x97\x04\x5e\x00\x00\x00\x1f\x00\x70\x03\x5e\x00" \
  "\x00\x00\x1f\x00\x97\x04\x5e\x00\x00\x00\x1f\x00\x17\x04\x65\x04\x70\x03\x5e\x00\x00\x00\x7d\x00\x70\x03\x5e\x00\x00\x00\x3e\x00" \
  "\x70\x03\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\xa1\x00\x10\x03\x5e\x00\x00\x00\x9c\x00" \
  "\x10\x03\x32\x02\x00\x00\x39\x00\x70\x03\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\x1f\x00\x70\x03\x5e\x00\x00\x00\x9c\x00" \
  "\x70\x03\x5e\x00\x00\x00\x9c\x00\x10\x03\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\x9c\x00\x97\x04\x5e\x00\x00\x00\x9c\x00" \
  "\x70\x03\x5e\x00\x00\x00\x1f\x00\x10\x03\xfa\x00\x97\x04\x5e\x00\x00\x00\x9c\x00\x70\x03\x5e\x00\x00\x00\x9c\x00\x10\x03\x5e\x00" \
  "\x00\x00\x9c\x00\xba\x02\x5e\x00\x00\x00\x9c\x00\x17\x04\x5e\x00\x00\x00\x9c\x00\x10\x03\x5e\x00\x00\x00\x9c\x00\xba\x02\x5e\x00" \
  "\x00\x00\x9c\x00\x93\x02\x5e\x00\x00\x00\x9c\x00\xd2\x01\x5e\x00\x00\x00\x9c\x00\x4b\x02\x5e\x00\x00\x00\x1f\x00\x93\x02\x5e\x00" \
  "\x00\x00\xbc\x00\xba\x02\x5e\x00\x00\x00\x7d\x00\x17\x04\x2c\x04\x00\x00\xe8\x03\x5d\x01\x39\x00\x00\x00\x44\x00\x26\x01\x39\x00" \
  "\x00\x00\x44\x00\x5d\x01\x39\x00\x00\x00\x44\x00\x88\x01\x39\x00\x00\x00\x44\x00\x9f\x01\x39\x00\x00\x00\x49\x00\x88\x01\x39\x00" \
  "\x00\x00\x3e\x00\x5d\x01\x39\x00\x00\x00\x44\x00\x26\x01\x39\x00\x00\x00\x44\x00\x9f\x01\x1f\x00\x00\x00\x1f\x00\x88\x01\x1f\x00" \
  "\x00\x00\x1f\x00\x5d\x01\x1f\x00\x00\x00\x1f\x00\x26\x01\x1f\x00\x00\x00\x1f\x00\x5d\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\xa4\x04" \
  "\x9f\x01\x7d\x00\x00\x00\x3e\x00\xb8\x01\x3e\x00\x00\x00\x3e\x00\x0b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x3e\x00\x00\x00\x3e\x00" \
  "\x9f\x01\x3e\x00\x00\x00\x3e\x00\x88\x01\x3e\x00\x00\x00\x3e\x00\x5d\x01\x3e\x00\x00\x00\x3e\x00\x26\x01\x3e\x00\x00\x00\x3e\x00" \
  "\x4a\x01\x7d\x00\x5d\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\x7d\x00\x0b\x02\x7d\x00" \
  "\x00\x00\x7d\x00\x2a\x02\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x9f\x01\x7d\x00\x88\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x65\x04" \
  "\xaf\x00\x7d\x00\x00\x00\x7d\x00\xc4\x00\x7d\x00\x00\x00\x7d\x00\xdc\x00\x7d\x00\x00\x00\x7d\x00\x5d\x01\x7d\x00\x00\x00\x7d\x00" \
  "\x4a\x01\xf4\x01\x26\x01\xf4\x01\x4a\x01\xf4\x01\x5d\x01\xf4\x01\x88\x01\xf4\x01\x4a\x01\xf4\x01\xb8\x01\x6b\x03\x00\x00\x7d\x00" \
  "\xb8\x01\x3e\x00\x00\x00\x3e\x00\x9f\x01\x3e\x00\x00\x00\x3e\x00\x88\x01\x3e\x00\x00\x00\x3e\x00\x72\x01\x3e\x00\x00\x00\x3e\x00" \
  "\x5d\x01\x3e\x00\x00\x00\x3e\x00\x4a\x01\x3e\x00\x00\x00\x3e\x00\x37\x01\x3e\x00\x00\x00\x3e\x00\x26\x01\x3e\x00\x00\x00\x3e\x00" \
  "\x15\x01\x6b\x03\x00\x00\x7d\x00\x37\x01\xe8\x03\x00\x00\xe8\x03\x5d\x01\x39\x00\x00\x00\x44\x00\x26\x01\x39\x00\x00\x00\x44\x00" \
  "\x5d\x01\x39\x00\x00\x00\x44\x00\x88\x01\x39\x00\x00\x00\x44\x00\x9f\x01\x39\x00\x00\x00\x49\x00\x88\x01\x39\x00\x00\x00\x3e\x00" \
  "\x5d\x01\x39\x00\x00\x00\x44\x00\x26\x01\x39\x00\x00\x00\x44\x00\x9f\x01\x1f\x00\x00\x00\x1f\x00\x88\x01\x1f\x00\x00\x00\x1f\x00" \
  "\x5d\x01\x1f\x00\x00\x00\x1f\x00\x26\x01\x1f\x00\x00\x00\x1f\x00\x5d\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\xa4\x04\x9f\x01\x7d\x00" \
  "\x00\x00\x3e\x00\xb8\x01\x3e\x00\x00\x00\x3e\x00\x0b\x02\x7d\x00\x00\x00\x7d\x00\xb8\x01\x3e\x00\x00\x00\x3e\x00\x9f\x01\x3e\x00" \
  "\x00\x00\x3e\x00\x88\x01\x3e\x00\x00\x00\x3e\x00\x5d\x01\x3e\x00\x00\x00\x3e\x00\x26\x01\x3e\x00\x00\x00\x3e\x00\x4a\x01\x7d\x00" \
  "\x5d\x01\x7d\x00\x00\x00\x7d\x00\x88\x01\x7d\x00\x00\x00\x7d\x00\xb8\x01\x7d\x00\x00\x00\x7d\x00\x0b\x02\x7d\x00\x00\x00\x7d\x00" \
  "\x2a\x02\xfa\x00\x9f\x01\x7d\x00\x00\x00\x7d\x00\x9f\x01\x7d\x00\x88\x01\x7d\x00\x5d\x01\x7d\x00\x88\x01\x65\x04\xaf\x00\x7d\x00" \
  "\x00\x00\x7d\x00\xc4\x00\x7d\x00\x00\x00\x7d\x00\xdc\x00\x7d\x00\x00\x00\x7d\x00\x5d\x01\x7d\x00\x00\x00\x7d\x00\x4a\x01\xf4\x01" \
  "\x26\x01\xf4\x01\x4a\x01\xf4\x01\x5d\x01\xf4\x01\x88\x01\xf4\x01\x4a\x01\xf4\x01\xb8\x01\x6b\x03\x00\x00\x7d\x00\xb8\x01\x3e\x00" \
  "\x00\x00\x3e\x00\x9f\x01\x3e\x00\x00\x00\x3e\x00\x88\x01\x3e\x00\x00\x00\x3e\x00\x72\x01\x3e\x00\x00\x00\x3e\x00\x5d\x01\x3e\x00" \
  "\x00\x00\x3e\x00\x4a\x01\x3e\x00\x00\x00\x3e\x00\x37\x01\x3e\x00\x00\x00\x3e\x00\x26\x01\x3e\x00\x00\x00\x3e\x00\x15\x01\x6b\x03" \
  "\x00\x00\x7d\x00\x37\x01\xe8\x03\x00\x00\xf4\x01"
# END SONG
# BEGIN SONG: determination
# 162 notes -> 162 events, 648 bytes
DETERMINATION_DATA = \
  "\x72\x01\x05\x01\x5d\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01\x37\x01\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\x00\x00\x05\x01" \
  "\xd0\x00\x05\x01\x00\x00\x05\x01\x37\x01\x05\x01\x5d\x01\x05\x01\x72\x01\x05\x01\x00\x00\x05\x01\x9f\x01\x05\x01\x00\x00\x05\x01" \
  "\x2a\x02\x05\x01\x00\x00\x05\x01\xd2\x01\x13\x04\x00\x00\x0a\x02\x72\x01\x05\x01\x5d\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01" \
  "\x37\x01\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\x00\x00\x05\x01\xd0\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x05\x01\xaf\x00\x05\x01" \
  "\xb9\x00\x05\x01\x00\x00\x05\x01\xaf\x00\x05\x01\x00\x00\x05\x01\x8b\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x13\x04\x00\x00\x0a\x02" \
  "\x72\x01\x05\x01\x5d\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01\x37\x01\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\x00\x00\x05\x01" \
  "\xd0\x00\x05\x01\x00\x00\x05\x01\x37\x01\x05\x01\x5d\x01\x05\x01\x72\x01\x05\x01\x00\x00\x05\x01\x9f\x01\x05\x01\x00\x00\x05\x01" \
  "\x2a\x02\x05\x01\x00\x00\x05\x01\xd2\x01\x13\x04\x00\x00\x0a\x02\x72\x01\x05\x01\x5d\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01" \
  "\x37\x01\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\x00\x00\x05\x01\xd0\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x05\x01\xaf\x00\x05\x01" \
  "\xb9\x00\x05\x01\x00\x00\x05\x01\xaf\x00\x05\x01\x00\x00\x05\x01\x8b\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x13\x04\x00\x00\x0a\x02" \
  "\x9f\x01\x05\x01\x72\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x05\x01\x00\x00\x05\x01" \
  "\xe9\x00\x05\x01\x00\x00\x05\x01\xe9\x00\x05\x01\x37\x01\x05\x01\x9f\x01\x05\x01\x72\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x05\x01" \
  "\x15\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x0f\x03\x00\x00\x05\x01\x9c\x00\x05\x01\xd0\x00\x05\x01\x15\x01\x05\x01\x06\x01\x05\x01" \
  "\xe9\x00\x05\x01\xd0\x00\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\xe9\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x05\x01\x00\x00\x05\x01" \
  "\x75\x00\x05\x01\x8b\x00\x05\x01\x9c\x00\x05\x01\x00\x00\x05\x01\xf7\x00\x05\x01\x00\x00\x05\x01\x37\x01\x0a\x02\x26\x01\x13\x04" \
  "\x00\x00\x0a\x02\x9f\x01\x05\x01\x72\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x05\x01\x15\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x05\x01" \
  "\x00\x00\x05\x01\xe9\x00\x05\x01\x00\x00\x05\x01\xe9\x00\x05\x01\x37\x01\x05\x01\x9f\x01\x05\x01\x72\x01\x05\x01\x4a\x01\x05\x01" \
  "\x37\x01\x05\x01\x15\x01\x05\x01\x4a\x01\x05\x01\x37\x01\x0f\x03\x00\x00\x05\x01\x9c\x00\x05\x01\xd0\x00\x05\x01\x15\x01\x05\x01" \
  "\x06\x01\x05\x01\xe9\x00\x05\x01\xd0\x00\x05\x01\xe9\x00\x05\x01\x06\x01\x05\x01\xe9\x00\x05\x01\x00\x00\x05\x01\x9c\x00\x05\x01" \
  "\x00\x00\x05\x01\x75\x00\x05\x01\x8b\x00\x05\x01\x9c\x00\x05\x01\x00\x00\x05\x01\x8b\x00\x05\x01\x00\x00\x05\x01\x68\x00\x05\x01" \
  "\x00\x00\x05\x01\x75\x00\x13\x04"
# END SONG

# ================================================================
# Shared display geometry
# ================================================================
# Only GRID_W / GRID_H live at the top level — both scenes address
# the same physical matrix. Everything else (sprites, colors, gameplay
# timing, song data) lives inside the scene class that owns it.
GRID_W = 16
GRID_H = 16

# ================================================================
# Hardware
# ================================================================
led       = WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256)
btn_left  = GPIO.new(Board43::GPIO_SW3, GPIO::IN | GPIO::PULL_UP)
btn_up    = GPIO.new(Board43::GPIO_SW4, GPIO::IN | GPIO::PULL_UP)
btn_down  = GPIO.new(Board43::GPIO_SW5, GPIO::IN | GPIO::PULL_UP)
btn_right = GPIO.new(Board43::GPIO_SW6, GPIO::IN | GPIO::PULL_UP)
buzzer    = PWM.new(Board43::GPIO_BUZZER, frequency: 0, duty: 40)

# ================================================================
# Scenes
# ================================================================
#
# Each scene is a small object with #tick(dt) that advances the
# scene by one frame and returns either a Symbol (to request a
# transition to that scene) or nil (to stay). Scene state lives as
# @ivars so nothing has to be reconstructed per frame.
#
# The outer loop at the bottom of this file owns the dt clock and
# the scene dispatch. Scenes never loop on their own.

# Title scene: silent, Sans sprite scrolls right-to-left with a
# full-screen gap between repeats. SW6 press edge → :main.
class TitleScene
  # Sprite is 17 wide × 15 tall (one column wider than the matrix),
  # pre-converted to byte rows so the draw loop is pure index
  # lookup. Glyph codes: '#' = white, 'K' = dark grey, '.' = off.
  SANS_SPRITE = [
    "....KKKKKKKKK....",
    "..KK#########KK..",
    ".K#############K.",
    ".K#############K.",
    "K###############K",
    "K##########KKK##K",
    "K##########KKK##K",
    "K##KKK##K##KKK##K",
    ".K#####KKK#####K.",
    "KK#K#########K#KK",
    "K##KKKKKKKKKKK##K",
    "K###K#K#K#K#K###K",
    ".KK##KKKKKKK##KK.",
    "...KK#######KK...",
    ".....KKKKKKK.....",
  ]
  SANS_BYTES  = SANS_SPRITE.map { |row| row.bytes }
  SANS_W      = 17
  SANS_H      = 15
  SANS_Y      = 0            # top-align; bottom row stays blank
  SANS_GAP    = GRID_W       # one full blank screen between repeats
  SANS_PERIOD = SANS_W + SANS_GAP

  # Byte values of the sprite glyphs (avoids char-compare at runtime).
  C_WHITE = 35  # '#'
  C_GREY  = 75  # 'K'

  # Render colors. White pixels render as actual white; "black"
  # pixels render as a very dim blue that just barely lights the LED
  # so the silhouette reads against the (fully off) transparent
  # pixels.
  WHITE_R = 180
  WHITE_G = 180
  WHITE_B = 180
  GREY_R  = 0
  GREY_G  = 0
  GREY_B  = 40

  SCROLL_MS_PER_PX = 140  # sprite advances one column every 140 ms

  def initialize(led, btn_right, buzzer)
    @led       = led
    @btn_right = btn_right
    buzzer.frequency(0)

    @scroll_x     = 0
    @scroll_accum = 0

    # Seed the edge detector with the current state so a button
    # already held at boot doesn't instantly skip the title.
    @prev_down = btn_right.low?
  end

  def tick(dt)
    @scroll_accum += dt
    while @scroll_accum >= SCROLL_MS_PER_PX
      @scroll_accum -= SCROLL_MS_PER_PX
      @scroll_x = (@scroll_x + 1) % SANS_PERIOD
    end
    render

    now_down = @btn_right.low?
    fired = now_down && !@prev_down
    @prev_down = now_down
    fired ? :main : nil
  end

  # Render the scrolling sprite. We iterate screen columns rather
  # than sprite columns so blank columns between repeats cost
  # nothing. `@scroll_x` is the current left-edge offset into the
  # infinite SANS_PERIOD-wide tape (sprite followed by one full
  # blank screen, repeating).
  def render
    @led.fill(0, 0, 0)
    col = 0
    while col < GRID_W
      sprite_col = (col + @scroll_x) % SANS_PERIOD
      if sprite_col < SANS_W
        row = 0
        while row < SANS_H
          code = SANS_BYTES[row][sprite_col]
          idx  = (SANS_Y + row) * GRID_W + col
          if code == C_WHITE
            @led.set_rgb(idx, WHITE_R, WHITE_G, WHITE_B)
          elsif code == C_GREY
            @led.set_rgb(idx, GREY_R, GREY_G, GREY_B)
          end
          row += 1
        end
      end
      col += 1
    end
    @led.show
  end
end

# Main scene (prototype): SOUL moves under the four-button control,
# megalovania loops on the buzzer, Left+Right chord toggles tracks.
#
# Input model:
#   Each direction has a `@ready_X` countdown in ms. When a button
#   is released we reset it to 0 so the next fresh press fires on
#   the very next poll (zero perceived latency). While held, `dt`
#   drains it; when it reaches 0, we step one cell and reload to
#   CONTROL_REPEAT_MS. This gives snap-to-first-press + smooth
#   auto-repeat without edge detection state.
#
# Debug track toggle:
#   Left+Right pressed together (a physically-impossible movement
#   combo) advances TRACK_ORDER by one. Edge-detected via
#   `@chord_held` so the toggle fires once per chord press, not
#   once per frame. Movement for L and R is suppressed while the
#   chord is held.
class MainScene
  # 3x2 "red T" downward triangle — compact, leaves room for attacks.
  HEART_SPRITE = ['###', '.#.']
  HEART_W = 3
  HEART_H = 2

  # Heart color is driven by mode:
  #   :red  — free movement (classic Undertale).
  #   :blue — gravity platformer; vertical input is "jump only".
  HEART_RED_R  = 200
  HEART_RED_G  = 0
  HEART_RED_B  = 0
  HEART_BLUE_R = 0
  HEART_BLUE_G = 0
  HEART_BLUE_B = 200

  # HP bar occupies the bottom row of the matrix. Heart movement is
  # clamped to PLAY_H so the heart can't paint over it.
  HP_ROW = GRID_H - 1
  HP_MAX = GRID_W
  HP_R   = 200
  HP_G   = 200
  HP_B   = 0

  PLAY_H = GRID_H - 1   # playfield excludes the HP row

  CONTROL_REPEAT_MS = 96   # step every ~96 ms while a button is held

  # --- Blue-mode physics --------------------------------------------
  #
  # Vertical position is integrated as a Float (rows; @y_f) and only
  # truncated to an integer (@y) for rendering.
  #
  # Variable-height jump: holding Up lets the upward velocity decay
  # naturally under gravity; releasing Up while still ascending
  # zeroes @vy on the spot, so gravity takes over immediately. Short
  # tap → short hop, full hold → max-height jump. Once released (or
  # once the apex is reached) the heart is committed to falling all
  # the way back to the floor — re-pressing Up mid-air is a no-op
  # because the edge-detected jump trigger only fires while grounded.
  #
  # Tuning: a full-hold jump's kinematic peak slightly overshoots 12
  # rows (= 3/4 of the 16-row screen), and the absolute clamp at
  # JUMP_PEAK_Y catches the rest. Time to peak ≈ 600 ms, fall back
  # ≈ 775 ms, total air time ≈ 1.4 s.
  #
  #   peak_height = JUMP_V0² / (2 * GRAVITY) = 0.032² / 0.00008 ≈ 12.8
  #
  # Integration is semi-implicit Euler (`@vy += g*dt; @y += @vy*dt`),
  # which is energy-stable for ballistic motion.
  GRAVITY     = 0.00004          # rows / ms²  (≈ 40 rows/s²)
  JUMP_V0     = 0.032            # rows / ms   (applied as -JUMP_V0)
  GROUND_Y    = PLAY_H - HEART_H # heart's @y when standing on the floor
  JUMP_PEAK_Y = 4                # absolute ceiling for any jump

  # Pre-convert each song's packed byte String to an Array<Integer>
  # exactly once at class-load time. MusicPlayer#play swaps
  # references into this hash, so switching tracks at runtime never
  # allocates. Add a new song by appending to both SONGS and
  # TRACK_ORDER.
  SONGS = {
    megalovania:   MEGALOVANIA_DATA.bytes,
    determination: DETERMINATION_DATA.bytes,
  }
  TRACK_ORDER = [:megalovania, :determination]

  # === Damage layer ================================================
  #
  # White is the damage color. Hazards write their damaging pixels
  # into the @danger map; render reads from it (drawn as white) and
  # so does the heart's collision check. Adding a new hazard variant
  # only requires implementing #paint_danger on the hazard class —
  # nothing else in MainScene needs to know about it.
  WHITE_R = 200
  WHITE_G = 200
  WHITE_B = 200

  # 1 HP per ~250 ms of continuous contact with any white pixel.
  DAMAGE_INTERVAL_MS = 250

  # === Game timeline ===============================================
  #
  # Each entry is [time_ms, :event_name, *args]. The args after the
  # event name are domain-specific — most spawn-events take the
  # geometry of the hazard they create — and apply_event below
  # destructures them. The timeline is the single source of truth
  # for WHAT appears WHEN and HOW BIG.
  #
  # We dispatch with `case` rather than Kernel#send because send
  # support is uneven across PicoRuby/mruby builds.
  TIMELINE = [
    [2000, :enter_blue],
    # x, y, w, h, lifetime_ms — visual outline only, doesn't damage.
    [3000, :spawn_warning,   0, 9, 16, 6, 500],
    # x, y, w, h, stay_ms — bones rise from rect bottom into rect
    # top over UpBones::RISE_MS, sit at full height for stay_ms,
    # then finish on their own.
    [3500, :spawn_up_bones,  0, 9, 16, 6, 700],
    [4800, :enter_red],
  ]

  def initialize(led, btn_left, btn_up, btn_down, btn_right, buzzer)
    @led       = led
    @btn_left  = btn_left
    @btn_up    = btn_up
    @btn_down  = btn_down
    @btn_right = btn_right

    @player   = MusicPlayer.new(buzzer)
    @track_ix = 0
    @player.play(SONGS[TRACK_ORDER[@track_ix]])

    # Active hazard objects. Each one ducks into:
    #   #tick(dt)         — advance internal state
    #   #finished?        — true when ready for cleanup
    #   #render(led)      — paint non-damaging visuals
    #   #paint_danger(d)  — write damaging pixels into the @danger map
    @hazards = []

    # Danger map: 16x16 booleans, true wherever a white (damaging)
    # pixel currently lives. Allocated once and reused —
    # rebuild_danger zeroes it in place every frame and each active
    # hazard re-paints into it. The renderer and the heart's
    # collision check read from this same map, which keeps "what's
    # drawn white" and "what hurts" in sync by construction.
    @danger = Array.new(GRID_W * GRID_H, false)

    # Throttled damage trigger: while the heart is touching a white
    # pixel, fires once every DAMAGE_INTERVAL_MS, returning the
    # number of fires per frame so we can deduct HP accordingly.
    @damage_trigger = ThrottledTrigger.new(DAMAGE_INTERVAL_MS)

    # Edge-detect for the Up+Down reset chord. Tracked here (not
    # in reset_scene) so the latch survives a reset — otherwise the
    # reset would loop on every frame the chord is still held.
    @reset_held = false

    reset_scene
    render
  end

  # Restore the scene to its t=0 state: heart centered in red mode
  # at full HP, timeline cursor at the first event, every active
  # hazard dropped. Hardware, audio, the danger buffer, and the
  # reset-chord latch are persistent and intentionally left alone.
  # The damage trigger self-resets next frame — heart_overlaps_danger?
  # will be false because the hazard list was just cleared.
  def reset_scene
    @mode = :red

    @x   = (GRID_W - HEART_W) / 2
    cy   = (PLAY_H - HEART_H) / 2
    @y_f = cy.to_f
    @y   = cy
    @vy  = 0.0
    @hp  = HP_MAX

    @ready_l    = 0
    @ready_r    = 0
    @ready_u    = 0
    @ready_d    = 0
    @chord_held = false   # L+R track-toggle chord
    @up_prev    = false   # blue-mode jump edge

    @hazards.clear

    @t        = 0
    @event_ix = 0
  end

  def tick(dt)
    # Re-enable after gameplay testing
    # @player.tick(dt)

    # Up+Down chord resets the scene. Edge-detected so it fires
    # once per chord press, not every frame the chord is held.
    if @btn_up.low? && @btn_down.low?
      unless @reset_held
        reset_scene
        @reset_held = true
      end
    else
      @reset_held = false
    end

    advance_timeline(dt)
    advance_hazards(dt)
    rebuild_danger

    tick_horizontal(dt)
    if @mode == :blue
      tick_vertical_blue(dt)
    else
      tick_vertical_red(dt)
    end

    apply_damage(dt)

    render
    nil
  end

  # === Timeline ===================================================

  def advance_timeline(dt)
    @t += dt
    while @event_ix < TIMELINE.length && TIMELINE[@event_ix][0] <= @t
      apply_event(TIMELINE[@event_ix])
      @event_ix += 1
    end
  end

  # Big switchboard for timeline events. `entry` is the full
  # [time_ms, :name, *args] array; the args layout for each event
  # is documented next to TIMELINE. Using `case` instead of
  # Kernel#send because send support is uneven on PicoRuby/mruby.
  def apply_event(entry)
    case entry[1]
    when :enter_blue
      @mode = :blue
      # Don't reset @y_f / @vy — gravity pulls the heart from
      # wherever it currently is, which is the "flung to the
      # floor" effect.
    when :enter_red
      @mode = :red
      @y    = @y_f.to_i
      @vy   = 0.0
    when :spawn_warning
      @hazards << WarningRect.new(entry[2], entry[3], entry[4], entry[5], entry[6])
    when :spawn_up_bones
      @hazards << UpBones.new(entry[2], entry[3], entry[4], entry[5], entry[6])
    end
  end

  # === Hazards ====================================================

  # Tick every hazard and drop the finished ones. delete_at is
  # acceptable here because @hazards is tiny (a handful at most).
  def advance_hazards(dt)
    i = 0
    while i < @hazards.length
      h = @hazards[i]
      h.tick(dt)
      if h.finished?
        @hazards.delete_at(i)
      else
        i += 1
      end
    end
  end

  # Wipe @danger and let each active hazard repaint its damaging
  # pixels. Each hazard is the single source of truth for its own
  # damage geometry; render reads from @danger so "what's drawn
  # white" and "what hurts" stay in sync by construction.
  def rebuild_danger
    i = 0
    n = @danger.length
    while i < n
      @danger[i] = false
      i += 1
    end
    hi = 0
    while hi < @hazards.length
      @hazards[hi].paint_danger(@danger)
      hi += 1
    end
  end

  # === Damage =====================================================
  #
  # The damage path is decoupled from the game script: it only
  # reads the heart's footprint, the @danger map, and dt, then
  # delegates rate-limiting to the generic ThrottledTrigger. New
  # hazards that paint into @danger get damage handling for free.
  def apply_damage(dt)
    n = @damage_trigger.tick(dt, heart_overlaps_danger?)
    return if n <= 0
    @hp -= n
    @hp = 0 if @hp < 0
  end

  # Only lit (`#`) sprite pixels collide. The transparent (`.`)
  # cells of the 3x2 bounding box are ignored, so a bone passing
  # through the heart's gap doesn't count as a hit.
  def heart_overlaps_danger?
    row = 0
    while row < HEART_H
      bytes = HEART_SPRITE[row].bytes
      col = 0
      while col < HEART_W
        if bytes[col] == 35  # '#'
          return true if @danger[(@y + row) * GRID_W + (@x + col)]
        end
        col += 1
      end
      row += 1
    end
    false
  end

  # Horizontal movement is shared by both modes. Auto-repeat steps
  # one cell per CONTROL_REPEAT_MS while a button is held; releasing
  # resets the counter so the next press fires on the very next poll.
  # Left+Right held together cycles the music track for debug.
  def tick_horizontal(dt)
    l_down = @btn_left.low?
    r_down = @btn_right.low?

    if l_down && r_down
      unless @chord_held
        @track_ix = (@track_ix + 1) % TRACK_ORDER.length
        @player.play(SONGS[TRACK_ORDER[@track_ix]])
        @chord_held = true
      end
      @ready_l = 0
      @ready_r = 0
      return
    end
    @chord_held = false

    if l_down
      @ready_l -= dt
      if @ready_l <= 0
        @x -= 1 if @x > 0
        @ready_l = CONTROL_REPEAT_MS
      end
    else
      @ready_l = 0
    end

    if r_down
      @ready_r -= dt
      if @ready_r <= 0
        @x += 1 if @x < GRID_W - HEART_W
        @ready_r = CONTROL_REPEAT_MS
      end
    else
      @ready_r = 0
    end
  end

  # Red mode: free vertical movement with the same auto-repeat model
  # as horizontal. Keeps @y_f in sync so a future mode switch into
  # blue starts from a sane integer position with zero velocity.
  def tick_vertical_red(dt)
    if @btn_up.low?
      @ready_u -= dt
      if @ready_u <= 0
        @y -= 1 if @y > 0
        @ready_u = CONTROL_REPEAT_MS
      end
    else
      @ready_u = 0
    end

    if @btn_down.low?
      @ready_d -= dt
      if @ready_d <= 0
        @y += 1 if @y < PLAY_H - HEART_H
        @ready_d = CONTROL_REPEAT_MS
      end
    else
      @ready_d = 0
    end

    @y_f = @y.to_f
    @vy  = 0.0
  end

  # Blue mode: gravity is always pulling down; Up edge-press while
  # grounded launches a jump. No double jump, no fast-fall — a single
  # ballistic arc that's clamped to JUMP_PEAK_Y (3/4 screen) at the
  # top and GROUND_Y at the bottom.
  def tick_vertical_blue(dt)
    up_down  = @btn_up.low?
    grounded = @y_f >= GROUND_Y

    # Edge-press while grounded launches a fresh jump.
    if up_down && !@up_prev && grounded
      @vy = -JUMP_V0
    end
    @up_prev = up_down

    # Variable jump height: releasing Up while still ascending kills
    # the upward velocity. Gravity then takes over and the heart
    # falls to the ground — it cannot re-engage the jump until it
    # lands (the grounded check above guards re-presses in air).
    if !up_down && @vy < 0
      @vy = 0.0
    end

    @vy  += GRAVITY * dt
    @y_f += @vy * dt

    if @y_f >= GROUND_Y
      @y_f = GROUND_Y.to_f
      @vy  = 0.0
    elsif @y_f <= JUMP_PEAK_Y
      # Hard ceiling: stop upward motion so gravity can take over.
      # Don't zero a downward @vy — only kill the upward push.
      @y_f = JUMP_PEAK_Y.to_f
      @vy  = 0.0 if @vy < 0
    end

    @y = @y_f.to_i
  end

  # Full-frame render. Draw order is bottom-up:
  #   1. clear
  #   2. HP bar              (row 15)
  #   3. hazard visuals      (warning outlines, etc.)
  #   4. white danger pixels (everything painted into @danger)
  #   5. heart               (player always on top)
  def render
    @led.fill(0, 0, 0)

    col = 0
    while col < @hp
      @led.set_rgb(HP_ROW * GRID_W + col, HP_R, HP_G, HP_B)
      col += 1
    end

    hi = 0
    while hi < @hazards.length
      @hazards[hi].render(@led)
      hi += 1
    end

    i = 0
    n = @danger.length
    while i < n
      @led.set_rgb(i, WHITE_R, WHITE_G, WHITE_B) if @danger[i]
      i += 1
    end

    if @mode == :blue
      hr = HEART_BLUE_R; hg = HEART_BLUE_G; hb = HEART_BLUE_B
    else
      hr = HEART_RED_R;  hg = HEART_RED_G;  hb = HEART_RED_B
    end

    row = 0
    while row < HEART_H
      bytes = HEART_SPRITE[row].bytes
      col = 0
      while col < HEART_W
        if bytes[col] == 35  # '#'
          @led.set_rgb((@y + row) * GRID_W + (@x + col), hr, hg, hb)
        end
        col += 1
      end
      row += 1
    end

    @led.show
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

# ================================================================
# Program — single dt-driven outer loop, scenes dispatched inside.
# ================================================================
#
# Frame cadence is whatever led.show (≈8 ms of WS2812 bit-banging
# for 256 LEDs) plus a few ms of Ruby happens to be on this
# hardware — roughly 10-20 ms. We don't estimate it; we measure
# every frame with Machine.board_millis and feed the real elapsed
# ms (`dt`) to the active scene's #tick.
#
# Contract for any Scene#tick:
#   - All timing state must decrement / accumulate in `dt` units.
#     Never key timing off "N frames"; frame time is variable.
#   - `dt` can spike; #tick must tolerate that. MusicPlayer#tick
#     uses a `while` loop so multiple short events that fit inside
#     one dt don't get dropped.
#   - Return a Symbol to request a scene switch, or nil to stay.
#     Scene construction happens at the frame boundary in the
#     outer loop, so transitions always start a new scene on a
#     fresh frame.
scene = TitleScene.new(led, btn_right, buzzer)
repl  = LiveRepl.new
last_ms = Machine.board_millis

loop do
  now_ms  = Machine.board_millis
  dt      = now_ms - last_ms
  last_ms = now_ms

  repl.tick

  case scene.tick(dt)
  when :title
    scene = TitleScene.new(led, btn_right, buzzer)
  when :main
    scene = MainScene.new(led, btn_left, btn_up, btn_down, btn_right, buzzer)
  end
end
