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
│       ├── fake_clock.rb         # Test double for Clock (advances `now` on sleep)
│       ├── fake_device.rb        # Test stand-in for a real Board43 + R2P2
│       ├── fake_serial.rb        # Test stand-in for Serial (inherits Serial)
│       └── fiber_fake_stdin.rb   # Fiber-yielding stdin for shell-attach tests
├── Gemfile / Gemfile.lock    # `serialport`, `minitest` (test group)
├── board43                   # bash wrapper — currently still points at the old board43.rb
└── board43.rb                # OLD CLI — still in place, untouched. To be replaced
                              # once the rewrite is feature-complete.
```

The old `tools/board43.rb` (the script being rewritten) is *still the
shipping CLI*. Nothing under `lib/`, `test/`, or `bin/` is wired into the
`tools/board43` bash wrapper yet. That's the final cutover step.

### Currently working: `push`, `run`, `shell`

- **`push(local_paths)`** — uploads each file to `/home/<basename>` via
  the full PicoModem flow (STX/ACK handshake → FILE_WRITE → CHUNK
  frames → DONE_ACK). 512-byte chunks. Multi-file push works (one
  PicoModem session per file). Raises `Board43::AckTimeout` if the
  device doesn't ACK within 5s.
- **`run(local_path)`** — uploads to `/home/run.rb`, scans the device's
  output for the post-session `$> ` prompt (instead of sleeping a fixed
  time), types the path + `\r` to exec it, then attaches a shell.
  Auto-attach is unconditional — there is no `--detach`. Raises
  `Board43::PromptTimeout` if `$> ` doesn't appear within 5s.
- **`shell`** — bidirectional pump: bytes from `@stdin` go to the
  serial; bytes from the serial go to `@stdout` with `\n` → `\r\n`
  translation (raw mode disables ONLCR). Loops until Ctrl-] (`0x1d`)
  appears in stdin. Idles via `@clock.sleep(0.005)`. Raw passthrough —
  the device's `Editor::Line` handles backspace/arrows/Ctrl-A/E/history.

### Tests that pass

`bundle exec ruby test/board43_test.rb` (from `tools/`) — 9 tests:

1. `test_push_uploads_a_file_to_the_devices_home_directory`
2. `test_push_splits_files_larger_than_the_chunk_size_into_multiple_chunks`
3. `test_push_uploads_each_file_in_its_own_picomodem_session`
4. `test_push_raises_ack_timeout_when_the_device_does_not_respond_to_stx`
5. `test_run_uploads_to_home_run_rb_then_types_the_path_at_the_prompt`
6. `test_run_waits_for_the_shell_prompt_before_typing_the_path`
7. `test_run_attaches_a_shell_after_typing_the_path`
8. `test_run_raises_prompt_timeout_when_the_device_never_emits_a_prompt`
9. `test_shell_displays_device_output_for_a_typed_command`

Push tests assert against `@device.io_events` (high-level protocol
event log). Shell-mode tests assert against `@stdout.string` (what a
connected terminal would render) or `@device.shell_mode_stdout` (the
device's view of what it would have printed in shell mode, frames
excluded).

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
`close` — inherits `read` and `Closed`. Intentional: tests share the
*blocking* read implementation so any difference between fake and real
is concentrated in `read_nonblock`.

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

### Shell pump — fiber-friendly without leaking fibers into production

`Board43#shell` is a plain nonblocking loop that:
1. Drains the serial outbox to `@stdout` (with `\n`→`\r\n` translation).
2. Reads `@stdin` non-blockingly. If a chunk contains `0x1d`, forwards
   bytes up to it, drains once more, and returns. Otherwise forwards
   the chunk verbatim.
3. Idles via `@clock.sleep(SHELL_IDLE_S)` (0.005s) when both sides have
   nothing to do.

In production the `@stdin` is a real IO whose `read_nonblock(_, exception:
false)` returns `:wait_readable` when the user hasn't typed — the loop
just sleeps and retries. No fiber, nothing exotic. In tests the stdin is
`FiberFakeStdin` whose `read_nonblock` calls `Fiber.yield` while its
buffer is empty, so the test driving the pump from a Fiber gets control
back as soon as the pump is idle on input. The `sleep` line is unreachable
in tests because `FiberFakeStdin` yields first.

This was the result of explicit design pressure from Okarin: production
must not pay for test ergonomics.

### `FakeDevice` — Fiber-driven, faithful PicoModem + shell implementation

The most complex test fake. Implements a believable slice of R2P2:

- **Shell-mode line input.** Bytes typed at the prompt accumulate into a
  line buffer; CR/LF "executes" the line (`[:shell, :command, line]`
  io_event), emits `\n`, and the device returns to a fresh `$> `.
  Programmable per-command responses via `command_responses['greet'] =
  "hello world\n"` (used by the shell-display test).
- **Boot prompt.** The fiber emits `$> ` as the first thing it does, so
  on startup the host sees the prompt without any prodding.
- **Char echo.** Every typed char is echoed back to `@outbuf`, like the
  real device's `Editor::Line` does on each refresh.
