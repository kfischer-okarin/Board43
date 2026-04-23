---
name: creating-board43-apps
description: Write PicoRuby apps for the Board43 RP2350A dev board — 16x16 WS2812 LED matrix, piezo buzzer (PWM), four buttons (SW3-SW6), status LED, and LSM6DS3 IMU. Use whenever creating or editing a sample under `workshop/examples/`, or when the user asks for a Board43 app, LED animation, buzzer tune, tilt game, or button-driven interaction on this board.
---

# Creating Board43 apps

Board43 runs **PicoRuby** (R2P2 firmware) on an RP2350A. Apps are single
`.rb` files in `workshop/examples/` uploaded via the playground (browser
IDE + Web Serial, Chrome/Edge) or run in the playground's WASM simulator.

## Hardware map

<!-- markdownlint-disable MD013 -->

| Peripheral                         | Module(s)                 | Pin constant                            |
| ---------------------------------- | ------------------------- | --------------------------------------- |
| 16×16 WS2812 matrix (256 LEDs)     | `ws2812-plus`             | `Board43::GPIO_LEDOUT`                  |
| Piezo buzzer                       | `pwm`                     | `Board43::GPIO_BUZZER`                  |
| Push buttons (active-low, pull-up) | `gpio` (+ `irq` optional) | `Board43::GPIO_SW3` … `GPIO_SW6`        |
| Status LED                         | `gpio`                    | `Board43::GPIO_STATUS_LED`              |
| LSM6DS3 IMU (accel + gyro)         | `i2c`, `lsm6ds3`          | `Board43::GPIO_IMU_SDA`, `GPIO_IMU_SCL` |

<!-- markdownlint-enable MD013 -->

## File skeleton

```ruby
# Board43 Sample: <Name>
#
# <one-paragraph description>
#
#   SW3: ...
#   SW4: ...
#
# Features: Switches (GPIO) + WS2812 16x16 matrix + Buzzer (PWM)

require 'ws2812-plus'
require 'pwm'
require 'gpio'

led    = WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256)
buzzer = PWM.new(Board43::GPIO_BUZZER, frequency: 0, duty: 50)
sw3    = GPIO.new(Board43::GPIO_SW3, GPIO::IN | GPIO::PULL_UP)

loop do
  # read inputs, update state, draw
  led.show
  sleep_ms 30
end
```

Keep the header comment, SW listing, and `Features:` line — existing
samples all follow this shape.

## LED matrix (`ws2812-plus`)

- Index pixels row-major: `idx = row * 16 + col` (row 0 = top, col 0 = left).
- `led.set_rgb(idx, r, g, b)` — 8 bits per channel.
- `led.set_hsb(idx, hue, sat, brightness)` — `hue` 0-360,
  `sat`/`brightness` 0-100. Easier for rainbows and fades.
- `led.fill(r, g, b)` / `led.clear` for bulk operations.
- **Must call `led.show`** after changes to flush the buffer.
- Existing samples use modest brightness (20-50). Full-brightness 256
  LEDs draws significant current; prefer conservative values unless you
  have a reason.

## Buttons (`gpio`)

Buttons are **active-low** with internal pull-ups.

```ruby
sw = GPIO.new(Board43::GPIO_SW3, GPIO::IN | GPIO::PULL_UP)
sw.low?   # true when pressed
sw.high?  # true when released
sw.read   # 0 (pressed) or 1 (released)
```

**Edge detection** (fire once per press, not while held):

```ruby
prev = false
loop do
  now = sw.low?
  do_thing if now && !prev
  prev = now
  sleep_ms 20
end
```

**IRQ-driven** (survives long work in the main loop):

```ruby
require 'irq'
state = { hit: false }
sw3.irq(GPIO::EDGE_FALL, debounce: 50, capture: state) do |gpio, event, cap|
  cap[:hit] = true
end
loop do
  IRQ.process
  # handle state[:hit] ...
  sleep_ms 30
end
```

