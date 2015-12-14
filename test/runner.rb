#!/usr/bin/env ruby
require 'fileutils'
require 'ostruct'
require 'pathname'
require 'stringio'
require 'tmpdir'

TESTS = %w[
  git_vcs
  reversions
  new_files
]

$:.unshift Pathname(__FILE__).expand_path.dirname.dirname + 'lib'
$:.unshift Pathname(__FILE__).expand_path.dirname.dirname
require 'xmigra'
require 'test/utils'

$test_count = 0
$test_successes = 0
$tests_failed = []

$xmigra_test_system = 'Microsoft SQL Server'

class AssertionFailure < Exception; end

class UnexpectedExceptionFailure < AssertionFailure
  def initialize(msg, original=nil)
    super(msg)
    @original = original
    set_backtrace(original.backtrace) if original
  end
  
  attr_reader :original
end

def run_test(name, &block)
  return unless $test_selectors.empty? || $test_selectors.any? {|selector| selector === name}
  
  $test_count += 1
  
  msg_receiver, msg_sender = IO.pipe
  
  if child_pid = Process.fork
    msg_sender.close
    
    # Must read to EOF or child may hang if pipe is filled
    test_message = msg_receiver.read
    Process.wait(child_pid)
    
    if $?.success?
      print '.'
      $test_successes += 1
    else
      print 'F'
      $tests_failed << name
    end
    
    if test_message.length > 0
      ($test_messages ||= {})[name] = test_message
    end
    msg_receiver.close
  else
    msg_receiver.close
    
    begin
      prev_stdout = $stdout
      $stdout = StringIO.new
      begin
        block.call
      ensure
        $stdout = prev_stdout
      end
      exit! 0
    rescue AssertionFailure
      msg_sender.puts $!
      exit! 2
    rescue
      msg_sender.puts "#{$!.class}: #{$!}"
      msg_sender.puts $!.backtrace
      $!.each_causing_exception do |ex|
        msg_sender.puts
        msg_sender.puts "Caused by #{ex.class}: #{ex}"
        msg_sender.puts ex.backtrace
      end
      exit! 1
    end
  end
end

def test_output
  return nil unless $stdout.kind_of? StringIO
  return $stdout.string
end

def assert(message=nil, &block)
  get_message = proc {
    if !message and File.exist?(block.source_location[0])
      File.read(block.source_location[0]).lines[block.source_location[1] - 1].strip
    elsif message.is_a? Proc
      message.call
    else
      message
    end
  }
  
  block.call || raise(AssertionFailure, get_message.call)
end

def assert_eq(actual, expected)
  assert(proc {"#{actual.inspect} was not equal to #{expected.inspect}"}) {actual == expected}
end

def assert_neq(actual, expected)
  assert(proc {"Value #{actual.inspect} was unexpected"}) {actual != expected}
end

def include_test(container, item)
  case
  when item.kind_of?(Regexp) && container.kind_of?(String)
    item.match container
  else
    container.include? item
  end
end

def assert_include(container, item)
  assert(proc {"#{item.inspect} was not in #{container.inspect}"}) do
    include_test container, item
  end
end

def assert_not_include(container, item)
  assert(proc {"#{item.inspect} was in #{container.inspect}"}) do
    !include_test container, item
  end
end

def assert_raises(expected_exception)
  begin
    yield
  rescue Exception => ex
    assert("#{ex.class} is not #{expected_exception}") {ex.is_a? expected_exception}
    return
  end
  
  assert("No #{expected_exception} raised") {false}
end

def assert_noraises
  yield
end

class TestNamePrinter
  def ===(v)
    puts "    #{v}"
    return false
  end
end

$test_options = OpenStruct.new
$test_options.show_counts = true
$test_selectors = (if __FILE__ == $0
  [].tap do |selectors|
    
    args = ARGV.dup
    until args.empty? do
      case
      when args[0] == '--list'
        $test_options.list_tests = true
        $test_options.show_counts = false
        args.shift
      when args[0].start_with?('re:')
        selectors << Regexp.new(args.shift[3..-1])
      else
        selectors << args.shift
      end
    end
    
    if $test_options.list_tests
      selectors.replace [TestNamePrinter.new]
    end
  end
else
  [Object]
end)

TESTS.each {|t| require "test/#{t}"}

puts
puts "#{$test_successes}/#{$test_count} succeeded" if $test_options.show_counts
puts "Failed tests:" unless $tests_failed.empty?
$tests_failed.each {|name| puts "    #{name}"}

($test_messages || {}).each_pair do |test_name, message|
  puts
  puts "----- #{test_name} -----"
  message.each_line do |msg_line|
    puts msg_line.chomp
  end
end
