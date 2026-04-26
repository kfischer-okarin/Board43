#!/usr/bin/env ruby
# board43.rb — run/install Ruby files on a Board43 (PicoRuby/R2P2) device.
#
# Speaks PicoRuby's PicoModem binary protocol (see upstream
# mrbgems/picoruby-picomodem/mrblib/picomodem.rb).
#
# Setup:
#   cd tools && bundle install
#
# Usage (from tools/):
#   bundle exec ruby board43.rb run     <local>          # upload to /home/run.rb
#                                                          and execute, like the
#                                                          playground's "Run on Device"
#   bundle exec ruby board43.rb install <local> [--run]  # upload to /home/app.rb,
#                                                          which R2P2 auto-loads on boot
#
# Both commands always overwrite the same flash path (no orphaned files
# accumulate). `run` uses a fixed scratch path so successive iterations
# don't fill flash with stale copies.

require 'bundler/setup'
require 'serialport'
require 'optparse'
require 'io/console'

# ── Protocol constants ────────────────────────────────────────────────

STX = 0x02
ACK = 0x06

FILE_WRITE = 0x02
CHUNK      = 0x04

FILE_ACK  = 0x82
CHUNK_ACK = 0x84
DONE_ACK  = 0x8F
ERROR_CMD = 0xFE

OK_STATUS = 0x00
READY     = 0x01

CHUNK_SIZE = 480     # device-side limit (picomodem.rb)
TIMEOUT_MS = 5000

STARTUP_PATH = '/home/app.rb'
SCRATCH_PATH = '/home/run.rb'

SHELL_EXIT_KEY = 0x1d   # Ctrl-]

# ── Top-level entry ───────────────────────────────────────────────────

def main
  options, command = parse_args
  port = open_port(options[:port])
  begin
    dispatch(command, port, options)
  ensure
    port.close
    warn '· disconnected'
  end
end

def dispatch(command, port, options)
  case command
  when 'run'     then run_command(port, options)
  when 'install' then install_command(port, options)
  when 'shell'   then shell_command(port, options)
  else                abort "unknown command: #{command}"
  end
end

# ── Subcommands ───────────────────────────────────────────────────────

def run_command(port, _options)
  local = ARGV.shift or abort 'run: <local> required'
  upload(port, local, SCRATCH_PATH)
  exec_remote(port, SCRATCH_PATH)
  # Auto-attach the shell so the user sees the app's output (puts,
  # LiveRepl `=> ...`, errors). Ctrl-] to detach.
  warn '· attaching shell — Ctrl-] to detach (Ctrl-C interrupts the app)'
  $stdin.raw { run_shell_loop(port) }
  warn "\n· shell exited"
end

def install_command(port, options)
  local = ARGV.shift or abort 'install: <local> required'
  upload(port, local, STARTUP_PATH)
  warn "✓ installed as startup (#{STARTUP_PATH})"
  exec_remote(port, STARTUP_PATH) if options[:run]
end

def shell_command(port, _options)
  warn '· shell — Ctrl-] to exit (Ctrl-C is passed through to the device)'
  $stdin.raw { run_shell_loop(port) }
  warn "\n· shell exited"
end

# ── Workflows ─────────────────────────────────────────────────────────

def upload(port, local, remote)
  enter_session(port)
  push_file(port, local, remote)
  warn "✓ pushed #{local} → #{remote} (CRC32 verified)"
end

def exec_remote(port, remote)
  warn "· running #{remote}"
  sleep 0.4   # let the device redraw the prompt after PicoModem session
  port.write_raw("#{remote}\r")
end

def run_shell_loop(port)
  loop do
    forward_device_to_terminal(port)
    return if forward_terminal_to_device(port) == :exit
    sleep 0.005
  end
end

def forward_device_to_terminal(port)
  chunk = port.read_some(4096)
  return if chunk.empty?
  # Raw mode disables ONLCR, so bare LF from the device moves down
  # without returning to column 0. R2P2 emits LF-only via `puts`, so
  # translate here. (Doubling on existing \r\n is harmless on terminals.)
  $stdout.write(chunk.gsub("\n", "\r\n"))
  $stdout.flush
end

def forward_terminal_to_device(port)
  bytes = $stdin.read_nonblock(64, exception: false)
  return nil if bytes == :wait_readable || bytes.nil?
  return :exit if bytes.bytes.include?(SHELL_EXIT_KEY)
  port.write_raw(bytes)
  nil
