# The Definitive Board43 Guide

A from-the-ground-up walkthrough of Board43: what the hardware is, what runs
on it, why, and how to develop for it. Assumes no prior microcontroller
experience — bring software-engineering literacy and we'll build up from
silicon to your Ruby code.

---

## Part 1 — Background

### 1.1 What "Board43" actually is

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
| **Status LED**              | Single discrete LED                                                  | `Board43::GPIO_LED_STATUS`               |
| **USB-C**                   | Wired directly to the RP2350's USB peripheral                        | (chip-internal)                          |
| **BOOTSEL button**          | Selects between firmware-running mode and mass-storage flashing mode | (chip-internal)                          |

<!-- markdownlint-enable MD013 -->

The peripherals you can see in workshop code: see
[`workshop/examples/logo.rb`](./workshop/examples/logo.rb) for everything
used together.

That's the whole hardware story.
**"Board43" = "RP2350A + this specific peripheral wiring."**

### 1.2 What the RP2350A is

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

### 1.3 What's already on a freshly-printed board

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

## Part 2 — The Layer Cake

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

## Part 3 — libc, HAL, Stubs (the foundational C concepts)

This section is the conceptual scaffolding you need to read the firmware.
Skip if you already know it.

### 3.1 libc

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

### 3.2 Stubs (a.k.a. "syscall stubs" or "newlib stubs")

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

### 3.3 HAL (Hardware Abstraction Layer)

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

### 3.4 So what is Pico SDK, exactly?

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

### 3.5 The relationship visualized

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

---

## Part 4 — Firmware: the Build

### 4.1 What the build produces

A single `.uf2` file: `R2P2-PICORUBY-*.uf2` (~1-2 MB). It contains,
statically linked:

- newlib (from the ARM cross-toolchain — not in this repo)
- Pico SDK (HAL + libc stubs)
- mruby/c VM
- All the mrbgems baked in (see §5.2)
- R2P2 Ruby code, precompiled to mrb bytecode and embedded as C arrays

There are no shared libraries, no dynamic linker, no `.so` files at runtime.
**One self-contained binary.**

### 4.2 Where the build lives

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

The patch ([`firmware/picoruby.patch`](./firmware/picoruby.patch)) does two
things:

