# `tools/board43` rewrite — progress and handoff

Cleanly designed, well-tested rewrite of `tools/board43.rb` (the Ruby CLI
that pushes files to a Board43 device over USB serial via the PicoModem
binary protocol). Working with **Okarin** (the user). TDD throughout —
Kent-Beck style: one failing test at a time, smallest change for green,
then refactor.

---

## Where things stand

### Classes that exist

```
tools/
├── lib/
│   ├── board43.rb            # Domain class — one method per CLI verb
│   ├── clock.rb              # Wall-clock dependency (real, for production)
│   ├── pico_modem_frame.rb   # Frame value object + parser
│   └── serial.rb             # Production Serial wrapper around `serialport` gem
├── test/
│   ├── board43_test.rb       # The centerpiece — drives Board43 through fakes
│   ├── test_helper.rb
│   └── support/
│       ├── fake_clock.rb     # Test double for Clock (advances `now` on sleep)
│       ├── fake_device.rb    # Test stand-in for a real Board43 + R2P2
│       └── fake_serial.rb    # Test stand-in for Serial (inherits Serial)
├── Gemfile / Gemfile.lock    # `serialport`, `minitest` (test group)
├── board43                   # bash wrapper — currently still points at the old board43.rb
└── board43.rb                # OLD CLI — still in place, untouched. To be replaced
                              # once the rewrite is feature-complete.
```

The old `tools/board43.rb` (the script being rewritten) is *still the
shipping CLI*. Nothing under `lib/`, `test/`, or `bin/` is wired into the
`tools/board43` bash wrapper yet. That's the final cutover step.

### Currently working: `push`

The new `Board43` class implements one CLI verb so far: `push(local_paths)`
— uploads each file to `/home/<basename>` via the full PicoModem flow
(STX/ACK handshake → FILE_WRITE → CHUNK frames → DONE_ACK). 512-byte
chunks. Multi-file push works (one PicoModem session per file). Raises
`Board43::AckTimeout` if the device doesn't ACK within 5s.

### Tests that pass

`bundle exec ruby test/board43_test.rb` (from `tools/`) — 4 tests:

1. `test_push_uploads_a_file_to_the_devices_home_directory`
2. `test_push_splits_files_larger_than_the_chunk_size_into_multiple_chunks`
3. `test_push_uploads_each_file_in_its_own_picomodem_session`
4. `test_push_raises_ack_timeout_when_the_device_does_not_respond_to_stx`

All assertions go through `@device.io_events` — a list of high-level
protocol events the FakeDevice records as it parses incoming frames.

---

## Architecture and design decisions (with rationale)

### `Board43` is the domain class; CLI is plumbing

One method per CLI verb. Constructor takes `serial:`, `stdin:`, `stdout:`,
`logger_io:`, `clock:`. The future CLI (not yet written) will be ~40
lines that parse argv, open a real `Serial`, and dispatch to one of
`push` / `install` / `run` / `shell`. No domain logic in the CLI — Okarin
was explicit on this.

### Serial interface — four methods, inheritance for the fake

`Serial` exposes `write(bytes)`, `read_nonblock(max)`, `read(n)`, `close`.

- `read_nonblock(max)` — returns 0..max bytes immediately, `''` if none.
- `read(n)` — blocks until exactly n bytes; built on top of `read_nonblock`
  with a `Kernel.sleep(0.001)` poll loop.
- `Serial::Closed` exception (subclass of `IOError`) raised on operations
  after `close`.

`FakeSerial < Serial` overrides only `initialize`, `write`, `read_nonblock`,
`close` — inherits `read` and `Closed`. This is intentional: we want the
test fake to share the *blocking* read implementation so any difference
between fake and real is concentrated in `read_nonblock`.

The 1ms poll-sleep inside `Serial#read` is **not** mocked. Okarin's call:
short enough not to matter in tests, mocking it would just confuse things.
Time mocking happens one layer up, in `Board43`.

### `PicoModemFrame` — value object with class-method factories

```ruby
PicoModemFrame.file_write(path:, size:)
PicoModemFrame.chunk(data)
PicoModemFrame.file_ack(status: READY)         # default args match common case
PicoModemFrame.chunk_ack(status: OK)
PicoModemFrame.done_ack(crc32:, status: OK)
PicoModemFrame.file_data(data, total: nil)     # first-frame total prefix
PicoModemFrame.error(message)
PicoModemFrame.abort
PicoModemFrame.file_read(path:)
```

