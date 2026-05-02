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

  def test_push_raises_ack_timeout_when_the_device_does_not_respond_to_stx
    Tempfile.create(['blink', '.rb']) do |f|
      f.write("puts :hello\n")
      f.close

      board = build_silent_board

      assert_raises(Board43::AckTimeout) { board.push([f.path]) }
    end
  end

  private

  def build_board
    @clock = FakeClock.new
    @device = FakeDevice.new
    @serial = FakeSerial.new(@device)
    Board43.new(
      serial: @serial,
      stdin: StringIO.new,
      stdout: StringIO.new,
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
