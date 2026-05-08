require_relative 'test_helper'
require 'tempfile'

class Board43Test < Minitest::Test
  def test_push_uploads_a_file_to_the_devices_home_directory
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_board

      board.push([f.path])

      assert_equal [
        [:picomodem, 'FILE_WRITE', "/home/#{File.basename(f.path)}", "puts :hello\n".bytesize],
        [:picomodem, 'CHUNK', "puts :hello\n"],
        [:picomodem, 'DONE'],
      ], @device.io_events
    end
  end

  def test_push_splits_files_larger_than_the_chunk_size_into_multiple_chunks
    data = 'x' * 1000
    Tempfile.create(['big', '.rb']) do |f|
      f.write(data)
      f.close

      board = build_board

      board.push([f.path])

      assert_equal [
        [:picomodem, 'FILE_WRITE', "/home/#{File.basename(f.path)}", 1000],
        [:picomodem, 'CHUNK', 'x' * 512],
        [:picomodem, 'CHUNK', 'x' * 488],
        [:picomodem, 'DONE'],
      ], @device.io_events
    end
  end

  def test_push_uploads_each_file_in_its_own_picomodem_session
    Tempfile.create(['a', '.rb']) do |a|
      Tempfile.create(['b', '.rb']) do |b|
        a.write("a\n")
        a.close
        b.write("bb\n")
        b.close

        board = build_board

        board.push([a.path, b.path])

        assert_equal [
          [:picomodem, 'FILE_WRITE', "/home/#{File.basename(a.path)}", 2],
          [:picomodem, 'CHUNK', "a\n"],
          [:picomodem, 'DONE'],
          [:picomodem, 'FILE_WRITE', "/home/#{File.basename(b.path)}", 3],
          [:picomodem, 'CHUNK', "bb\n"],
          [:picomodem, 'DONE'],
        ], @device.io_events
      end
    end
  end

  def test_run_uploads_to_home_run_rb_then_types_the_path_at_the_prompt
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_board

      board.run(f.path)

      assert_equal [
        [:picomodem, 'FILE_WRITE', '/home/run.rb', "puts :hello\n".bytesize],
        [:picomodem, 'CHUNK', "puts :hello\n"],
        [:picomodem, 'DONE'],
        [:shell, :command, '/home/run.rb'],
      ], @device.io_events
    end
  end

  def test_run_waits_for_the_shell_prompt_before_typing_the_path
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_board

      board.run(f.path)

      # On a connected terminal, the last thing visible after `run` is
      # the prompt with the typed path echoed next to it, then a fresh
      # prompt waiting for input. If `run` typed before the post-session
      # prompt arrived, the path would land mid-output and this would
      # not hold.
      assert_equal ["$> /home/run.rb\n", '$> '], @device.shell_mode_stdout.lines.last(2)
    end
  end

  def test_push_raises_ack_timeout_when_the_device_does_not_respond_to_stx
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_silent_board

      assert_raises(Board43::AckTimeout) { board.push([f.path]) }
    end
  end

  def test_shell_displays_device_output_for_a_typed_command
    board = build_board
    @device.command_responses['greet'] = "hello world\n"

    shell = handle_stdin { board.shell }
    assert_equal '$> ', @stdout.string

    @stdin.string = "greet\r"
    shell.resume

    # Bare \n from the device gets translated to \r\n before stdout —
    # the user's terminal is in raw mode (no ONLCR), so without this it
    # would render staircased.
    assert_equal "$> greet\r\nhello world\r\n$> ", @stdout.string

    @stdin.string = "\x1d"
    shell.resume

    refute shell.alive?
  end

  def test_run_raises_prompt_timeout_when_the_device_never_emits_a_prompt
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_board
      @device.emit_prompt = false

      assert_raises(Board43::PromptTimeout) { board.run(f.path) }
    end
  end

  private

  # Wrap a block that reads from @stdin in a Fiber so that
  # FiberFakeStdin's yield-on-empty-buffer has a non-root fiber to
  # return to. The fiber is started before this returns — it runs until
  # it first yields on empty stdin. Mutate @stdin.string and call
  # .resume on the returned fiber to drive subsequent input.
  def handle_stdin(&block)
    fiber = Fiber.new(&block)
    fiber.resume
    fiber
  end

  def build_board
    @clock = FakeClock.new
    @device = FakeDevice.new
    @serial = FakeSerial.new(@device)
    @stdin = FiberFakeStdin.new
    @stdout = StringIO.new
    Board43.new(
      serial: @serial,
      stdin: @stdin,
      stdout: @stdout,
      logger_io: StringIO.new,
      clock: @clock,
    )
  end

  def build_silent_board
    @clock = FakeClock.new
    @serial = FakeSerial.new(SilentDevice.new)
    Board43.new(
      serial: @serial,
      stdin: StringIO.new,
      stdout: StringIO.new,
      logger_io: StringIO.new,
      clock: @clock,
    )
  end

  class SilentDevice
    def feed(_bytes); end
    def consume_outgoing(_max) = ''.b
  end
end
