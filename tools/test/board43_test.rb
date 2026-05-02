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

  private

  def build_board
    @serial = FakeSerial.new
    @device = Device.new(@serial)
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
