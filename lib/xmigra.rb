#!/usr/bin/env ruby
# encoding: utf-8

# Copyright 2013 by Next IT Corporation.
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
# International License. To view a copy of this license, visit
# http://creativecommons.org/licenses/by-sa/4.0/.

require "digest/md5"
require "fileutils"
require "optparse"
require "ostruct"
require "pathname"
require "rbconfig"
require "rexml/document"
require "yaml"

require "xmigra/version"

unless Object.instance_methods.include? :define_singleton_method
  class Object
    def define_singleton_method(name, &body)
      metaclass = class << self; self; end
      metaclass.send(:define_method, name, &body)
      return method(name)
    end
  end
end

def Array.from_generator(proc)
  result = new
  proc.call {|item| result << item}
  return result
end

class Array
  def insert_after(element, new_element)
    insert(index(element) + 1, new_element)
  end
end

class Pathname
  def glob(rel_path, *args, &block)
    if block_given?
      Pathname.glob(self + rel_path, *args) {|p| yield self + p}
    else
      Pathname.glob(self + rel_path, *args).map {|p| self + p}
    end
  end
end

# Make YAML scalars dump back out in the same style they were when read in
if defined? YAML::Syck
  class YAML::Syck::Node
    alias_method :orig_transform_Lorjiardaik9, :transform
    def transform
      tv = orig_transform_Lorjiardaik9
      if tv.kind_of? String and @style
        node_style = @style
        tv.define_singleton_method(:to_yaml_style) {node_style}
      end
      return tv
    end
  end
  
  if defined? YAML::ENGINE.yamler
    previous = YAML::ENGINE.yamler
    YAML::ENGINE.yamler = 'syck'
    YAML::ENGINE.yamler = previous
    $xmigra_yamler = Syck
  else
    $xmigra_yamler = YAML
  end

elsif defined? Psych
  class Psych::Nodes::Scalar
    alias_method :orig_transform_Lorjiardaik9, :transform
    def transform
      tv = orig_transform_Lorjiardaik9
      if @style
        node_style = @style
        tv.define_singleton_method(:yaml_style) {node_style}
      end
      return tv
    end
  end
  
  module YAMLRepro
    class TreeBuilder < Psych::TreeBuilder
      Scalar = ::Psych::Nodes::Scalar
      
      attr_writer :next_collection_style
      
      def initialize(*args)
        super
        @next_collection_style = nil
      end
      
      def next_collection_style(default_style)
        style = @next_collection_style || default_style
        @next_collection_style = nil
        style
      end
      
      def scalar(value, anchor, tag, plain, quoted, style)
        if style_any?(style) and value.respond_to?(:yaml_style) and style = value.yaml_style
          if style_block_scalar?(style)
            plain = false
            quoted = true
          end
        end
        super
      end
      
      def style_any?(style)
        Scalar::ANY == style
      end
      
      def style_block_scalar?(style)
        [Scalar::LITERAL, Scalar::FOLDED].include? style
      end
      
      %w[sequence mapping].each do |node_type|
        class_eval <<-RUBY
          def start_#{node_type}(anchor, tag, implicit, style)
            style = next_collection_style(style)
            super
          end
        RUBY
      end
    end
    
    # Custom tree class to handle Hashes and Arrays tagged with `yaml_style`
    class YAMLTree < Psych::Visitors::YAMLTree
      %w[Hash Array Psych_Set Psych_Omap].each do |klass|
        class_eval <<-RUBY
          def visit_#{klass} o
            if o.respond_to? :yaml_style
              @emitter.next_sequence_or_mapping_style = o.yaml_style
            end
            super
          end
        RUBY
      end
    end
    
    def self.dump(data_root, io=nil, options={})
      real_io = io || StringIO.new(''.encode('utf-8'))
      visitor = YAMLTree.new(options, TreeBuilder.new)
      visitor << data_root
      ast = visitor.tree
      
      begin
        ast.yaml real_io
      rescue
        Psych::Visitors::Emitter.new(real_io).accept ast
      end
      
      io || real_io.string
    end
  end
  
  $xmigra_yamler = YAMLRepro
  
else
  $xmigra_yamler = YAML
end