Wire-format encoding via `to_s` (binary string). Idiomatic Ruby — frames
*are* byte sequences, so `to_s` is the natural serialization name. We
explicitly considered and rejected `to_b` / `to_bytes` / `pack`.

Class methods grouped under `class << self`. `crc16` is a public class
method — was briefly tempted to make it private, but `to_s` (instance
method) needs to call it, and `self.class.send(:crc16, ...)` was uglier
than the leak.

Constants `STX`, `ACK`, `FILE_WRITE`, `CHUNK`, `OK`, `READY`, `FAIL`, etc.
all live on `PicoModemFrame` — the canonical home. Both `Board43` and
`FakeDevice` reference them as `PicoModemFrame::ACK`, etc.

### `read_from_serial!(serial)` — parser takes a serial, not a buffer

Earlier draft was `read_from_buffer!(buffer)` — pure parser, mutates a
String buffer. Switched to `read_from_serial!(serial)` after Okarin
asked: it's cleaner because the parser doesn't expose internals like
"how many bytes have I tried to read so far," and it mirrors how upstream
picomodem.rb consumes from its IO incrementally.

`serial` parameter must provide `read(n)` that blocks until exactly n
bytes are returned. Each side handles its own waiting strategy — sleep
on real serial, `Fiber.yield` on the test-side device. Bytes are
consumed as they're read; on protocol failure (non-STX, CRC mismatch)
the bytes consumed so far are gone, matching upstream picomodem.rb's
read-and-gone behavior.

Raises:
- `PicoModemFrame::ProtocolError` — first byte wasn't STX
- `PicoModemFrame::CrcMismatchError < ProtocolError` — CRC-16 didn't match

### `FakeDevice` — Fiber-driven, faithful PicoModem implementation