end

# ── Session orchestration ────────────────────────────────────────────

def enter_session(port)
  warn '· checking for shell prompt'
  wait_for_prompt(port) or abort <<~MSG
    no '$> ' prompt within 3 s — the device is probably running an app.
    Open `tools/board43 shell`, hit Ctrl-C to interrupt it, exit with Ctrl-],
    then re-run this command. (Auto-sending Ctrl-C from here can crash the
    firmware mid-frame and reboot the board, so we don't.)
  MSG
  warn '· starting PicoModem session'
  start_picomodem(port)
end

def wait_for_prompt(port, timeout_ms: 3000)
  # Just nudge with Enter — never auto-Ctrl-C. Sending Ctrl-C while the
  # firmware is mid-task can corrupt VM state and trigger a watchdog
  # reset. The playground avoids it for the same reason.
  port.write_raw("\r")
  poll_for_prompt(port, timeout_ms)
end

def poll_for_prompt(port, timeout_ms)
  deadline = now_ms + timeout_ms
  buf = ''.b
  while now_ms < deadline
    buf << port.read_some(256)
    return true if buf.include?('$> ')
    sleep 0.05
  end
  warn "no '$> ' prompt; saw: #{buf.inspect[0, 200]}"
  false
end

def start_picomodem(port)
  port.write_raw([STX].pack('C'))
  deadline = now_ms + TIMEOUT_MS
  while now_ms < deadline
    byte = port.read_exact(1, 250)
    next unless byte
    return if byte.getbyte(0) == ACK
  end
  raise 'timeout waiting for ACK after Ctrl-B'
end

# ── File transfer ─────────────────────────────────────────────────────

def push_file(port, local_path, remote_path)
  data = File.binread(local_path)
  send_write_request(port, remote_path, data.bytesize)
  send_chunks(port, data)
  verify_push_done(port, expected_crc: crc32(data))
end

def send_write_request(port, remote_path, size)
  header = [size].pack('N') + remote_path.b
  send_frame(port, FILE_WRITE, header)
  ack = expect_frame(port, FILE_ACK, 'FILE_ACK')
  raise 'FILE_ACK without READY status' unless ack.getbyte(0) == READY
end

def send_chunks(port, data)
  offset = 0
  while offset < data.bytesize
    chunk = data.byteslice(offset, [CHUNK_SIZE, data.bytesize - offset].min)
    send_frame(port, CHUNK, chunk)
    expect_frame(port, CHUNK_ACK, 'CHUNK_ACK')
    offset += chunk.bytesize
    print "\r  #{offset}/#{data.bytesize} bytes"
  end
  puts
end

def verify_push_done(port, expected_crc:)
  done = expect_frame(port, DONE_ACK, 'DONE_ACK')
  status = done.getbyte(0)
  raise "transfer status=0x#{status.to_s(16)}" unless status == OK_STATUS
  reported_crc = done.byteslice(1, 4).unpack1('N')
  return if reported_crc == expected_crc
  raise "CRC32 mismatch: expected 0x#{expected_crc.to_s(16)}, got 0x#{reported_crc.to_s(16)}"
end

# ── Frame I/O ─────────────────────────────────────────────────────────

def send_frame(port, cmd, payload = ''.b)
  port.write_raw(build_frame(cmd, payload))
end

def expect_frame(port, expected_cmd, ctx)
  frame = recv_frame(port) or raise "#{ctx}: timeout"
  cmd, payload = frame
  raise "#{ctx}: device error: #{payload}" if cmd == ERROR_CMD
  raise "#{ctx}: expected 0x#{expected_cmd.to_s(16)}, got 0x#{cmd.to_s(16)}" unless cmd == expected_cmd
  payload
end

def build_frame(cmd, payload)
  body = cmd.chr.b + payload.b
  [STX, body.bytesize].pack('Cn') + body + [crc16(body)].pack('n')
end

def recv_frame(port, timeout_ms = TIMEOUT_MS)
  deadline = now_ms + timeout_ms
  return nil unless scan_for_stx(port, deadline)
  body_len = read_body_length(port, deadline)
  return nil if body_len.nil? || body_len.zero?
  read_and_verify_body(port, body_len, deadline)
end

def scan_for_stx(port, deadline)
  loop do
    return false if now_ms >= deadline
    byte = port.read_exact(1, deadline - now_ms)
    return false unless byte
    return true if byte.getbyte(0) == STX
  end
end

def read_body_length(port, deadline)
  remaining = deadline - now_ms
  return nil if remaining <= 0
  bytes = port.read_exact(2, remaining)
  bytes&.unpack1('n')
end

def read_and_verify_body(port, body_len, deadline)
  remaining = deadline - now_ms
  return nil if remaining <= 0
  rest = port.read_exact(body_len + 2, remaining)
  return nil unless rest
  body = rest.byteslice(0, body_len)
  recv_crc = rest.byteslice(body_len, 2).unpack1('n')
  return nil if crc16(body) != recv_crc
  [body.getbyte(0), body.byteslice(1, body_len - 1) || ''.b]
end

# ── CLI argument parsing ──────────────────────────────────────────────

def parse_args
  options = { port: nil, run: false }
  parser = build_option_parser(options)
  parser.parse!
  command = ARGV.shift or abort parser.to_s
  [options, command]
end

def build_option_parser(options)
  OptionParser.new do |o|
    o.banner = usage_banner
    o.on('-p', '--port PATH', 'serial port (default: auto-detect /dev/cu.usbmodem*)') { |v| options[:port] = v }
    o.on('--run', 'after install, run /home/app.rb immediately') { options[:run] = true }
    o.on('-h', '--help') { puts o; exit }
  end
end

def usage_banner
  <<~USAGE
    Usage: bundle exec ruby board43.rb [opts] <command> <args>

    Commands:
      run     <local>           Upload <local> to /home/run.rb and execute
      install <local>           Upload <local> to /home/app.rb (auto-runs on boot)
      shell                     Attach a raw terminal to the device (Ctrl-] to exit)

    Options:
  USAGE
