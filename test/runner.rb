#!/usr/bin/env ruby
require 'fileutils'
require 'ostruct'
require 'pathname'
require 'stringio'
require 'tmpdir'

TESTS = %w[
  git_vcs
]

$:.unshift Pathname(__FILE__).expand_path.dirname.dirname + 'lib'
$:.unshift Pathname(__FILE__).expand_path.dirname.dirname
require 'xmigra'

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
  
  if child_pid = Process.fork
    Process.wait(child_pid)
    
    if $?.success?
      print '.'
      $test_successes += 1
    else
      print 'F'
      $tests_failed << name
    end
  else
    begin
      block.call
      exit! 0
    rescue AssertionFailure
      exit! 2
    rescue
      puts
      puts "Exception: #{$!}"
      puts $!.backtrace
      exit! 1
    end
  end
end

class Integer
  def temp_dirs(prefix='')
    tmpdirs = []
    begin
      (1..self).each do |i|
        tmpdirs << Pathname(Dir.mktmpdir([prefix, ".#{i}"]))
      end
      
      yield(*tmpdirs)
    ensure
      tmpdirs.each do |dp|
        begin
          FileUtils.remove_entry dp
        rescue
          # Skip failure
        end
      end
    end
  end
end

def do_or_die(command, message=nil, exc_type=Exception)
  output = `#{command}`
  $?.success? || raise(exc_type, message || ("Unable to " + command + "\n" + output))
end

def initialize_xmigra_schema(path='.', options={})
  (Pathname(path) + XMigra::SchemaManipulator::DBINFO_FILE).open('w') do |f|
    YAML.dump({
      'system' => $xmigra_test_system,
    }.merge(options[:db_info] || {}), f)
  end
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

def assert_include(container, item)
  assert(proc {"#{item.inspect} was not in #{container.inspect}"}) {container.include? item}
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