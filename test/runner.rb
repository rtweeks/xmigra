#!/usr/bin/env ruby
require 'fileutils'
require 'pathname'
require 'stringio'
require 'tmpdir'

TESTS = %w[
]

$:.unshift Pathname(__FILE__).expand_path.dirname.dirname
require 'xmigra'

$test_count = 0
$test_successes = 0
$tests_failed = []

$xmigra_test_system = 'Microsoft SQL Server'

def run_test(name, &block)
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
        tmpdirs << Dir.mktmpdir([prefix, ".#{i}"])
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

def initialize_xmigra_schema(path='.')
  (Pathname(path) + XMigra::SchemaManipulator::DBINFO_FILE).open('w') do |f|
    YAML.dump({
      'system' => $xmigra_test_system,
    }, f)
  end
end

class AssertionFailure < Exception; end

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
  assert(proc {"#{actual.inspect} was equal to #{expected.inspect}"}) {actual != expected}
end

def assert_include(container, item)
  assert(proc {"#{item.inspect} was not in #{container.inspect}"}) {container.include? item}
end

TESTS.each {|t| require "test/#{t}"}

puts
puts "#{$test_successes}/#{$test_count} succeeded"
puts "Failed tests:" unless $tests_failed.empty?
$tests_failed.each {|name| puts "    #{name}"}

