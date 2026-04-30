# The Definitive Board43 Guide

A reference guide and introduction to Board43: what the hardware is, what
runs on it, why, and how to develop for it. Assumes software-engineering
literacy; no prior microcontroller experience required.

---

## Table of Contents

- [Part 1 — Board43 in Brief](#part-1--board43-in-brief)
- [Part 2 — Hardware](#part-2--hardware)
  - [2.1 Board43 (the PCB)](#21-board43-the-pcb)
  - [2.2 The RP2350A microcontroller](#22-the-rp2350a-microcontroller)
  - [2.3 What's already on a freshly-printed board](#23-whats-already-on-a-freshly-printed-board)
- [Part 3 — The Layer Cake](#part-3--the-layer-cake)
- [Part 4 — The Firmware in Detail](#part-4--the-firmware-in-detail)
  - [4.1 R2P2 — Ruby Rapid Portable Platform](#41-r2p2--ruby-rapid-portable-platform)
  - [4.2 Boot flow on the chip](#42-boot-flow-on-the-chip)
  - [4.3 Auto-run on boot (and how to skip it)](#43-auto-run-on-boot-and-how-to-skip-it)
  - [4.4 Shell — built-in commands](#44-shell--built-in-commands)
  - [4.5 mrbgems baked into the Board43 build](#45-mrbgems-baked-into-the-board43-build)
  - [4.6 What this repo adds on top of stock PicoRuby](#46-what-this-repo-adds-on-top-of-stock-picoruby)
  - [4.7 The `Board43` module — pin constants](#47-the-board43-module--pin-constants)
- [Part 5 — Building the Firmware](#part-5--building-the-firmware)
- [Part 6 — Connecting and Developing](#part-6--connecting-and-developing)
- [Part 7 — PicoModem: protocol reference](#part-7--picomodem-protocol-reference)
- [Part 8 — Where Each Concern Lives (jump table)](#part-8--where-each-concern-lives-jump-table)
- [Part 9 — Mental Models to Keep](#part-9--mental-models-to-keep)
- [Appendix A — libc, HAL, Stubs (the foundational C concepts)](#appendix-a--libc-hal-stubs-the-foundational-c-concepts)

---

## Part 1 — Board43 in Brief

**Hardware.** Board43 is a small printed circuit board built around a
**Raspberry Pi RP2350A** microcontroller, with a fixed set of peripherals
soldered onto specific GPIO pins: a 16×16 WS2812 RGB LED matrix, an
LSM6DS3 IMU (accelerometer + gyroscope), four tactile buttons, a piezo
buzzer, a status LED, and a USB-C port wired straight to the chip's USB
peripheral. Schematic and layout live in [`pcb/`](./pcb).

**Firmware.** What ships flashed onto the board is **R2P2** — a
self-contained `.uf2` binary that bundles a Ruby virtual machine, a tiny
UNIX-shaped operating system, and drivers for everything on the PCB. R2P2
boots into a serial shell (over the USB-C port), can auto-run a Ruby file
at `/home/app.rb`, and accepts new files over a custom binary protocol
called PicoModem. Source for the firmware build lives in
[`firmware/`](./firmware) (a thin wrapper around the
[PicoRuby](https://github.com/picoruby/picoruby) project, with two extra
mrbgems and a small patch added by this repo).

**You write Ruby.** From the user's perspective Board43 is a tiny Ruby
computer: edit a `.rb` file on your laptop, push it to the board over USB,
the LEDs animate. The rest of this guide unpacks every layer between
those two facts.

---

## Part 2 — Hardware

### 2.1 Board43 (the PCB)

Board43 is a **printed circuit board** designed around a **Raspberry Pi
RP2350A** microcontroller, with a fixed set of peripherals soldered onto
specific GPIO pins. The KiCad design files live in [`pcb/`](./pcb).

The peripherals (with their `Board43::*` constant names from firmware):

<!-- markdownlint-disable MD013 -->

| Peripheral                  | What it is                                                           | Pin constant                             |
| --------------------------- | -------------------------------------------------------------------- | ---------------------------------------- |
| **16×16 WS2812 LED matrix** | 256 individually addressable RGB LEDs on a single data line          | `Board43::GPIO_LEDOUT` (GPIO 24)         |
| **LSM6DS3 IMU**             | 3-axis accelerometer + 3-axis gyroscope, over I²C                    | `Board43::GPIO_IMU_SDA` / `GPIO_IMU_SCL` |
| **4 buttons**               | Tactile switches, active-low with pull-ups                           | `Board43::GPIO_SW3` … `GPIO_SW6`         |
| **Piezo buzzer**            | Driven by PWM                                                        | `Board43::GPIO_BUZZER`                   |
| **Status LED**              | Single discrete LED                                                  | `Board43::GPIO_STATUS_LED` (GPIO 25)     |
| **USB-C**                   | Wired directly to the RP2350's USB peripheral                        | (chip-internal)                          |
| **BOOTSEL button**          | Selects between firmware-running mode and mass-storage flashing mode | (chip-internal)                          |

<!-- markdownlint-enable MD013 -->

For an end-to-end example using LEDs + buttons + buzzer together, see
[`workshop/examples/logo.rb`](./workshop/examples/logo.rb).

That's the whole hardware story.
**"Board43" = "RP2350A + this specific peripheral wiring."**

### 2.2 The RP2350A microcontroller

The RP2350A is a **microcontroller** — a single chip that contains a CPU,
RAM, flash interface, and a bunch of peripheral controllers. Specs that
matter:

- **Dual-core ARM Cortex-M33** at up to 150 MHz (also has dual RISC-V cores;
  firmware picks one ISA at boot)
- **520 KB SRAM** (yes, kilobytes — total RAM)
- **No internal flash** — flash is an external QSPI chip on the PCB; the
  chip's own flash interface (XIP) makes it look like memory at `0x10000000`
- **Memory-mapped peripherals** at `0x40000000+` (GPIO, I²C, SPI, UART, PWM,
  DMA, PIO, …)
- **USB 1.1 controller** built in
- **Boot ROM** (a few KB of read-only code burned in at the factory)

Compare to a full Raspberry Pi (Pi 5, etc.): those run Broadcom application
processors, GBs of RAM, and Linux. **The Pico/Board43 world is a separate
product line, sharing only the brand name.** Don't conflate them.

### 2.3 What's already on a freshly-printed board

When you receive a freshly-assembled Board43, the QSPI flash is empty.
**But the chip is not entirely blank** — every RP2350 has a **Boot ROM**
burned into silicon at manufacturing time, and it does exactly one useful
thing on power-on:

> If BOOTSEL is held low (or the flash is empty / corrupt), enumerate over
> USB as a **mass-storage device** named `RPI-RP2`. Drop a `.uf2` file onto
> that drive; the Boot ROM writes it to flash and reboots into it.

This is why microcontroller dev kits don't need flashers, JTAG probes, or
special tools to get started: **the chip is its own flasher over USB.** You
just need a UF2 file and a USB cable.

The Boot ROM also handles a few other things (secure boot, ROM helper
functions Pico SDK can call into) but for our purposes its job is "accept
a UF2."

---

## Part 3 — The Layer Cake

Here's the whole vertical stack on a flashed Board43, top to bottom. Each
layer is examined in the sections that follow.

<!-- markdownlint-disable MD013 -->

```text
┌──────────────────────────────────────────────────────────┐
│  Layer 7   Your Ruby code in /home/app.rb                │  ← what you write
├──────────────────────────────────────────────────────────┤
│  Layer 6   R2P2 (shell, vim, ls, /home/app.rb autorun)   │  ← Ruby on top of layer 5
├──────────────────────────────────────────────────────────┤
│  Layer 5   PicoRuby mrbgems (gpio, i2c, ws2812-plus, …)  │  ← Ruby + C glue
├──────────────────────────────────────────────────────────┤
│  Layer 4   mruby/c VM                                    │  ← C, the Ruby interpreter
├──────────────────────────────────────────────────────────┤
│  Layer 3   newlib (libc) + Pico SDK syscall stubs        │  ← C standard library + glue
├──────────────────────────────────────────────────────────┤
│  Layer 2   Pico SDK (HAL — GPIO, I²C, USB, flash, DMA)   │  ← C, hardware abstraction
├──────────────────────────────────────────────────────────┤
│  Layer 1   RP2350 Boot ROM                               │  ← read-only, factory-burned
├──────────────────────────────────────────────────────────┤
│  Layer 0   RP2350A silicon + Board43 peripherals         │  ← the PCB
└──────────────────────────────────────────────────────────┘
```

<!-- markdownlint-enable MD013 -->

Layers 1-6 are bundled into a single `.uf2` file produced by the firmware
build in [`firmware/`](./firmware). One file, one drag-and-drop, all of it
on the chip.

---

## Part 4 — The Firmware in Detail

This is the part to read if you want to know what *actually* runs on the
chip after flash, what features you have available from Ruby, and what
this repo's patch changes vs. stock upstream.

### 4.1 R2P2 — Ruby Rapid Portable Platform

R2P2 stands for **"Ruby Rapid Portable Platform"** — it's the upstream
PicoRuby project's name for the firmware that turns a Raspberry Pi
Pico/Pico 2 (or in our case, a Pico-2-class board like Board43) into a
self-hosting Ruby device with a serial shell. R2P2 is not a separate
codebase; it's a **mrbgem inside PicoRuby** that ties everything together:

[`firmware/picoruby/mrbgems/picoruby-r2p2/`](./firmware/picoruby) (after
submodule init).

Upstream supports four boards / chip combinations: `pico` (RP2040),
`pico_w` (RP2040 + Wi-Fi), `pico2` (RP2350), and `pico2_w` (RP2350 +
Wi-Fi). Board43 uses the **`pico2`** target — RP2350, no Wi-Fi.

Two Ruby VMs are supported on `pico2`: **mruby/c** (a.k.a. "femtoruby" —
tiny, embedded-friendly) and **mruby** (more capable, larger). Board43
ships the mruby/c flavor — that's what `rake r2p2:picoruby:pico2:prod`
produces.

### 4.2 Boot flow on the chip

The chip cold-boots into a tiny C entry point (Pico SDK's `_entry_point`
→ reset handler → `main`). A few dozen instructions later, control reaches
PicoRuby's startup code, which spawns the mruby/c VM and runs **one Ruby
file** as the entry point:

[`firmware/picoruby/mrbgems/picoruby-r2p2/mrblib/main_task.rb`](./firmware/picoruby)

Boiled down (with the Board43 patch applied), this script:

1. Defines the `Board43` module with all GPIO pin constants (added by the
   patch — see §4.7).
2. `require`s `numeric-ext`, `machine`, `watchdog`, `shell`, `irq`.
3. Disables the hardware watchdog (`Watchdog.disable`).
4. Sets up `STDOUT` and `STDIN` and turns echo off.
5. Sets the hardware clock to `0`.
6. Mounts a **littlefs filesystem** on the QSPI flash and labels it
   `R2P2`: `Shell.setup_root_volume(:flash, label: "R2P2")`.
7. Runs `Shell.setup_system_files` to create `/bin`, `/etc`, etc.
8. Bootstraps `/etc/init.d/r2p2` — this is where the auto-run logic lives
   (see §4.3).
9. Constructs a `Shell` instance, prints the logo, and enters the prompt
   loop: `shell.start`.

From step 9 onward you're talking to a Ruby program over USB-CDC at 115200
baud. **R2P2 isn't a separate process — it's just the first Ruby script
PicoRuby runs.** It happens to be a shell.

### 4.3 Auto-run on boot (and how to skip it)

The `Shell.bootstrap("/etc/init.d/r2p2")` call in the boot flow runs an
executable shipped in the shell mrbgem:

[`firmware/picoruby/mrbgems/picoruby-shell/shell_executables/r2p2.rb`](./firmware/picoruby)

The Board43 patch rewrites this script
([`firmware/picoruby.patch:98-167`](./firmware/picoruby.patch)) to do the
following on every boot:

1. **Escape hatch:** if **SW3 is held low at boot**, skip autostart
   entirely. The status LED blinks rapidly 6 times to confirm, then the
   shell starts normally. This is the "I want to fix a broken app.rb"
   recovery path.
2. Otherwise, look for an app to load, in this order:
   1. `/home/app.mrb` (precompiled mruby bytecode — faster to load)
   2. `/home/app.rb` (Ruby source — compiled at load time)
   3. Whatever `DFU::BootManager.resolve` returns (DFU / OTA boot
      managers, unused on Board43)
3. If an app was found, blink the status LED 10 times (visual "loading"
   indicator), then `load` it with rescues for `Interrupt`, `ScriptError`,
   and `StandardError` — failures fall through to the shell rather than
   bricking the device.
4. If nothing was found, print `"No app found"` and drop straight into the
   shell.

Practical implication: **the way to install a "program" on Board43 is to
write `/home/app.rb`** (which is what the playground's "Install as startup
program" button and `tools/board43.rb push` to that path both do). Hold
SW3 while plugging in to bypass it.

### 4.4 Shell — built-in commands

The R2P2 shell is implemented in
[`firmware/picoruby/mrbgems/picoruby-shell/`](./firmware/picoruby). Each
shell command is a `.rb` file under `shell_executables/`. The set
included in the Board43 build (everything in upstream that isn't gated
behind Wi-Fi/Bluetooth, which Board43 lacks):

<!-- markdownlint-disable MD013 -->

| Category    | Commands                                                                                                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- |
| Filesystem  | `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `cat`, `head`, `tail`                                                         |
| System info | `date`, `df`, `free`, `uptime`, `taskstat`                                                                              |
| REPL/editor | `irb` (interactive Ruby), `vim` (single-file editor)                                                                    |
| Boot/init   | `r2p2` (autorun script — see §4.3), `install`, `setup_rtc`, `setup_sdcard`                                              |
| Networking  | `ifconfig`, `ping`, `ntpdate`, `wifi_connect`, `wifi_disconnect` *(present in the gem but inert on Board43 — no Wi-Fi)* |
| Bluetooth   | `nmble`, `nmcli`, `dfuble`, `dfutcp` *(inert on Board43 — no BT radio)*                                                 |
| DFU         | `dfucat`, `dfucli`                                                                                                      |
| Misc        | `hello`, `rapicco`                                                                                                      |

<!-- markdownlint-enable MD013 -->

The shell also handles a few control-character intercepts at the prompt
([`picoruby-shell/mrblib/shell.rb:417-451`](./firmware/picoruby)):

- **Ctrl-B (`0x02`, STX)** — enters PicoModem mode. See Part 7.
- **Ctrl-C (`0x03`)** — interrupt the running command.
- **Ctrl-D (`0x04`)** — EOF / logout.
- **Ctrl-Z (`0x1A`)** — suspend.

### 4.5 mrbgems baked into the Board43 build

An **mrbgem** is the mruby equivalent of a Ruby gem, but compiled into the
firmware at build time — there's no `gem install` at runtime. Each mrbgem
can contain pure Ruby (compiled to bytecode) and/or C code that calls into
Pico SDK and exposes Ruby classes.

The build recipe for Board43 lives at
`firmware/picoruby/build_config/r2p2-picoruby-pico2.rb`. It pulls in six
**gemboxes** (curated bundles of mrbgems, defined under
`firmware/picoruby/mrbgems/*.gembox`) plus three standalone gems, plus
the two extras added by this repo's patch.

#### From the `minimum` gembox

| mrbgem            | Purpose                         |
| ----------------- | ------------------------------- |
| `mruby-compiler2` | Ruby source → bytecode compiler |
| `picoruby-mrubyc` | The mruby/c VM itself           |

#### From the `core` gembox

<!-- markdownlint-disable MD013 -->

| mrbgem                | Purpose                                               |
| --------------------- | ----------------------------------------------------- |
| `picoruby-require`    | `require` / `load` support                            |
| `picoruby-machine`    | `Machine.*` API: clock, debug puts, reset, build info |
| `picoruby-picorubyvm` | VM introspection                                      |
| `picoruby-time`       | `Time.now` etc.                                       |
| `picoruby-vfs`        | Virtual filesystem layer                              |
| `picoruby-littlefs`   | littlefs driver — the actual on-flash filesystem      |
| `picoruby-watchdog`   | Hardware watchdog control                             |

<!-- markdownlint-enable MD013 -->

#### From the `stdlib` gembox

<!-- markdownlint-disable MD013 -->

| mrbgem                                                       | Purpose                                        |
| ------------------------------------------------------------ | ---------------------------------------------- |
| `picoruby-dfu`                                               | Device Firmware Update / boot manager          |
| `picoruby-rng`                                               | Random number generation                       |
| `picoruby-base16`, `picoruby-base64`                         | Encoding                                       |
| `picoruby-json`, `picoruby-yaml`                             | Data formats                                   |
| `picoruby-eval`                                              | `eval`                                         |
| `picoruby-marshal`                                           | Object serialization                           |
| `picoruby-data`                                              | `Data` value-objects                           |
| `picoruby-logger`                                            | Structured logging                             |
| `picoruby-terminus`                                          | Terminal / ANSI helpers                        |
| `picoruby-karmatic_arcade`                                   | Embedded game-loop helpers (used by `rapicco`) |
| `picoruby-pack`, `picoruby-numeric-ext`, `picoruby-metaprog` | Standard Ruby extensions ported to mruby/c     |
| `picoruby-regexp_light`                                      | Small regex engine                             |

<!-- markdownlint-enable MD013 -->

#### From the `shell` gembox

| mrbgem              | Purpose                                       |
| ------------------- | --------------------------------------------- |
| `picoruby-shell`    | The R2P2 shell (commands listed in §4.4)      |
| `picoruby-picoline` | Line editor / readline-equivalent             |
| `picoruby-vim`      | On-device single-file vim                     |
| `picoruby-rapicco`  | `rapicco` — terminal slide-show / demo runner |

#### From the `peripherals` gembox

This is where Ruby gets to talk to hardware. All wrap Pico SDK HAL calls.

<!-- markdownlint-disable MD013 -->

| mrbgem          | Ruby API exposed                                                          |
| --------------- | ------------------------------------------------------------------------- |
| `picoruby-gpio` | `GPIO.new(pin, mode)`, `#read`, `#write`, `#low?`, `#high?`               |
| `picoruby-i2c`  | `I2C.new(unit:, sda_pin:, scl_pin:, frequency:)`                          |
| `picoruby-spi`  | `SPI.new(...)`                                                            |
| `picoruby-adc`  | `ADC.new(pin)`                                                            |
| `picoruby-uart` | `UART.new(...)`                                                           |
| `picoruby-pwm`  | `PWM.new(pin, frequency:, duty:)` — used for the buzzer                   |
| `picoruby-irq`  | Interrupt handlers                                                        |
| `picoruby-pio`  | Programmable I/O state machines (the trick used to clock the WS2812 LEDs) |

<!-- markdownlint-enable MD013 -->

#### From the `peripheral_utils` gembox

| mrbgem          | Purpose                                 |
| --------------- | --------------------------------------- |
| `picoruby-vram` | Frame-buffer / VRAM helper for displays |

#### Standalone (added by name in the build config)

<!-- markdownlint-disable MD013 -->

| mrbgem               | Purpose                                                       |
| -------------------- | ------------------------------------------------------------- |
| `picoruby-psg`       | Programmable Sound Generator — chiptune square-wave synth     |
| `picoruby-shinonome` | Shinonome bitmap font (used for text-on-LED-matrix rendering) |
| `picoruby-keyboard`  | Keyboard / matrix-input helper                                |

<!-- markdownlint-enable MD013 -->

#### Added by **this repo**'s patch (Board43 only)

<!-- markdownlint-disable MD013 -->

| mrbgem                 | Purpose                                                            | Source                                                                                   |
| ---------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `picoruby-ws2812-plus` | `WS2812.new(pin:, num:)`, `#fill`, `#set_rgb`, `#show`, animations | [github.com/ksbmyk/picoruby-ws2812-plus](https://github.com/ksbmyk/picoruby-ws2812-plus) |
| `picoruby-lsm6ds3`     | Accelerometer + gyroscope reads over I²C                           | [github.com/0x6b/picoruby-lsm6ds3](https://github.com/0x6b/picoruby-lsm6ds3)             |

<!-- markdownlint-enable MD013 -->

These two are why the LED matrix and IMU "just work" from Ruby on Board43.

#### Worked example — the call chain when you light an LED

```text
Ruby:    WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256).fill(255, 0, 0).show
  ↓ (mruby/c method dispatch)
C:       ws2812_plus_init() / show() in picoruby-ws2812-plus
  ↓ (Pico SDK HAL call)
C:       pio_sm_config_*, pio_sm_set_enabled(), pio_sm_put_blocking(...)
  ↓ (writes to PIO peripheral registers)
HW:      RP2350 PIO state machine generates WS2812 bit-stream on GPIO 24
  ↓ (single-wire 800 kHz protocol)
LEDs:    256 RGB pixels latch the new color values
```

The PIO is the trick. WS2812 timing (~1.25 µs per bit) is too tight for
software bit-banging at any reasonable CPU usage — the RP2040/RP2350 PIO
state machines bit-bang it in dedicated silicon and the mrbgem hides all
of that.

### 4.6 What this repo adds on top of stock PicoRuby

Everything in this repo's [`firmware/`](./firmware) is a thin wrapper
around the upstream PicoRuby submodule. The deltas live in two places —
[`firmware/setup.sh`](./firmware/setup.sh) and the patch
[`firmware/picoruby.patch`](./firmware/picoruby.patch). The patch is
applied verbatim during setup and contains five distinct changes:

1. **Two extra mrbgems wired into the build config** — `picoruby-ws2812-plus`
   and `picoruby-lsm6ds3`, the LED-matrix and IMU drivers (patch lines
   1-13). Without these, Board43's two most distinctive peripherals would
   be unreachable from Ruby.

2. **A build-date suffix that includes time + "SB"** in the version
   string (patch lines 14-35, 36-55). The unmodified upstream stamp is
   `YYYY-MM-DD`; Board43 builds report
   `YYYY-MM-DD HH:MM:SS SB` in the version banner and append `-SB` to the
   project name in CMake. Lets you tell a Board43 firmware apart from a
   stock PicoRuby build at a glance.

3. **The `Board43` Ruby module** with all the pin constants (patch lines
   56-72). Defined directly in `main_task.rb` so it's available globally
   from the very first user-script load. See §4.7.

4. **A status-LED-on init in the C boot path** (patch lines 76-95). Stock
   PicoRuby pulls all GPIOs 17-29 to input-pull-down at boot. The patch
   excludes pin 25 from that loop and explicitly drives it high — so the
   green status LED lights up the moment the chip boots, before any Ruby
   has run. Useful as a "yes, the firmware is alive" signal even when the
   shell hasn't come up yet.

5. **A custom autorun script** (patch lines 96-167) — replaces the stock
   `r2p2.rb` autorun with the Board43 version: SW3 escape hatch,
   status-LED blink before app load, exception rescuing. Discussed in
   §4.3.

The patch is small (~110 net additions). Everything else — the entire
shell, the VM, the standard library, the peripheral drivers, R2P2 itself
— comes from upstream PicoRuby unchanged.

### 4.7 The `Board43` module — pin constants

Defined in the patch ([`firmware/picoruby.patch:60-72`](./firmware/picoruby.patch)),
loaded as the very first thing in `main_task.rb` so it's available
everywhere:

```ruby
module Board43
  GPIO_BUZZER     = 11
  GPIO_SW3        = 15
  GPIO_SW4        = 14
  GPIO_SW5        = 12
  GPIO_SW6        = 13
  GPIO_IMU_SDA    = 16
  GPIO_IMU_SCL    = 17
  GPIO_LEDOUT     = 24
  GPIO_STATUS_LED = 25
end
```

It's pure constants — no methods, no classes. Apps write
`Board43::GPIO_LEDOUT` instead of literal `24` to keep code readable and
pin assignments in one place. If the PCB ever respins with different pins,
only this module changes.

For the canonical API surface using these constants, see the workshop
examples — each demonstrates one peripheral cleanly:

<!-- markdownlint-disable MD013 -->

| Example                                                                | Demonstrates                                |
| ---------------------------------------------------------------------- | ------------------------------------------- |
| [`workshop/examples/status_led.rb`](./workshop/examples/status_led.rb) | GPIO output (status LED)                    |
| [`workshop/examples/button.rb`](./workshop/examples/button.rb)         | GPIO input with pull-up (the four switches) |
| [`workshop/examples/buzzer.rb`](./workshop/examples/buzzer.rb)         | PWM (the piezo buzzer)                      |
| [`workshop/examples/imu.rb`](./workshop/examples/imu.rb)               | I²C (the IMU)                               |
| [`workshop/examples/led_matrix.rb`](./workshop/examples/led_matrix.rb) | WS2812 (the LED matrix)                     |
| [`workshop/examples/logo.rb`](./workshop/examples/logo.rb)             | LEDs + buttons + buzzer together            |
| [`workshop/examples/snake_game.rb`](./workshop/examples/snake_game.rb) | A full mini-game                            |
| [`workshop/examples/theremin.rb`](./workshop/examples/theremin.rb)     | LEDs + IMU + buzzer (motion → sound)        |

<!-- markdownlint-enable MD013 -->

---

## Part 5 — Building the Firmware

### 5.1 What the build produces

A single `.uf2` file: `R2P2-PICORUBY-*.uf2` (~1-2 MB). It contains,
statically linked:

- newlib (from the ARM cross-toolchain — not in this repo)
- Pico SDK (HAL + libc stubs)
- mruby/c VM
- All the mrbgems baked in (see §4.5)
- R2P2 Ruby code, precompiled to mrb bytecode and embedded as C arrays

There are no shared libraries, no dynamic linker, no `.so` files at runtime.
**One self-contained binary.**

### 5.2 Where the build lives

PicoRuby is a **git submodule** at
[`firmware/picoruby`](./firmware/picoruby). Pico SDK and Pico Extras are
**nested submodules under it** (so they get the version PicoRuby's Rakefile
expects):

```text
firmware/
├── picoruby/                                    # submodule: github.com/picoruby/picoruby
│   ├── build_config/r2p2-picoruby-pico2.rb      # build recipe
│   ├── mrbgems/picoruby-r2p2/                   # R2P2 (the "OS" Ruby code)
│   │   └── lib/pico-sdk/                        # nested submodule: Pico SDK
│   │   └── lib/pico-extras/                     # nested submodule: Pico Extras
│   └── …
├── picoruby.patch                               # Board43-specific changes
└── setup.sh                                     # wires it all up
```

### 5.3 First-time setup

From [`firmware/`](./firmware):

```console
./setup.sh
```

Which runs (see [`firmware/setup.sh`](./firmware/setup.sh)):

1. `git submodule update --init --recursive` inside `picoruby/` — pulls
   PicoRuby's own submodules
2. `bundle install` — installs Ruby gems the build needs (mainly `rake`)
3. `rake r2p2:setup` — pulls the **nested** submodules (Pico SDK, Pico
   Extras) at the tags PicoRuby's Rakefile expects (e.g. `sdk-2.2.0`)
4. `git apply ../picoruby.patch` — applies the Board43 changes

> **Subtlety:** don't replace step 3 with
> `git submodule update --recursive`. The Rakefile pins specific tagged
> releases of Pico SDK/Extras; recursive submodule init grabs whatever
> commit the parent points at, which has caused build breakage upstream.

### 5.4 Building locally

From `firmware/picoruby`:

```console
export PICO_SDK_PATH=$(pwd)/mrbgems/picoruby-r2p2/lib/pico-sdk
export PICO_EXTRAS_PATH=$(pwd)/mrbgems/picoruby-r2p2/lib/pico-extras
rake r2p2:picoruby:pico2:prod
```

Output: `build/r2p2/picoruby/pico2/prod/R2P2-PICORUBY-*.uf2`.

System prereqs (apt names; CI uses these): `cmake`, `gcc-arm-none-eabi`,
`libnewlib-arm-none-eabi`, `libstdc++-arm-none-eabi-newlib`. The
`arm-none-eabi-gcc` toolchain ships newlib — **that's where the libc comes
from**, not from Pico SDK.

### 5.5 Releasing via CI

Push a tag matching `firmware-YYYY-MM-DD-NN` (two-digit sequence) to trigger
[`.github/workflows/build-firmware.yml`](./.github/workflows/build-firmware.yml).
The workflow runs the same `setup.sh` + `rake` flow, then attaches the UF2
to a GitHub Release.

```console
git tag firmware-2026-04-26-01
git push origin firmware-2026-04-26-01
```

`workflow_dispatch` is also accepted (build without releasing).

---

## Part 6 — Connecting and Developing

### 6.1 First flash

1. Hold **BOOTSEL** while plugging USB in. The Boot ROM enumerates
   `RPI-RP2` as a USB drive.
2. Drag a `R2P2-PICORUBY-*.uf2` onto it (download from Releases, or build
   yourself).
3. The chip writes flash, reboots, and now enumerates as a USB-CDC serial
   device at `/dev/tty.usbmodem*` (macOS) / `/dev/ttyACM*` (Linux) / a
   `COM*` port (Windows).

After this first flash, BOOTSEL is only needed to *re-flash the firmware
itself*. Day-to-day app development never touches it.

### 6.2 Three development workflows

#### Workflow A — Direct serial terminal

Open any serial terminal at **115200 8N1** and you get the R2P2 shell:

```console
$ tio /dev/tty.usbmodem* -b 115200       # or screen, picocom, minicom
R2P2> ls /home
R2P2> vim /home/blink.rb
R2P2> ./blink.rb
```

Good for exploration and one-shot experiments. Bad for git-tracked projects.

#### Workflow B — Browser playground

[`playground/`](./playground) is a React 19 + TypeScript SPA. It uses:

- **Web Serial API** (Chrome/Edge) to connect to the device
- **PicoModem**
  ([`playground/src/utils/picomodem.ts`](./playground/src/utils/picomodem.ts))
  to push files
- `@picoruby/wasm-wasi` to run a **simulator** in-browser when no device is
  connected
- Local Rust crate
  [`board43-image-transformer`](./playground/lib/board43-image-transformer/)
  (compiled to WASM) to convert images to 16×16 RGB pixel data

Run with:

```console
cd playground && pnpm install && pnpm dev
```

The "Run on Device" button does `FILE_WRITE` your buffer to a temp path
then `RUN_FILE` it. "Install as startup program" does `FILE_WRITE` to
`/home/app.rb`.

#### Workflow C — CLI (`tools/board43.rb`)

A Ruby CLI that speaks PicoModem from your shell, no browser needed. See
[`tools/board43.rb`](./tools/board43.rb):

```console
ruby tools/board43.rb push path/to/blink.rb /home/blink.rb --run
ruby tools/board43.rb pull /home/app.rb
ruby tools/board43.rb run /home/blink.rb
```

Auto-detects `/dev/cu.usbmodem*`. Uses `bundler/inline` to install the
`serialport` gem on first run.

---

## Part 7 — PicoModem: protocol reference

PicoModem is a binary file-transfer + remote-exec protocol that R2P2
implements on the device side. It's named after XMODEM/YMODEM, but the
protocol itself is Board43-/PicoRuby-specific. Source on the device:
[`firmware/picoruby/mrbgems/picoruby-picomodem/mrblib/picomodem.rb`](./firmware/picoruby).

**It's not Ruby-specific.** It's a generic byte-transport with one "execute
this path" primitive. Could be used to push any file (config, binary, text)
to any path.

### 7.1 Two reference implementations in this repo

- TypeScript / Web Serial:
  [`playground/src/utils/picomodem.ts`](./playground/src/utils/picomodem.ts)
  (487 lines)
- Ruby / serialport gem: [`tools/board43.rb`](./tools/board43.rb)

Both speak the same wire format.

### 7.2 Entering a session

The R2P2 shell normally treats serial bytes as terminal input. To switch
into binary mode:

1. Client writes `STX` (`0x02`) — Ctrl-B.
2. Device responds with `ACK` (`0x06`) on the same serial stream.
3. Client now sends framed commands; device responds with framed responses.

After one operation completes (or `ABORT` is sent), the device returns to
shell mode.

### 7.3 Frame format

```text
┌─────┬──────────────┬─────┬─────────┬──────────┐
│ STX │ length (BE)  │ cmd │ payload │ CRC-16   │
│ 0x02│  2 bytes     │  1  │  N bytes│  2 bytes │
└─────┴──────────────┴─────┴─────────┴──────────┘
```

- **`length`** = `1 + len(payload)` — covers `cmd` byte + payload,
  big-endian
- **CRC-16/CCITT** with initial value `0xFFFF`, polynomial `0x1021`,
  computed over `cmd + payload`

### 7.4 Commands

<!-- markdownlint-disable MD013 -->

| Direction | Command       | Code   | Payload                                              |
| --------- | ------------- | ------ | ---------------------------------------------------- |
| C→D       | `FILE_READ`   | `0x01` | path bytes                                           |
| C→D       | `FILE_WRITE`  | `0x02` | 4-byte BE size + path bytes                          |
| C→D       | `CHUNK`       | `0x04` | up to 480-512 bytes of file data                     |
| C→D       | `DELETE_FILE` | `0x06` | path bytes                                           |
| C→D       | `RUN_FILE`    | `0x07` | path bytes                                           |
| C→D       | `ABORT`       | `0xFF` | (none)                                               |
| D→C       | `FILE_DATA`   | `0x81` | first frame: 4-byte BE size + data; subsequent: data |
| D→C       | `FILE_ACK`    | `0x82` | status byte (`READY`=`0x01`)                         |
| D→C       | `CHUNK_ACK`   | `0x84` | status byte (`OK`=`0x00`)                            |
| D→C       | `DELETE_ACK`  | `0x86` | status byte                                          |
| D→C       | `RUN_ACK`     | `0x87` | status byte                                          |
| D→C       | `DONE_ACK`    | `0x8F` | status + 4-byte BE CRC-32 of full file               |
| D→C       | `ERROR`       | `0xFE` | UTF-8 error message                                  |

<!-- markdownlint-enable MD013 -->

### 7.5 File-write flow

```text
client                                              device
  │                                                   │
  │── STX (0x02) ────────────────────────────────────▶│
  │◀────────────────────────────────────── ACK (0x06)─│
  │── FILE_WRITE [size_be32, path] ──────────────────▶│
  │◀──────────────────────────── FILE_ACK [READY=0x01]│
  │── CHUNK [up to 480 bytes] ───────────────────────▶│
  │◀────────────────────────────── CHUNK_ACK [OK=0x00]│
  │   …repeat until all data sent…                    │
  │◀──────────────────── DONE_ACK [OK + crc32_be32] ──│
  │  client verifies CRC-32 matches its own           │
```

### 7.6 USB-CDC pacing quirk

USB-CDC drops bytes on the floor if you spam too fast. Both implementations
send in **32-byte blocks with a 20 ms gap** between blocks
([`picomodem.ts:27-29`](./playground/src/utils/picomodem.ts),
[`board43.rb:46-47`](./tools/board43.rb)). If you write your own client,
replicate this — without it, large writes fail intermittently.

### 7.7 Integrity

Two layers of checksum:

- **Per frame**: CRC-16/CCITT covers the framed body
- **Per file** (write & read): CRC-32 in `DONE_ACK` covers the full file
  payload

A frame whose CRC-16 doesn't match is rejected as corrupt; a file whose
CRC-32 doesn't match is rejected even if every frame was individually fine.
Both layers use little-overhead CRCs because that's all USB-CDC needs (it
has its own link-layer error detection).

---

## Part 8 — Where Each Concern Lives (jump table)

Quick reference for "I want to change X — where do I look?"

<!-- markdownlint-disable MD013 -->

| Concern                                 | Path                                                                                      |
| --------------------------------------- | ----------------------------------------------------------------------------------------- |
| Hardware design (schematic, layout)     | [`pcb/`](./pcb)                                                                           |
| Firmware build entry point              | [`firmware/setup.sh`](./firmware/setup.sh)                                                |
| Board43-specific firmware patches       | [`firmware/picoruby.patch`](./firmware/picoruby.patch)                                    |
| PicoRuby itself (submodule)             | [`firmware/picoruby/`](./firmware/picoruby)                                               |
| Build recipe for `pico2:prod`           | `firmware/picoruby/build_config/r2p2-picoruby-pico2.rb`                                   |
| R2P2 ("OS") source                      | `firmware/picoruby/mrbgems/picoruby-r2p2/`                                                |
| R2P2 entry script                       | `firmware/picoruby/mrbgems/picoruby-r2p2/mrblib/main_task.rb`                             |
| Autorun / app.rb logic                  | `firmware/picoruby/mrbgems/picoruby-shell/shell_executables/r2p2.rb`                      |
| Shell command implementations           | `firmware/picoruby/mrbgems/picoruby-shell/shell_executables/`                             |
| LED driver mrbgem                       | external: `github.com/ksbmyk/picoruby-ws2812-plus`                                        |
| IMU driver mrbgem                       | external: `github.com/0x6b/picoruby-lsm6ds3`                                              |
| Firmware CI                             | [`.github/workflows/build-firmware.yml`](./.github/workflows/build-firmware.yml)          |
| Reference manual (Typst source)         | [`docs/reference-manual/main.typ`](./docs/reference-manual/main.typ)                      |
| Reference manual compiler (Rust)        | [`docs/src/main.rs`](./docs/src/main.rs)                                                  |
| Browser playground (React)              | [`playground/`](./playground)                                                             |
| Image-to-RGB Rust crate                 | [`playground/lib/board43-image-transformer/`](./playground/lib/board43-image-transformer) |
| PicoModem (TypeScript)                  | [`playground/src/utils/picomodem.ts`](./playground/src/utils/picomodem.ts)                |
| PicoModem (Ruby CLI)                    | [`tools/board43.rb`](./tools/board43.rb)                                                  |
| Workshop examples (canonical API usage) | [`workshop/examples/`](./workshop/examples)                                               |

<!-- markdownlint-enable MD013 -->

---

## Part 9 — Mental Models to Keep

Distilled from this guide; each is one-sentence:

1. **Board43 = RP2350A + a fixed peripheral wiring on a PCB.** Nothing
   more, nothing less.
2. **The Boot ROM makes the chip its own flasher.** No external tools
   needed to load firmware.
3. **The firmware is the OS.** R2P2 isn't UNIX-derived — it's
   UNIX-*shaped* on top of a Ruby VM.
4. **The Ruby VM is the kernel.** R2P2 runs *inside* PicoRuby, not on top
   of it — same address space, same binary, same heartbeat.
5. **libc and HAL are independent concerns** that happen to live next to
   each other on a microcontroller. libc is the C standard API (newlib for
   us); HAL (Pico SDK) wraps the chip's hardware. Stubs are the
   strategy-pattern slot bridging libc to the platform.
6. **PicoModem = byte transport + one "exec this path" primitive.**
   Generic, not Ruby-specific.
7. **The browser playground is just a PicoModem client.** Anything it
   does, a CLI can do too — `tools/board43.rb` proves it.

---

## Appendix A — libc, HAL, Stubs (the foundational C concepts)

This appendix is the conceptual scaffolding you need to read the firmware
sources. Skip if you already know it.

### A.1 libc

**libc** is shorthand for "the C standard library" — the functions every C
program assumes exist: `printf`, `malloc`, `strlen`, `memcpy`, `qsort`,
file I/O, math, etc. The **API** is fixed by the ISO C standard. The
**implementation** is not — multiple libcs exist:

| Implementation               | Where you see it                              |
| ---------------------------- | --------------------------------------------- |
| **glibc**                    | Default Linux distros                         |
| **musl**                     | Alpine Linux, static binaries                 |
| **Apple libSystem**          | macOS                                         |
| **MSVCRT / UCRT**            | Windows                                       |
| **newlib** / **newlib-nano** | Embedded / bare-metal — **what Board43 uses** |

Different libcs exist not because ISO C functions are hard, but because each
libc *also* bundles platform-specific things beyond ISO C: POSIX, threading,
networking, locales, dynamic linking, etc. ISO C is universal; the rest is
platform-flavored.

newlib is designed for bare-metal / embedded — minimal, makes no assumptions
about a kernel. That's why it ships with the ARM toolchain
(`arm-none-eabi-gcc`) and not with Pico SDK.

### A.2 Stubs (a.k.a. "syscall stubs" or "newlib stubs")

When you call `printf("hello")`, libc formats the bytes, then needs to
actually push them somewhere. On a hosted OS, libc traps into the kernel via
a **syscall**. On bare metal there is no kernel — so libc calls a small set
of hand-implemented functions called **stubs**:

```c
_write(fd, buf, len)    // "send these bytes somewhere"
_read(fd, buf, len)     // "give me bytes from somewhere"
_sbrk(incr)             // "grow the heap by N bytes"
_close(fd)              // "close this file"
_fstat(fd, st)          // "info about this file"
// …a few more
```

newlib ships **placeholder versions** of these that return
`-1, errno=ENOSYS`. They compile and link but do nothing — that's the
literal "stub" meaning. The board integrator (Pico SDK in our case)
**overrides** them with real implementations:

```c
// What Pico SDK provides (simplified):
int _write(int fd, char *buf, int len) {
    if (fd == 1 || fd == 2) {        // stdout / stderr
        stdio_usb_out_chars(buf, len);
        return len;
    }
    errno = EBADF;
    return -1;
}
```

The override happens at **link time**: newlib's defaults are marked as weak
symbols, the linker prefers Pico SDK's strong definition, and the final
binary points `printf`'s call site at the real one. **Strategy pattern,
wired by the linker, not by a runtime DI container.**

After override, the function is still *called* "the `_write` syscall stub" —
that's the name of the slot, not a comment on quality. The slot is real,
the implementation is real, "stub" just stuck around as the name.

### A.3 HAL (Hardware Abstraction Layer)

A separate idea from libc. The RP2350's peripherals are controlled by
**memory-mapped registers** — special memory addresses where reads/writes
manipulate hardware:

```c
// Without HAL — datasheet-driven, raw register access:
*((volatile uint32_t*)0xD0000024) = (1 << 24);   // GPIO 24 enable output
*((volatile uint32_t*)0xD0000010) = (1 << 24);   // GPIO 24 set high
```

A HAL wraps these in friendlier function calls:

```c
// With HAL (Pico SDK):
gpio_init(24);
gpio_set_dir(24, GPIO_OUT);
gpio_put(24, 1);
```

A HAL replaces "read the 800-page chip datasheet" with "call this function."
It's chip-specific (Pico SDK only knows RP2040/RP2350) but
architecture-flexible (works whether you compile in ARM or RISC-V mode).

### A.4 So what is Pico SDK, exactly?

[Pico SDK](https://github.com/raspberrypi/pico-sdk) is Raspberry Pi's
official C library for the RP2040/RP2350 chips. Three things:

1. **A HAL for RP2040/RP2350 peripherals.** The bulk of it. GPIO, I²C, SPI,
   UART, PWM, ADC, DMA, PIO, timers, flash, multicore, clocks. Same API
   works on every board built around these chips.
2. **Higher-level libraries** that build on the HAL: USB stack (TinyUSB
   wrapped), stdio routing, multicore sync, async helpers, board
   configuration headers, CMake build glue.
3. **Newlib syscall stubs.** A small file (~100 lines out of tens of
   thousands) that fills in `_write`/`_read`/`_sbrk`/etc. so libc functions
   actually work on the RP2350.

Pico SDK is *not* a libc. It's the HAL + the plumbing that makes the
toolchain's libc (newlib) functional on this specific chip family.

### A.5 The relationship visualized

```text
Ruby code in /home/app.rb
        ↓
mruby/c VM  (C code) — calls printf/malloc/memcpy/...
        ↓
newlib (libc)  — formats strings, manages heap, …
        ↓  delegates I/O via stubs:
        ↓  _write(...)        _read(...)        _sbrk(...)
Pico SDK  — provides those stubs + a fat HAL:
        ↓  gpio_put(24, 1);   pio_sm_put(...);   usb_cdc_write(...);
        ↓
RP2350 silicon (registers at 0x40000000+, 0xD0000000+, …)
```

Two parallel concerns sit at the same conceptual level:

- **libc + stubs** is about the C standard API on top of an embedded chip.
  Abstract things like "write to stdout."
- **HAL** is about giving Ruby's mrbgems a clean way to poke at hardware.
  Concrete things like "set GPIO 24 high."

Pico SDK ships both because both are needed; conceptually they're
independent.