- **STX intercept.** Echoes `\n^B\n\x06` (matching `shell.rb`'s actual
  byte sequence — see "Protocol details" below) and runs one PicoModem
  session.
- **Session epilogue.** After the session, emits `\n[PicoModem] info\n`
  and a fresh `$> `.
- **PicoModem session.** Implements FILE_WRITE, FILE_READ, and ABORT
  against an in-memory `@filesystem` hash.
- **Suppression.** `attr_writer :emit_prompt` — set to `false` to
  silence all prompt emissions (boot, post-command, post-session).
  Used by the prompt-timeout test.

**Why a Fiber:** the device drives the protocol in straight-line style
(read STX → recv frame → loop on chunks → ...) but its only input is
`feed(bytes)`. The Fiber lets us write linear `read(n)` code; whenever
it asks for more bytes than have arrived, it yields and resumes on the
next feed. Tests therefore can't deadlock waiting for "the device to do
its part" — every byte the client writes synchronously advances the
device as far as it can go, then yields.

**Public interface:** `feed(bytes)`, `consume_outgoing(max)`, `read(n)`,
plus introspection accessors `io_events`, `filesystem`, `shell_mode_stdout`,
and writers `emit_prompt`, `command_responses`. `read(n)` is what
`PicoModemFrame.read_from_serial!(self)` calls.

**`io_events` event vocabulary** (current, may grow):
- `[:picomodem, 'FILE_WRITE', path, size]`
- `[:picomodem, 'CHUNK', data]`
- `[:picomodem, 'DONE']` — multi-frame op completed
- `[:picomodem, 'FILE_READ', path]`
- `[:shell, :command, line]` — line typed at the shell prompt (CR/LF terminated)

**`shell_mode_stdout` accumulator.** Mirrors what a connected terminal
would have rendered in shell mode. Every shell-side `emit_bytes` tees
into it; PicoModem frames go straight to `@outbuf` via `send_frame` and
bypass it. So tests can assert *"the user saw `$> /home/run.rb` then a
fresh `$> `"* on the last two lines, instead of asserting brittle
byte-exact concatenations.

### `FakeSerial` — accumulating outbox, byte-in/byte-out device

Decoupled from the device's response timing — accumulating outbox lets
the device emit bytes the client hasn't read yet (this matters for the
session epilogue between operations on a multi-file push, which sits in
the outbox until the next operation's `read_until_ack` scans past it).

Earlier sketch had `feed(bytes)` *return* the response bytes, but Okarin
correctly flagged that this forecloses on async/spontaneous emit
scenarios (boot banner, app stdout while attached in `shell` mode).

### `FiberFakeStdin` — fiber-yielding test stdin

`read_nonblock(_, exception: false)` calls `Fiber.yield` while the
internal buffer is empty. The test sets `string=` and resumes the
wrapping fiber to feed the next bytes. Mirrors `FakeDevice`'s
"feed-and-resume" model so shell tests read as a back-and-forth:

```ruby
shell = handle_stdin { board.shell }   # starts the fiber, runs to first idle
assert_equal '$> ', @stdout.string

@stdin.string = "greet\r"
shell.resume
assert_equal "$> greet\r\nhello world\r\n$> ", @stdout.string

@stdin.string = "\x1d"
shell.resume
refute shell.alive?
```

The `handle_stdin` test helper is a one-liner that does
`Fiber.new(&block).tap(&:resume)`. The first resume is built in so the
test reads as a single setup line, not two.

### Clock injection — only in `Board43`, only for deadline checks and idle sleeps

Okarin: don't inject the clock into `Serial`. The 1ms poll-sleep there
is short enough not to bother tests. Mocking it would be confusing.

In `Board43`:
- `read_until_ack` / `read_until_prompt` use `@clock.now > deadline`
  to bail with `AckTimeout` / `PromptTimeout`.
- `@clock.sleep(POLL_INTERVAL_S)` between polls — `FakeClock.sleep`
  advances `@now` so timeout tests run in zero wall-clock time.
- `@clock.sleep(SHELL_IDLE_S)` for the shell pump's idle. Only reached
  in production; in tests `FiberFakeStdin` yields first.

### Step-down ordering everywhere

Methods in `Board43` and `FakeDevice` are ordered top-down: each method
appears above the methods it calls. Section dividers (`# ── X ──`)
separate semantic groupings (top-level loop, per-operation handlers,
frame I/O). Serials are *exempt* (pure interface — no internal calls
worth ordering).

### Empty lines after `raise` / early `return`

Okarin's style preference. Applied throughout. Helps the eye see the
guard clauses.

### Decisions explicitly NOT taken

- **No local line editing in `shell`.** The device's `Editor::Line`
  already handles backspace/Del (8, 127), left/right (`ESC[CD]`),
  up/down history (`ESC[AB]`), Ctrl-A/E (head/tail), Ctrl-L (refresh),
  Tab. Alt-prefixed sequences (Alt-F/B word jumps, Alt-Backspace) are
  NOT handled by the device — they currently produce a literal letter
  insert, since `Editor::Line` re-prepends unknown ESC tails. Living
  with that for now; revisit only if it becomes painful on hardware.
