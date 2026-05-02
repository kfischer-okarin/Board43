require 'bundler/setup'
require 'minitest/autorun'
require 'stringio'

require_relative '../lib/board43'
require_relative '../lib/clock'
require_relative '../lib/pico_modem_frame'
require_relative '../lib/serial'

require_relative 'support/fake_clock'
require_relative 'support/fake_device'
require_relative 'support/fake_serial'
