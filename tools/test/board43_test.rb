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

  private

  def build_board
    @device = FakeDevice.new
    @serial = FakeSerial.new(@device)
    @stdin = StringIO.new
    @stdout = StringIO.new
    @logger_io = StringIO.new
    Board43.new(
      serial: @serial,
      stdin: @stdin,
      stdout: @stdout,
      logger_io: @logger_io,
    )
  end
end