end

# ── Port lifecycle ───────────────────────────────────────────────────

def open_port(path)
  path ||= autodetect_port
  warn "→ #{path}"
  Port.new(path)
end

def autodetect_port
  # The board exposes two CDC interfaces (usb_descriptors.c): "PicoRuby
  # CDC" (the shell, interface 0) and "PicoRuby CDC Debug" (interface
  # 1). macOS names them /dev/cu.usbmodemXXX1 and …XXX3 respectively,
  # so the sorted-first one is always the shell.
  candidates = Dir.glob('/dev/cu.usbmodem*').sort
  abort 'no USB CDC device found at /dev/cu.usbmodem*' if candidates.empty?
  if candidates.size > 1
    warn "multiple devices: #{candidates.inspect}"
    warn "  using #{candidates.first} (the higher-numbered ones are the debug CDC)"
  end
  candidates.first
end

# ── Helpers ───────────────────────────────────────────────────────────

def now_ms
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
end

def crc16(data)
  crc = 0xFFFF
  data.each_byte do |b|
    crc ^= (b << 8)
    8.times do
      crc = (crc & 0x8000).zero? ? (crc << 1) : ((crc << 1) ^ 0x1021)
      crc &= 0xFFFF
    end
  end
  crc
end

def crc32(data)
  crc = 0xFFFFFFFF
  data.each_byte do |b|
    crc ^= b
    8.times do
      crc = (crc & 1).zero? ? (crc >> 1) : ((crc >> 1) ^ 0xEDB88320)
    end
  end
  crc ^ 0xFFFFFFFF
end

# ── Serial port wrapper ───────────────────────────────────────────────

class Port
  def initialize(path)
    @sp = SerialPort.new(path, 115200, 8, 1, SerialPort::NONE)
    @sp.read_timeout = 0
    @sp.flow_control = SerialPort::NONE
    @buf = String.new(encoding: Encoding::ASCII_8BIT)
  end

  def write_raw(bytes)
    @sp.write(bytes)
  end

  def read_some(max = 4096)
    @sp.read_nonblock(max).b
  rescue IO::WaitReadable, EOFError
    ''.b
  end

  def read_exact(n, timeout_ms = TIMEOUT_MS)
    deadline = now_ms + timeout_ms
    while @buf.bytesize < n
      return nil if now_ms >= deadline
      chunk = read_some(n - @buf.bytesize)
      if chunk.empty?
        sleep 0.005
      else
        @buf << chunk
      end
    end
    out = @buf.byteslice(0, n)
    @buf = @buf.byteslice(n, @buf.bytesize - n) || ''.b
    out
  end

  def close
    @sp.close
  rescue StandardError
    # best effort
  end
end

main if $PROGRAM_NAME == __FILE__