The most complex test fake. Implements:
- Shell-mode line input (CR/LF "executes" the line as a `[:shell, :command, ...]` event)
- STX intercept: emits `\n^B\n\x06` (matching `shell.rb`'s actual byte sequence — see "Protocol details" below) and runs one PicoModem session
- FILE_WRITE handler with chunking + DONE_ACK + CRC32
- FILE_READ handler that streams from `@filesystem`
- ABORT handling
- Session epilogue: `\n[PicoModem] write /path\n$> ` after each operation

**Why a Fiber:** the device drives the protocol in straight-line style
(read STX → recv frame → loop on chunks → ...) but its only input is
`feed(bytes)`. The Fiber lets us write linear `read(n)` code; whenever
it asks for more bytes than have arrived, it yields and resumes on the
next feed. Tests therefore can't deadlock waiting for "the device to do
its part" — every byte the client writes synchronously advances the
device as far as it can go, then yields.

**Public interface:** `feed(bytes)`, `consume_outgoing(max)`, `read(n)`,
plus introspection accessors `io_events` and `filesystem`. The `read(n)`
is what `PicoModemFrame.read_from_serial!(self)` calls.

**`io_events` event vocabulary** (current, may grow):
- `[:picomodem, 'FILE_WRITE', path, size]`
- `[:picomodem, 'CHUNK', data]`
- `[:picomodem, 'DONE']` — multi-frame op completed
- `[:picomodem, 'FILE_READ', path]`
- `[:shell, :command, line]` — line typed at the shell prompt (CR/LF terminated)

### `FakeSerial` — accumulating outbox, byte-in/byte-out device

Decoupled from the device's response timing — accumulating outbox lets
the device emit bytes the client hasn't read yet (this matters for the
session epilogue between operations on a multi-file push, which sits in
the outbox until the next operation's `read_until_ack` scans past it).

Earlier sketch had `feed(bytes)` *return* the response bytes, but Okarin
correctly flagged that this forecloses on async/spontaneous emit
scenarios (boot banner, app stdout while attached in `shell` mode).

### Clock injection — only in `Board43`, only for deadline checks

Okarin: don't inject the clock into `Serial`. The 1ms poll-sleep there
is short enough not to bother tests. Mocking it would be confusing.

In `Board43`:
- `read_until_ack` uses `@clock.now > deadline` to bail with `AckTimeout`
- `@clock.sleep(POLL_INTERVAL_S)` between polls — `FakeClock.sleep`
  advances `@now` so the timeout test runs in zero wall-clock time

### Step-down ordering everywhere

Methods in `Board43` and `FakeDevice` are ordered top-down: each method
appears above the methods it calls. Section dividers (`# ── X ──`)
separate semantic groupings (top-level loop, per-operation handlers,
frame I/O). Serials are *exempt* (pure interface — no internal calls
worth ordering).

### Empty lines after `raise` / early `return`

Okarin's style preference. Applied throughout. Helps the eye see the
guard clauses.

---

## Protocol details (cross-checked against upstream)

`firmware/picoruby/mrbgems/picoruby-picomodem/mrblib/picomodem.rb` is the
device-side source. Cloned at the pinned commit (`9b94521d`) into
`lib-checkouts/picoruby/` for reference.

**STX/ACK handshake.** When the shell sees `0x02` while reading at the
prompt (see `shell.rb:417-422`), it does:
```ruby
puts "\n^B"                  # → bytes 0x0a 0x5e 0x42 0x0a (puts adds the closing \n)
$stdout.write("\x06")        # → ACK
PicoModem.session(...)
```
So after STX, **5 bytes** come back: `\n^B\n\x06`. The first byte after
STX is `\n`, not ACK. `read_until_ack` scans byte-by-byte until ACK —
also tolerates leftover epilogue text from prior operations. Matches
both reference clients (TS playground, original `tools/board43.rb`).

**Session lifetime.** One operation per session. `PicoModem.session`
reads exactly one frame, dispatches to its handler (which may loop
internally for FILE_WRITE chunks etc.), then `break`s out and returns to
the shell. So `push file1 file2` does **two** complete handshake +
FILE_WRITE cycles.

**Session epilogue.** After the operation returns, the shell sleeps 200ms
and prints `[PicoModem] info\n` (e.g. `[PicoModem] write /home/foo\n`)
then re-displays the `$> ` prompt. These bytes sit in the buffer until
the next operation reads them (or until they're scanned past during
`read_until_ack` for the next session).

**Chunk sizes.**
- Device-side `CHUNK_SIZE = 480` (`picomodem.rb:38`) — used **only**
  for outgoing FILE_READ chunks. Device accepts any size on incoming
  FILE_WRITE chunks.
- Reference wasm-demo client (`picoruby-wasm/demo/www/terminal.html`)
  uses `PICOMODEM_CHUNK_SIZE = 512`. TS playground inherits 512.
- Original `tools/board43.rb` uses 480 (matching device-side). Misleading
  comment "device-side limit" — there's no actual limit on incoming.
- **The new `Board43::CHUNK_SIZE = 512`** matches the reference client
  and is a clean power of two. Device is happy with any value within the
  2-byte length-field cap (65535 bytes per body).

**Frame format.** `STX(1) + length(2 BE) + cmd(1) + payload(N) + CRC16(2 BE)`.
Length covers `cmd + payload`. CRC-16/CCITT-FALSE (init `0xFFFF`,
poly `0x1021`) over `cmd + payload`. CRC-32 (zip/png polynomial) on
DONE_ACK + over each transferred file.

**Read-and-gone semantics.** `picomodem.rb`'s `recv_frame` (lines 91-116)
reads bytes via `read_exact` and discards them on failure (non-STX,
timeout, CRC mismatch). The CLI mirrors this: bytes that come off the
wire are gone. There's no peek/rewind; framing is self-synchronizing via
STX.

---

## What's left

These haven't been started. Ordered by dependency.

### 1. Remaining `Board43` verbs

The original `tools/board43.rb` has these subcommands:

- **`run <local>`** — upload to `/home/run.rb`, exec it (the existing
  CLI types the path + `\r` into the shell prompt rather than using
  `RUN_FILE`), then attach a raw shell. `--detach` skips the attach.
- **`install <local>`** — upload to `/home/app.rb` (R2P2 autoruns this
  on boot). `--run` triggers it immediately.
- **`shell`** — pure raw-terminal attach to the live device; Ctrl-]
  detaches.

The current `tools/board43.rb`'s `run`, `install`, and `shell` workflows
are documented in its own header comment — that's the spec for what the
new code should do. Read it before starting.

The shell-attach part (raw terminal, Ctrl-] detection, LF→CRLF translation
for the user terminal) is non-trivial. Probably wants to live in a
small `ShellPilot` class or similar. It's the one place `stdin` /
`stdout` get used as actual terminal IO, not just for tests.

For tests, `FakeDevice` already records `[:shell, :command, line]` events,
so `run` and `install --run` can be asserted on those. `shell` itself is
trickier — would need a test that pumps fake stdin bytes and checks they
reach the device + that device output flows to fake stdout.

### 2. CLI entry point

A new file (probably `lib/cli.rb`) that:
- Parses argv with OptionParser (matching the existing flag set:
  `-p PATH`, `--run`, `--detach`, `-h`)
- Auto-detects `/dev/cu.usbmodem*` if no `-p`
- Constructs a real `Serial`, `Board43.new(serial:, ...)`, dispatches.