Buttons are physically ordered SW3 (leftmost) → SW6 (rightmost). When
an app has an ordered pair of controls (e.g. decrease/increase), map
them left-to-right. Otherwise, check the existing samples — they each
assign buttons to suit their own task and there's no cross-sample rule.

## Buzzer (`pwm`)

```ruby
buzzer = PWM.new(Board43::GPIO_BUZZER, frequency: 0, duty: 50)
buzzer.frequency(440)  # A4 — starts the tone
sleep_ms 200
buzzer.frequency(0)    # stops the tone
# or: buzzer.duty(0)   # also silences (see buzzer.rb)
```

Existing samples pick a fixed `duty` at construction: `logo.rb` uses
`10`, `drum.rb` and `theremin.rb` use `50`. After construction they
only change `frequency` to play tones.

## IMU (`i2c` + `lsm6ds3`)

```ruby
require 'i2c'
require 'lsm6ds3'

i2c = I2C.new(unit: :RP2040_I2C0,
              sda_pin: Board43::GPIO_IMU_SDA,
              scl_pin: Board43::GPIO_IMU_SCL,
              frequency: 400_000)
imu = LSM6DS3.new(i2c)

acc = imu.read_acceleration  # [ax, ay, az] in g
all = imu.read_all           # { acceleration:, gyroscope:, temperature: }
```

Axis orientation depends on how the board is held — verify empirically
with `imu.rb`. Typical use: `acc[0]` for left/right tilt, `acc[1]` for
front/back.

## Timing

- `sleep N` — seconds (float, `sleep 0.1`).
- `sleep_ms N` — milliseconds.
- Frame loops typically target 20-30ms (`sleep_ms 30` ≈ 33 FPS).

## PicoRuby gotchas

- **No built-in `rand`.** Ship your own LCG (pattern used in `snake_game.rb` / `drum.rb`):

  ```ruby
  class SimpleRand
    def initialize(seed = 12345); @seed = seed; end
    def rand(max)
      @seed = (@seed * 1103515245 + 12345) & 0x7fffffff
      @seed % max
    end
  end
  ```

- **`def` does not close over outer locals.** Pass a state hash
  explicitly (the `drum.rb` pattern). Top-level constants (`FOO = ...`)
  *are* visible inside methods.
- **Existing samples use `while` loops** for per-pixel and per-particle
  update paths (`water.rb`, `logo.rb`, `snake_game.rb`). Match that
  style unless there's a reason not to.
- **`return` cannot exit from inside a block.** Use flags or restructure.
- **`String#bytes`** returns raw byte values, useful for decoding
  bitmap strings (`logo.rb`: `bytes[col] == 35` compares against `'#'`).

## Encoding sprites

The established pattern is **bitmap strings**: one string per row using
`#`/`.` (or similar) for on/off, decoded with `.bytes` and a row-major
index into a flat array. See `logo.rb` for the canonical example.

## Workflow

1. Write the `.rb` under `workshop/examples/`.
2. Test in the browser playground (WASM simulator) — or flash-free
   upload to a connected board via Web Serial.
3. Firmware changes live in `firmware/` — see top-level `CLAUDE.md`.

## Existing samples (use as reference)

From `workshop/examples/`:

- **Single peripheral**: `status_led.rb`, `button.rb`, `buzzer.rb`,
  `led_matrix.rb`, `imu.rb`.
- **Combined**:
  - `logo.rb` — LED + switches + buzzer, bitmap-string sprite, mode
    switching.
  - `drum.rb` — IRQ-driven buttons, per-effect frame animation, state
    hash pattern.
  - `snake_game.rb` — game loop, grid coordinates, `SimpleRand` LCG.
  - `theremin.rb` — IMU tilt → note scale, multi-button control.
  - `water.rb` — IMU-driven cellular automaton on the LED grid.

When unsure about an API, read the closest matching sample first.
