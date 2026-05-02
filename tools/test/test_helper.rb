require 'bundler/setup'
require 'minitest/autorun'
require 'stringio'

require_relative '../lib/board43'
require_relative '../lib/serial'

require_relative 'support/fake_serial'
require_relative 'support/device'