The new `tools/board43.rb` script (replacing the old one) should be
~10 lines: require the lib, call `Cli.run(ARGV, ...)`, exit 0.

### 3. Cutover

Once everything works:
- Replace the old `tools/board43.rb` with the new entry point.
- The existing `tools/board43` bash wrapper already invokes
  `bundle exec ruby tools/board43.rb` — no change needed there.
- Delete the original 421-line `board43.rb` once feature parity is
  confirmed. (Don't lose its prompt-detection + warning copy in the
  shell-attach code path though — the doc string in the existing
  `wait_for_prompt` has useful advice about why we don't auto-Ctrl-C.)

### 4. Probably worth adding eventually

Not blocking the rewrite, but in the design's reach:

- **`pull <remote> [local]`** — uses `PicoModemFrame.file_read`. The
  guide actually documents this as already supported in the CLI;
  somebody promised it ahead of implementation. `FakeDevice` already
  implements the device side.
- **`rm <remote>`** — uses `DELETE_FILE`. Not yet in `PicoModemFrame`;
  would just be one factory method + handling.
- **Frame-level read timeout.** `PicoModemFrame.read_from_serial!`
  blocks indefinitely if the device goes silent mid-frame. The ACK
  timeout we have only covers the handshake. For real hardware
  robustness, frame reads should also have a deadline. The Clock
  abstraction is already there; it's a small change.
- **`CrcMismatchError` recovery.** Currently propagates as an unhandled
  exception out of `read_frame`. Real picomodem.rb just bails the
  session on CRC mismatch — fine, but the CLI should turn it into a
  user-visible error message rather than a stack trace.

### 5. Lower-level unit tests, when they earn their place

Per the `software-design` skill: only when a sub-module needs to be
*resilient* (handles many edge cases specific to its subdomain) or
*reusable* across contexts. **`PicoModemFrame`** is the obvious
candidate — frame parsing is the place corruption / partial reads / CRC
edge cases live, and it's exercised heavily on real hardware. When a
parsing edge case is awkward to provoke from a CLI-level test, drop down
to `PicoModemFrameTest`.

---

## How to run / extend

```bash
cd tools
bundle install                              # one-time
bundle exec ruby test/board43_test.rb       # run the test
```

To add a new test: add a method to `Board43Test`. `build_board` gives
you a `Board43` wired to a `FakeDevice` + `FakeSerial` + `FakeClock`.
Use `@device.io_events` for protocol-level assertions and
`@device.filesystem` for "what files ended up on the device" assertions.
`build_silent_board` is the variant for timeout testing — substitutes a
`SilentDevice` that ignores all input and never responds.

For a "device emits something the test should see" scenario that
**doesn't** map to client→server flow (e.g. a boot banner, an app's
stdout while attached in shell mode), nothing prevents adding a method
on `FakeDevice` like `simulate_emit(bytes)` that just appends to
`@outbuf`. The accumulating-outbox design already supports this.

---

## Okarin's preferences observed during this session

- TDD strictly: one failing test, smallest fix, run, repeat. *Don't*
  invent infrastructure ahead of demand — they'll redirect quickly if
  you do.
- Address them as "Okarin" (per global CLAUDE.md).
- `require_relative` over `$LOAD_PATH.unshift` for non-gem code.
- Empty line after `raise` / early `return`.
- Step-down method ordering, with section dividers (`# ── … ──`).
- Idiomatic Ruby names (`to_s` over `to_b`).
- Constructors at the very top; production interface above test helpers.
- Don't mention test-only behavior in production docs.
- `class << self` for class methods, with `private` inside if needed.
- Don't over-mock: only what tests genuinely need (Clock yes, internal
  Serial sleep no).
- Personal apps go in `my-apps/`, not `workshop/examples/` (from memory —
  not relevant to this rewrite, but came up before).

---

## External references

- Upstream PicoModem source (cloned for reference, not built):
  `lib-checkouts/picoruby/mrbgems/picoruby-picomodem/mrblib/picomodem.rb`
- Upstream shell STX intercept:
  `lib-checkouts/picoruby/mrbgems/picoruby-shell/mrblib/shell.rb:417-422`
- Reference wasm client (where 512 came from):
  `lib-checkouts/picoruby/mrbgems/picoruby-wasm/demo/www/terminal.html:190`
- Original Ruby CLI being rewritten (still the shipping one):
  `tools/board43.rb`
- TS reference implementation: `playground/src/utils/picomodem.ts`
- Protocol overview: `BOARD43_GUIDE.md` Part 7