- **No `--detach` for `run`.** Auto-attach is unconditional.
- **No `Fiber.yield` in `Board43#shell` itself.** The yield lives in
  `FiberFakeStdin`; production stays fiber-free.

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
`read_until_ack` for the next session). `Board43#run` consumes them
explicitly with `read_until_prompt` before typing the path, so the
typed path lands while the shell is ready to read.

**No `RUN_FILE`.** The TS playground defines `RUN_FILE = 0x07` and a
`runFile()` method, but **nothing calls it** and the device firmware
has no handler for it (`picomodem.rb`'s case-statement falls through to
`Unknown command`). Both the playground "Run on device" button and our
`run` verb upload via `FILE_WRITE`, then drop back to the shell and type
the path + `\r`. That's the only thing that actually works against
current firmware.

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

Two items, in dependency order. Nothing else is in scope.

### 1. `install <local>`

Upload-only: `Board43#install(local_path)` uploads the file to
`/home/app.rb` (R2P2 autoruns this on boot via the patched
`shell_executables/r2p2.rb`). No flags. If the user wants to run it
right away, they can use `run`. If they want to validate boot behavior,
they reset the device.

Scope: one method, one or two tests at the application level (file
ends up on the device's filesystem at `/home/app.rb`).

### 2. CLI entry point + cutover

A new file (probably `lib/cli.rb`) that:
- Parses argv with OptionParser. Flag set is now smaller than before:
  `-p PATH`, `-h`. (No `--run`, no `--detach`.)
- Auto-detects `/dev/cu.usbmodem*` if no `-p`.
- Constructs a real `Serial`, `Board43.new(serial:, stdin: $stdin,
  stdout: $stdout, logger_io: $stderr)`, dispatches to one of `push`,
  `install`, `run`, `shell`.

The new `tools/board43.rb` script (replacing the old one) should be
~10 lines: require the lib, call `Cli.run(ARGV, ...)`, exit 0.

Cutover steps:
- Replace the old `tools/board43.rb` with the new entry point.
- The existing `tools/board43` bash wrapper already invokes
  `bundle exec ruby tools/board43.rb` — no change needed there.
- Delete the original 421-line `board43.rb` once feature parity is
  confirmed. (Don't lose its prompt-detection + warning copy in the
  shell-attach code path though — the doc string in the existing
  `wait_for_prompt` has useful advice about why we don't auto-Ctrl-C.)

### Lower-level unit tests, when they earn their place

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
you a `Board43` wired to a `FakeDevice` + `FakeSerial` + `FakeClock` +
`FiberFakeStdin`. Use `@device.io_events` for protocol-level assertions
and `@device.filesystem` for "what files ended up on the device"
assertions. `@device.shell_mode_stdout` is the device's view of what a
real terminal would have rendered in shell mode (frames excluded).
`build_silent_board` is the variant for `AckTimeout` testing —
substitutes a `SilentDevice` that ignores all input and never responds.
For `PromptTimeout` testing, use `build_board` then
`@device.emit_prompt = false`.

For shell-attach tests, wrap the shell-driving code with the
`handle_stdin { ... }` helper (creates a Fiber, runs to first idle).
Then mutate `@stdin.string` and call `.resume` on the returned fiber to
feed the next bytes.

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
- Production must not pay for test ergonomics — fiber-yield logic lives
  in `FiberFakeStdin`, not in `Board43#shell`.
- Prefer behavioral assertions (`shell_mode_stdout` last-two-lines)
  over byte-level structural ones (`consume_outgoing == ''`).
- Don't preemptively terminate fibers in tests "for cleanliness" if they
  GC fine — only when it makes the test clearer.
- Helpers like `handle_stdin` should fold setup ceremony in (here, the
  initial `.resume`) rather than expose it.
- Personal apps go in `my-apps/`, not `workshop/examples/` (from memory —
  not relevant to this rewrite, but came up before).

---

## External references

- Upstream PicoModem source (cloned for reference, not built):
  `lib-checkouts/picoruby/mrbgems/picoruby-picomodem/mrblib/picomodem.rb`
- Upstream shell STX intercept:
  `lib-checkouts/picoruby/mrbgems/picoruby-shell/mrblib/shell.rb:417-422`
- Upstream line editor (handles backspace, arrows, Ctrl-A/E, history):
  `lib-checkouts/picoruby/mrbgems/picoruby-editor/mrblib/editor.rb` —
  `Editor::Line` (line 103+)
- Reference wasm client (where 512 came from):
  `lib-checkouts/picoruby/mrbgems/picoruby-wasm/demo/www/terminal.html:190`
- Original Ruby CLI being rewritten (still the shipping one):
  `tools/board43.rb`
- TS reference implementation: `playground/src/utils/picomodem.ts`
  (note: its `runFile()` is dead code; no firmware support)
- Protocol overview: `BOARD43_GUIDE.md` Part 7