module XMigra
  FORMALIZATIONS = {
    /xmigra/i=>"XMigra",
  }
  DBOBJ_NAME_SPLITTER = /^
    (?:(\[[^\[\]]+\]|[^.\[]+)\.)?     (?# Schema, match group 1)
    (\[[^\[\]]+\]|[^.\[]+)            (?# Object name, match group 2)
  $/x
  DBQUOTE_STRIPPER = /^\[?([^\]]+)\]?$/
  PLATFORM = case
  when (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) then :mswin
  else :unix
  end
  
  class Error < RuntimeError; end
  
  def self.canonize_path_case(s)
    case PLATFORM
    when :mswin then s.downcase
    else s
    end
  end
  
  def self.formalize(s)
    FORMALIZATIONS.each_pair do |pattern, result|
      return result if pattern === s
    end
    return s
  end
  
  def self.program_message(message, options={})
    prog_pattern = options[:prog] || /%prog\b/
    
    steps = [$0]
    steps << (program = self.canonize_path_case(File.basename(steps[-1])))
    steps << (prog_name = self.formalize(File.basename(steps[-2], '.rb')))
    steps << message.to_s
    steps << steps[-1].gsub(prog_pattern, program)
    steps << steps[-1].gsub(/%program_name\b/, prog_name)
    steps << steps[-1].gsub(/%cmd\b/, options[:cmd] || '<cmd>')
    return steps[-1]
  rescue
    STDERR.puts "steps: " + steps.inspect
    raise
  end
  
  class SchemaError < Error; end
  
  class << self
    def access_artifact(info)
      case info["define"]
      when "stored procedure" then StoredProcedure.new(info)
      when "view" then View.new(info)
      when "function" then Function.new(info)
      else
        raise SchemaError, "'define' not specified for access artifact '#{info['name']}'"
      end
    end
    
    def load_access_artifact(path)
      info = YAML.load_file(path)
      info['name'] = File.basename(path, '.yaml')
      artifact = access_artifact(info)
      artifact.file_path = File.expand_path(path)
      return artifact
    end
    
    def each_access_artifact(path)
      Dir.glob(File.join(path, '*.yaml')).each do |fpath|
        artifact = load_access_artifact(fpath)
        (yield artifact) if artifact
      end
    end
    
    def yaml_path(path)
      path_s = path.to_s
      if path_s.end_with?('.yaml')
        return path
      else
        return path.class.new(path_s + '.yaml')
      end
    end
    
    def secure_digest(s)
      [Digest::MD5.digest(s)].pack('m0').chomp
    end
  end
  
  module NoSpecifics; end
  
  class VersionControlError < XMigra::Error; end
  
  DatabaseSupportModules = []
  VersionControlSupportModules = []
  
  module WarnToStderr
    def warning(message)
      STDERR.puts("Warning: " + message)
      STDERR.puts
    end
  end
  
  module FoldedYamlStyle
    def to_yaml_style
      :fold
    end
    
    if defined? Psych
      def yaml_style
        Psych::Nodes::Scalar::FOLDED
      end
    end
    
  end
  
  module LiteralYamlStyle
    def to_yaml_style
      :literal
    end
    
    if defined? Psych
      def yaml_style
        Psych::Nodes::Scalar::LITERAL
      end
    end
  end
  
  def self.command_line_program
    XMigra::Program.run(
      ARGV,
      :error=>proc do |e|
        STDERR.puts("#{e} (#{e.class})") unless e.is_a?(XMigra::Program::QuietError)
        exit(2) if e.is_a?(OptionParser::ParseError)
        exit(2) if e.is_a?(XMigra::Program::ArgumentError)
        exit(1)
      end
    )
  end
end

require 'xmigra/vcs_support/svn'
require 'xmigra/vcs_support/git'

require 'xmigra/db_support/mssql'
require 'xmigra/db_support/psql'

require 'xmigra/access_artifact'
require 'xmigra/stored_procedure'
require 'xmigra/view'
require 'xmigra/function'

require 'xmigra/access_artifact_collection'
require 'xmigra/index'
require 'xmigra/index_collection'
require 'xmigra/migration'
require 'xmigra/migration_chain'
require 'xmigra/migration_conflict'
require 'xmigra/branch_upgrade'
require 'xmigra/schema_manipulator'
require 'xmigra/schema_updater'
require 'xmigra/new_migration_adder'
require 'xmigra/permission_script_writer'
require 'xmigra/source_tree_initializer'

require 'xmigra/program'

if $0 == __FILE__
  XMigra.command_line_program
end