1. **Adds two extra mrbgems** to `build_config/r2p2-picoruby-pico2.rb`:
   - [`picoruby-ws2812-plus`](https://github.com/ksbmyk/picoruby-ws2812-plus)
     — driver for the LED matrix
   - [`picoruby-lsm6ds3`](https://github.com/0x6b/picoruby-lsm6ds3)
     — driver for the IMU
2. **Tweaks the build-date stamp** in `lib/picoruby/build.rb` to include
   time + an "SB" suffix (so Board43 builds are identifiable in `version`).

If you modify the patch, regenerate it from the submodule working tree —
CI applies it verbatim.

### 4.3 First-time setup

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

### 4.4 Building locally

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

### 4.5 Releasing via CI

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

## Part 5 — Firmware: the Runtime

### 5.1 What's running on the chip after flash

The chip cold-boots into a tiny C entry point (Pico SDK's `_entry_point` →
reset handler → `main`). A few dozen instructions later, control reaches
PicoRuby's startup code, which:

1. Initializes USB-CDC so the chip enumerates as a serial device
2. Mounts a **littlefs filesystem** on a region of QSPI flash (a real
   read-write filesystem in the chip's flash chip, separate from the
   firmware code region)
3. Spawns the mruby/c VM
4. Runs R2P2's Ruby entry script
5. R2P2 either drops to a shell prompt over USB-CDC, or auto-runs
   `/home/app.rb` if present

Everything from step 4 onward is Ruby code being interpreted by the C VM.
**R2P2 is not a separate process — it's just the first Ruby program
PicoRuby runs.** It happens to be a shell.

### 5.2 mrbgems — the binding between Ruby and C

An **mrbgem** is the mruby equivalent of a Ruby gem, but compiled into the
firmware at build time. Each mrbgem can contain:

- Pure Ruby code (compiled to bytecode)
- C code that calls into Pico SDK and exposes Ruby classes/methods

The build config that lists which mrbgems are included for the
Board43-targeted build:
`firmware/picoruby/build_config/r2p2-picoruby-pico2.rb` (see the patch in
[`firmware/picoruby.patch:5-10`](./firmware/picoruby.patch) for the
additions).

Roughly:

<!-- markdownlint-disable MD013 -->

| mrbgem                              | What it gives Ruby                                      |
| ----------------------------------- | ------------------------------------------------------- |
| `picoruby-gpio`                     | `GPIO.new(pin, mode)`, `#read`/`#write`                 |
| `picoruby-i2c`                      | `I2C.new(unit:, sda_pin:, scl_pin:)`                    |
| `picoruby-pwm`                      | `PWM.new(pin, frequency:, duty:)`                       |
| `picoruby-ws2812-plus`              | `WS2812.new(pin:, num:)`, `#fill`, `#set_rgb`, `#show`  |
| `picoruby-lsm6ds3`                  | accelerometer + gyro reads over I²C                     |
| `picoruby-r2p2`                     | the shell, filesystem, vim, picomodem                   |
| `picoruby-shinonome`                | bitmap font (used for scrolling text on the LED matrix) |
| `picoruby-keyboard`, `picoruby-psg` | other utilities                                         |

<!-- markdownlint-enable MD013 -->

When `workshop/examples/led_matrix.rb` calls
`WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256)`, the call chain is:

```text
Ruby: WS2812.new(...)
  ↓ (mruby/c dispatch)
C: ws2812_plus_init() in picoruby-ws2812-plus
  ↓ (Pico SDK HAL call)
C: pio_sm_config_*, pio_sm_set_enabled() in Pico SDK
  ↓ (register writes)
RP2350 PIO peripheral generates the WS2812 protocol on GPIO 24
```

The PIO (Programmable I/O) is one of the RP2350's coolest features — small
state machines that can bit-bang exotic protocols at line rate. WS2812
timing is too tight for software, so PIO does it. You don't need to know
that to write apps; the mrbgem hides it.

### 5.3 R2P2 — the "OS"

R2P2 is **Ruby code running inside PicoRuby** that *behaves* like a
UNIX-shaped operating system. Source lives upstream at
[`firmware/picoruby/mrbgems/picoruby-r2p2/`](./firmware/picoruby) (after
submodule init). It provides:

- A shell prompt over USB-CDC at 115200 8N1
- POSIX-shaped commands: `ls`, `cd`, `cp`, `mv`, `rm`, `cat`, `mkdir`, `pwd`
- An on-device `vim` (single-file editor)
- An `irb`-like Ruby REPL
- A littlefs filesystem mounted at `/`
- The convention that **`/home/app.rb` auto-runs at boot** if present
- **PicoModem** — a binary protocol entered by sending Ctrl-B (0x02) at the
  prompt

The R2P2 "OS" is **fundamentally not UNIX-derived**. Zero shared code. It's
UNIX-*shaped* because the metaphors (paths, shell, vim) are familiar.
Conceptually closer to MicroPython, CircuitPython, or Espruino — same
product category, different language.

What R2P2 deliberately does **not** provide:

- Processes (single address space, one task at a time)
- Virtual memory / MMU (raw physical addresses everywhere)
- Preemptive multitasking (mruby/c has cooperative tasks, rarely used)
- User/kernel privilege split
- Dynamic loading (no `gem install` at runtime — every mrbgem is baked in)
- Networking (no Wi-Fi/Ethernet on Board43)

This is why it fits in ~1-2 MB and boots instantly.

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
ruby tools/board43.rb push my-apps/blink.rb /home/blink.rb --run
ruby tools/board43.rb pull /home/app.rb
ruby tools/board43.rb run /home/blink.rb
```

Auto-detects `/dev/cu.usbmodem*`. Uses `bundler/inline` to install the
`serialport` gem on first run.

### 6.3 Personal apps (this repo)

Per [`CLAUDE.md`](./CLAUDE.md) and stored memory: Okarin's own PicoRuby
apps go in [`my-apps/`](./my-apps), not `workshop/examples/`. Existing apps:

- `billboard.rb`, `kirby_animation.rb`, `kirby_song.rb`, `live_repl.rb`,
  `midi_song.rb`, `undertale_battle.rb`, `songs/`

The workshop directory ([`workshop/examples/`](./workshop/examples)) is
reserved for the official workshop material and is the best reference for
the API surface — see `logo.rb` for an end-to-end example using LEDs +
buttons + buzzer.

---

## Part 7 — PicoModem: protocol reference

PicoModem is a binary file-transfer + remote-exec protocol that R2P2
implements on the device side. It's named after XMODEM/YMODEM, but the
protocol itself is Board43-/PicoRuby-specific.

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
| Personal apps                           | [`my-apps/`](./my-apps)                                                                   |

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
