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
require "tsort"
require "yaml"

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
  
  class AccessArtifact
    def definition_sql
      [
        check_existence_sql(false, "%s existed before definition"),
        creation_notice,
        creation_sql + ";",
        check_existence_sql(true, "%s was not created by definition"),
        insert_access_creation_record_sql,
      ].compact.join(ddl_block_separator)
    end
    
    attr_accessor :file_path, :filename_metavariable
    
    def ddl_block_separator
      "\n"
    end
    
    def check_existence_sql(for_existence, error_message)
      nil
    end
    
    def creation_notice
      nil
    end
    
    def creation_sql
      if metavar = filename_metavariable
        @definition.gsub(metavar) {|m| self.name}
      else
        @definition
      end
    end
    
    def insert_access_creation_record_sql
      nil
    end
    
    def printable_type
      self.class.name.split('::').last.scan(/[A-Z]+[a-z]*/).collect {|p| p.downcase}.join(' ')
    end
  end
  
  class StoredProcedure < AccessArtifact
    OBJECT_TYPE = "PROCEDURE"
    
    # Construct with a hash (as if loaded from a stored procedure YAML file)
    def initialize(sproc_info)
      @name = sproc_info["name"].dup.freeze
      @definition = sproc_info["sql"].dup.freeze
    end
    
    attr_reader :name
    
    def depends_on
      []
    end
  end
  
  class View < AccessArtifact
    OBJECT_TYPE = "VIEW"
    
    # Construct with a hash (as if loaded from a view YAML file)
    def initialize(view_info)
      @name = view_info["name"].dup.freeze
      @depends_on = view_info.fetch("referencing", []).dup.freeze
      @definition = view_info["sql"].dup.freeze
    end
    
    attr_reader :name, :depends_on
  end
  
  class Function < AccessArtifact
    OBJECT_TYPE = "FUNCTION"
    
    # Construct with a hash (as if loaded from a function YAML file)
    def initialize(func_info)
      @name = func_info["name"].dup.freeze
      @depends_on = func_info.fetch("referencing", []).dup.freeze
      @definition = func_info["sql"].dup.freeze
    end
    
    attr_reader :name, :depends_on
  end
  
  class << self
    def access_artifact(info)
      case info["define"]
      when "stored procedure" then StoredProcedure.new(info)
      when "view" then View.new(info)
      when "function" then Function.new(info)
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
  
  class AccessArtifactCollection
    def initialize(path, options={})
      @items = Hash.new
      db_specifics = options[:db_specifics]
      filename_metavariable = options[:filename_metavariable]
      filename_metavariable = filename_metavariable.dup.freeze if filename_metavariable
      
      XMigra.each_access_artifact(path) do |artifact|
        @items[artifact.name] = artifact
        artifact.extend(db_specifics) if db_specifics
        artifact.filename_metavariable = filename_metavariable
      end
    end
    
    def [](name)
      @items[name]
    end
    
    def names
      @items.keys
    end
    
    def at_path(fpath)
      fpath = File.expand_path(fpath)
      return find {|i| i.file_path == fpath}
    end
    
    def each(&block); @items.each_value(&block); end
    alias tsort_each_node each
    
    def tsort_each_child(node)
      node.depends_on.each do |child|
        yield @items[child]
      end
    end
    
    include Enumerable
    include TSort
    
    def each_definition_sql
      tsort_each do |artifact|
        yield artifact.definition_sql
      end
    end
  end
  
  class Index
    def initialize(index_info)
      @name = index_info['name'].dup.freeze
      @definition = index_info['sql'].dup.freeze
    end
    
    attr_reader :name
    
    attr_accessor :file_path
    
    def id
      XMigra.secure_digest(@definition)
    end
    
    def definition_sql
      @definition
    end
  end
  
  class IndexCollection
    def initialize(path, options={})
      @items = Hash.new
      db_specifics = options[:db_specifics]
      Dir.glob(File.join(path, '*.yaml')).each do |fpath|
        info = YAML.load_file(fpath)
        info['name'] = File.basename(fpath, '.yaml')
        index = Index.new(info)
        index.extend(db_specifics) if db_specifics
        index.file_path = File.expand_path(fpath)
        @items[index.name] = index
      end
    end
    
    def [](name)
      @items[name]
    end
    
    def names
      @items.keys
    end
    
    def each(&block); @items.each_value(&block); end
    include Enumerable
    
    def each_definition_sql
      each {|i| yield i.definition_sql}
    end
    
    def empty?
      @items.empty?
    end
  end
  
  class Migration
    EMPTY_DB = 'empty database'
    FOLLOWS = 'starting from'
    CHANGES = 'changes'
    
    def initialize(info)
      @id = info['id'].dup.freeze
      _follows = info[FOLLOWS]
      @follows = (_follows.dup.freeze unless _follows == EMPTY_DB)
      @sql = info["sql"].dup.freeze
      @description = info["description"].dup.freeze
      @changes = (info[CHANGES] || []).dup.freeze
      @changes.each {|c| c.freeze}
    end
    
    attr_reader :id, :follows, :sql, :description, :changes
    attr_accessor :file_path
    
    class << self
      def id_from_filename(fname)
        XMigra.secure_digest(fname.upcase) # Base64 encoded digest
      end
    end
  end
  
  class MigrationChain < Array
    HEAD_FILE = 'head.yaml'
    LATEST_CHANGE = 'latest change'
    MIGRATION_FILE_PATTERN = /^\d{4}-\d\d-\d\d.*\.yaml$/i
    
    def initialize(path, options={})
      super()
      
      db_specifics = options[:db_specifics]
      vcs_specifics = options[:vcs_specifics]
      
      head_info = YAML.load_file(File.join(path, HEAD_FILE))
      file = head_info[LATEST_CHANGE]
      prev_file = HEAD_FILE
      files_loaded = []
      
      until file.nil?
        file = XMigra.yaml_path(file)
        fpath = File.join(path, file)
        break unless File.file?(fpath)
        begin
          mig_info = YAML.load_file(fpath)
        rescue
          raise XMigra::Error, "Error loading/parsing #{fpath}"
        end
        files_loaded << file
        mig_info["id"] = Migration::id_from_filename(file)
        migration = Migration.new(mig_info)
        migration.file_path = File.expand_path(fpath)
        migration.extend(db_specifics) if db_specifics
        migration.extend(vcs_specifics) if vcs_specifics
        unshift(migration)
        prev_file = file
        file = migration.follows
        unless file.nil? || MIGRATION_FILE_PATTERN.match(XMigra.yaml_path(file))
          raise XMigra::Error, "Invalid migration file \"#{file}\" referenced from \"#{prev_file}\""
        end
      end
      
      @other_migrations = []
      Dir.foreach(path) do |fname|
        if MIGRATION_FILE_PATTERN.match(fname) && !files_loaded.include?(fname)
          @other_migrations << fname.freeze
        end
      end
      @other_migrations.freeze
    end
    
    # Test if the chain reaches back to the empty database
    def complete?
      length > 0 && self[0].follows.nil?
    end
    
    # Test if the chain encompasses all migration-like filenames in the path
    def includes_all?
      @other_migrations.empty?
    end
  end
  
  class MigrationConflict
    def initialize(path, branch_point, heads)
      @path = Pathname.new(path)
      @branch_point = branch_point
      @heads = heads
      @branch_use = :undefined
      @scope = :repository
      @after_fix = nil
    end
    
    attr_accessor :branch_use, :scope, :after_fix
    
    def resolvable?
      head_0 = @heads[0]
      @heads[1].each_pair do |k, v|
        next unless head_0.has_key?(k)
        next if k == MigrationChain::LATEST_CHANGE
        return false unless head_0[k] == v
      end
      
      return true
    end
    
    def migration_tweak
      unless defined? @migration_to_fix and defined? @fixed_migration_contents
        # Walk the chain from @head[1][MigrationChain::LATEST_CHANGE] and find
        # the first migration after @branch_point
        branch_file = XMigra.yaml_path(@branch_point)
        cur_mig = XMigra.yaml_path(@heads[1][MigrationChain::LATEST_CHANGE])
        until cur_mig.nil?
          mig_info = YAML.load_file(@path.join(cur_mig))
          prev_mig = XMigra.yaml_path(mig_info[Migration::FOLLOWS])
          break if prev_mig == branch_file
          cur_mig = prev_mig
        end
        
        mig_info[Migration::FOLLOWS] = @heads[0][MigrationChain::LATEST_CHANGE]
        @migration_to_fix = cur_mig
        @fixed_migration_contents = mig_info
      end
      
      return @migration_to_fix, @fixed_migration_contents
    end
    
    def fix_conflict!
      raise(VersionControlError, "Unresolvable conflict") unless resolvable?
      
      file_to_fix, fixed_contents = migration_tweak
      
      # Rewrite the head file
      head_info = @heads[0].merge(@heads[1]) # This means @heads[1]'s LATEST_CHANGE wins
      File.open(@path.join(MigrationChain::HEAD_FILE), 'w') do |f|
        YAML.dump(head_info, f)
      end
      
      # Rewrite the first migration (on the current branch) after @branch_point
      File.open(@path.join(file_to_fix), 'w') do |f|
        YAML.dump(fixed_contents, f)
      end
      
      if @after_fix
        @after_fix.call
      end
    end
  end

  class BranchUpgrade
    TARGET_BRANCH = "resulting branch"
    MIGRATION_COMPLETED = "completes migration to"
    
    def initialize(path)
      @file_path = path
      @warnings = []
      
      verinc_info = {}
      if path.exist?
        @found = true
        begin
          verinc_info = YAML.load_file(path)
        rescue Error => e
          warning "Failed to load branch upgrade migration (#{e.class}).\n  #{e}"
          verinc_info = {}
        end
      end
      
      @base_migration = verinc_info[Migration::FOLLOWS]
      @target_branch = (XMigra.secure_digest(verinc_info[TARGET_BRANCH]) if verinc_info.has_key? TARGET_BRANCH)
      @migration_completed = verinc_info[MIGRATION_COMPLETED]
      @sql = verinc_info['sql']
    end
    
    attr_reader :file_path, :base_migration, :target_branch, :migration_completed, :sql
    
    def found?
      @found
    end
    
    def applicable?(mig_chain)
      return false if mig_chain.length < 1
      return false unless (@base_migration && @target_branch)
      
      return File.basename(mig_chain[-1].file_path) == XMigra.yaml_path(@base_migration)
    end
    
    def has_warnings?
      not @warnings.empty?
    end
    
    def warnings
      @warnings.dup
    end
    
    def migration_completed_id
      Migration.id_from_filename(XMigra.yaml_path(migration_completed))
    end
    
    private
    
    def warning(s)
      s.freeze
      @warnings << s
    end
  end
  
  module NoSpecifics; end
  
  module MSSQLSpecifics
    IDENTIFIER_SUBPATTERN = '[a-z_@#][a-z0-9@$#_]*|"[^\[\]"]+"|\[[^\[\]]+\]'
    DBNAME_PATTERN = /^
      (?:(#{IDENTIFIER_SUBPATTERN})\.)?
      (#{IDENTIFIER_SUBPATTERN})
    $/ix
    STATISTICS_FILE = 'statistics-objects.yaml'
    
    class StatisticsObject
      def initialize(name, params)
        (@name = name.dup).freeze
        (@target = params[0].dup).freeze
        (@columns = params[1].dup).freeze
        @options = params[2] || {}
        @options.freeze
        @options.each_value {|v| v.freeze}
      end
      
      attr_reader :name, :target, :columns, :options
      
      def creation_sql
        result = "CREATE STATISTICS #{name} ON #{target} (#{columns})"
        
        result += " WHERE " + @options['where'] if @options['where']
        result += " WITH " + @options['with'] if @options['with']
        
        result += ";"
        return result
      end
    end
    
    def ddl_block_separator; "\nGO\n"; end
    def filename_metavariable; "[{filename}]"; end
    
    def stats_objs
      return @stats_objs if @stats_objs
      
      begin
        stats_data = YAML::load_file(path.join(MSSQLSpecifics::STATISTICS_FILE))
      rescue Errno::ENOENT
        return @stats_objs = [].freeze
      end
      
      @stats_objs = stats_data.collect(&StatisticsObject.method(:new))
      @stats_objs.each {|o| o.freeze}
      @stats_objs.freeze
      
      return @stats_objs
    end
    
    def in_ddl_transaction
      parts = []
      parts << <<-"END_OF_SQL"
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

SET ANSI_PADDING ON
GO

SET NOCOUNT ON
GO

BEGIN TRY
  BEGIN TRAN;
      END_OF_SQL
      
      each_batch(yield) do |batch|
        batch_literal = MSSQLSpecifics.string_literal("\n" + batch)
        parts << "EXEC sp_executesql @statement = #{batch_literal};"
      end
      
      parts << <<-"END_OF_SQL"
  COMMIT TRAN;
END TRY
BEGIN CATCH
  ROLLBACK TRAN;
  
  DECLARE @ErrorMessage NVARCHAR(4000);
  DECLARE @ErrorSeverity INT;
  DECLARE @ErrorState INT;
  
  PRINT N'Update failed: ' + ERROR_MESSAGE();
  PRINT N'    State: ' + CAST(ERROR_STATE() AS NVARCHAR);
  PRINT N'    Line: ' + CAST(ERROR_LINE() AS NVARCHAR);

  SELECT 
      @ErrorMessage = N'Update failed: ' + ERROR_MESSAGE(),
      @ErrorSeverity = ERROR_SEVERITY(),
      @ErrorState = ERROR_STATE();

  -- Use RAISERROR inside the CATCH block to return error
  -- information about the original error that caused
  -- execution to jump to the CATCH block.
  RAISERROR (@ErrorMessage, -- Message text.
             @ErrorSeverity, -- Severity.
             @ErrorState -- State.
             );
END CATCH;
      END_OF_SQL
      
      return parts.join("\n")
    end
    
    def amend_script_parts(parts)
      parts.insert_after(
        :create_and_fill_indexes_table_sql,
        :create_and_fill_statistics_table_sql
      )
      parts.insert_after(
        :remove_undesired_indexes_sql,
        :remove_undesired_statistics_sql
      )
      parts.insert_after(:create_new_indexes_sql, :create_new_statistics_sql)
    end
    
    def check_execution_environment_sql
      <<-"END_OF_SQL"
PRINT N'Checking execution environment:';
IF DB_NAME() IN ('master', 'tempdb', 'model', 'msdb')
BEGIN
  RAISERROR(N'Please select an appropriate target database for the update script.', 11, 1);
END;
      END_OF_SQL
    end
    
    def ensure_version_tables_sql
      <<-"END_OF_SQL"
PRINT N'Ensuring version tables:';
IF NOT EXISTS (
  SELECT * FROM sys.schemas
  WHERE name = N'xmigra'
)
BEGIN
  EXEC sp_executesql N'
    CREATE SCHEMA [xmigra] AUTHORIZATION [dbo];
  ';
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[applied]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[applied] (
    [MigrationID]            nvarchar(80) NOT NULL,
    [ApplicationOrder]       int IDENTITY(1,1) NOT NULL,
    [VersionBridgeMark]      bit NOT NULL,
    [Description]            nvarchar(max) NOT NULL,
    
    CONSTRAINT [PK_version] PRIMARY KEY CLUSTERED (
      [MigrationID] ASC
    ) WITH (
      PAD_INDEX = OFF,
      STATISTICS_NORECOMPUTE  = OFF,
      IGNORE_DUP_KEY = OFF,
      ALLOW_ROW_LOCKS = ON,
      ALLOW_PAGE_LOCKS = ON
    ) ON [PRIMARY]
  ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[DF_version_VersionBridgeMark]')
  AND type IN (N'D')
)
BEGIN
  ALTER TABLE [xmigra].[applied] ADD CONSTRAINT [DF_version_VersionBridgeMark]
    DEFAULT (0) FOR [VersionBridgeMark];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[access_objects]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[access_objects] (
    [type] nvarchar(40) NOT NULL,
    [name] nvarchar(256) NOT NULL,
    [order] int identity(1,1) NOT NULL,
    
    CONSTRAINT [PK_access_objects] PRIMARY KEY CLUSTERED (
      [name] ASC
    ) WITH (
      PAD_INDEX = OFF,
      STATISTICS_NORECOMPUTE  = OFF,
      IGNORE_DUP_KEY = OFF,
      ALLOW_ROW_LOCKS = ON,
      ALLOW_PAGE_LOCKS = ON
    ) ON [PRIMARY]
  ) ON [PRIMARY];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[indexes]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[indexes] (
    [IndexID] nvarchar(80) NOT NULL PRIMARY KEY,
    [name] nvarchar(256) NOT NULL
  ) ON [PRIMARY];
END;

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[statistics]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[statistics] (
    [Name] nvarchar(100) NOT NULL PRIMARY KEY,
    [Columns] nvarchar(256) NOT NULL
  ) ON [PRIMARY];
END;

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[branch_upgrade]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[branch_upgrade] (
    [ApplicationOrder] int identity(1,1) NOT NULL,
    [Current] nvarchar(80) NOT NULL PRIMARY KEY,
    [Next] nvarchar(80) NULL,
    [UpgradeSql] nvarchar(max) NULL,
    [CompletesMigration] nvarchar(80) NULL
  ) ON [PRIMARY];
END;
      END_OF_SQL
    end
    
    def create_and_fill_migration_table_sql
      intro = <<-"END_OF_SQL"
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[migrations]')
  AND type IN (N'U')
)
BEGIN
  DROP TABLE [xmigra].[migrations];
END;
GO

CREATE TABLE [xmigra].[migrations] (
  [MigrationID]            nvarchar(80) NOT NULL,
  [ApplicationOrder]       int NOT NULL,
  [Description]            ntext NOT NULL,
  [Install]                bit NOT NULL DEFAULT(0)
);
GO

      END_OF_SQL
      
      mig_insert = <<-"END_OF_SQL"
INSERT INTO [xmigra].[migrations] (
  [MigrationID],
  [ApplicationOrder],
  [Description]
) VALUES
      END_OF_SQL
      
      if (@db_info || {}).fetch('MSSQL 2005 compatible', false).eql?(true)
        parts = [intro]
        (0...migrations.length).each do |i|
          m = migrations[i]
          description_literal = MSSQLSpecifics.string_literal(m.description.strip)
          parts << mig_insert + "(N'#{m.id}', #{i + 1}, #{description_literal});\n"
        end
        return parts.join('')
      else
        return intro + mig_insert + (0...migrations.length).collect do |i|
          m = migrations[i]
          description_literal = MSSQLSpecifics.string_literal(m.description.strip)
          "(N'#{m.id}', #{i + 1}, #{description_literal})"
        end.join(",\n") + ";\n"
      end
    end
    
    def create_and_fill_indexes_table_sql
      intro = <<-"END_OF_SQL"
PRINT N'Creating and filling index manipulation table:';
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[updated_indexes]')
  AND type IN (N'U')
)
BEGIN
  DROP TABLE [xmigra].[updated_indexes];
END;
GO

CREATE TABLE [xmigra].[updated_indexes] (
  [IndexID]                  NVARCHAR(80) NOT NULL PRIMARY KEY
);
GO

      END_OF_SQL
      
      insertion = <<-"END_OF_SQL"
INSERT INTO [xmigra].[updated_indexes] ([IndexID]) VALUES
      END_OF_SQL
      
      strlit = MSSQLSpecifics.method :string_literal
      return intro + insertion + indexes.collect do |index|
        "(#{strlit[index.id]})"
      end.join(",\n") + ";\n" unless indexes.empty?
      
      return intro
    end
    
    def create_and_fill_statistics_table_sql
      intro = <<-"END_OF_SQL"
PRINT N'Creating and filling statistics object manipulation table:';
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[updated_statistics]')
  AND type in (N'U')
)
BEGIN
  DROP TABLE [xmigra].[updated_statistics];
END;
GO

CREATE TABLE [xmigra].[updated_statistics] (
  [Name] nvarchar(100) NOT NULL PRIMARY KEY,
  [Columns] nvarchar(256) NOT NULL
);
GO

      END_OF_SQL
      
      insertion = <<-"END_OF_SQL"
INSERT INTO [xmigra].[updated_statistics] ([Name], [Columns]) VALUES
      END_OF_SQL
      
      strlit = MSSQLSpecifics.method :string_literal
      return intro + insertion + stats_objs.collect do |stats_obj|
        "(#{strlit[stats_obj.name]}, #{strlit[stats_obj.columns]})"
      end.join(",\n") + ";\n" unless stats_objs.empty?
    end
    
    def check_preceding_migrations_sql
      parts = []
      
      parts << (<<-"END_OF_SQL") if production 
IF EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
) AND NOT EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
  WHERE #{branch_id_literal} IN ([Current], [Next])
)
RAISERROR (N'Existing database is from a different (and non-upgradable) branch.', 11, 1);

      END_OF_SQL
      
      parts << (<<-"END_OF_SQL")
IF NOT #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Checking preceding migrations:';
  -- Get the ApplicationOrder of the most recent version bridge migration
  DECLARE @VersionBridge INT;
  SET @VersionBridge = (
    SELECT COALESCE(MAX([ApplicationOrder]), 0)
    FROM [xmigra].[applied]
    WHERE [VersionBridgeMark] <> 0
  );
  
  -- Check for existence of applied migrations after the latest version
  -- bridge that are not in [xmigra].[migrations]
  IF EXISTS (
    SELECT * FROM [xmigra].[applied] a
    WHERE a.[ApplicationOrder] > @VersionBridge
    AND a.[MigrationID] NOT IN (
      SELECT m.[MigrationID] FROM [xmigra].[migrations] m
    )
  )
  RAISERROR (N'Unknown in-version migrations have been applied.', 11, 1);
END;
      END_OF_SQL
      
      return parts.join('')
    end
    
    def check_chain_continuity_sql
      <<-"END_OF_SQL"
IF NOT #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Checking migration chain continuity:';
  -- Get the [xmigra].[migrations] ApplicationOrder of the most recent version bridge migration
  DECLARE @BridgePoint INT;
  SET @BridgePoint = (
    SELECT COALESCE(MAX(m.[ApplicationOrder]), 0)
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    WHERE a.[VersionBridgeMark] <> 0
  );
  
  -- Test for previously applied migrations that break the continuity of the
  -- migration chain in this script:
  IF EXISTS (
    SELECT *
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    INNER JOIN [xmigra].[migrations] p
      ON m.[ApplicationOrder] - 1 = p.[ApplicationOrder]
    WHERE p.[ApplicationOrder] > @BridgePoint
    AND p.[MigrationID] NOT IN (
      SELECT a2.[MigrationID] FROM [xmigra].[applied] a2
    )
  )
  BEGIN
    RAISERROR(
      N'Previously applied migrations interrupt the continuity of the migration chain',
      11,
      1
    );
  END;
END;
      END_OF_SQL
    end
    
    def select_for_install_sql
      <<-"END_OF_SQL"
PRINT N'Selecting migrations to apply:';
DECLARE @BridgePoint INT;
IF #{upgrading_to_new_branch_test_sql}
BEGIN
  -- Get the [xmigra].[migrations] ApplicationOrder of the record corresponding to the branch transition
  SET @BridgePoint = (
    SELECT MAX(m.[ApplicationOrder])
    FROM [xmigra].[migrations] m
    INNER JOIN [xmigra].[branch_upgrade] bu
      ON m.[MigrationID] = bu.[CompletesMigration]
  );
  
  UPDATE [xmigra].[migrations]
  SET [Install] = 1
  WHERE [ApplicationOrder] > @BridgePoint;
END
ELSE BEGIN
  -- Get the [xmigra].[migrations] ApplicationOrder of the most recent version bridge migration
  SET @BridgePoint = (
    SELECT COALESCE(MAX(m.[ApplicationOrder]), 0)
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    WHERE a.[VersionBridgeMark] <> 0
  );
  
  UPDATE [xmigra].[migrations]
  SET [Install] = 1
  WHERE [MigrationID] NOT IN (
    SELECT a.[MigrationID] FROM [xmigra].[applied] a
  )
  AND [ApplicationOrder] > @BridgePoint;
END;
      END_OF_SQL
    end
    
    def production_config_check_sql
      unless production
        id_literal = MSSQLSpecifics.string_literal(@migrations[0].id)
        <<-"END_OF_SQL"
PRINT N'Checking for production status:';
IF EXISTS (
  SELECT * FROM [xmigra].[migrations]
  WHERE [MigrationID] = #{id_literal}
  AND [Install] <> 0
)
BEGIN
  CREATE TABLE [xmigra].[development] (
    [info] nvarchar(200) NOT NULL PRIMARY KEY
  );
END;
GO

IF NOT EXISTS (
  SELECT * FROM [sys].[objects]
  WHERE object_id = OBJECT_ID(N'[xmigra].[development]')
  AND type = N'U'
)
RAISERROR(N'Development script cannot be applied to a production database.', 11, 1);
        END_OF_SQL
      end
    end
    
    def remove_access_artifacts_sql
      # Iterate the [xmigra].[access_objects] table and drop all access
      # objects previously created by xmigra
      return <<-"END_OF_SQL"
PRINT N'Removing data access artifacts:';
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @obj_name NVARCHAR(256); -- Name of object to drop
DECLARE @obj_type NVARCHAR(40); -- Type of object to drop

DECLARE AccObjs_cursor CURSOR LOCAL FOR
SELECT [name], [type]
FROM [xmigra].[access_objects]
ORDER BY [order] DESC;

OPEN AccObjs_cursor;

FETCH NEXT FROM AccObjs_cursor INTO @obj_name, @obj_type;

WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sqlcmd = N'DROP ' + @obj_type + N' ' + @obj_name + N';';
  EXEC sp_executesql @sqlcmd;
  
  FETCH NEXT FROM AccObjs_cursor INTO @obj_name, @obj_type;
END;

CLOSE AccObjs_cursor;
DEALLOCATE AccObjs_cursor;

DELETE FROM [xmigra].[access_objects];

END_OF_SQL
    end
    
    def remove_undesired_indexes_sql
      <<-"END_OF_SQL"
PRINT N'Removing undesired indexes:';
-- Iterate over indexes in [xmigra].[indexes] that don't have an entry in
-- [xmigra].[updated_indexes].
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @index_name NVARCHAR(256); -- Name of index to drop
DECLARE @table_name SYSNAME; -- Name of table owning index
DECLARE @match_count INT; -- Number of matching index names

DECLARE Index_cursor CURSOR LOCAL FOR
SELECT 
  xi.[name], 
  MAX(QUOTENAME(OBJECT_SCHEMA_NAME(si.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(si.object_id))), 
  COUNT(*)
FROM [xmigra].[indexes] xi
INNER JOIN sys.indexes si ON si.[name] = xi.[name]
WHERE xi.[IndexID] NOT IN (
  SELECT [IndexID]
  FROM [xmigra].[updated_indexes]
)
GROUP BY xi.[name];

OPEN Index_cursor;

FETCH NEXT FROM Index_cursor INTO @index_name, @table_name, @match_count;

WHILE @@FETCH_STATUS = 0 BEGIN
  IF @match_count > 1
  BEGIN
    RAISERROR(N'Multiple indexes are named %s', 11, 1, @index_name);
  END;
  
  SET @sqlcmd = N'DROP INDEX ' + @index_name + N' ON ' + @table_name + N';';
  EXEC sp_executesql @sqlcmd;
  PRINT N'    Removed ' + @index_name + N'.';
  
  FETCH NEXT FROM Index_cursor INTO @index_name, @table_name, @match_count;
END;

CLOSE Index_cursor;
DEALLOCATE Index_cursor;

DELETE FROM [xmigra].[indexes]
WHERE [IndexID] NOT IN (
  SELECT ui.[IndexID]
  FROM [xmigra].[updated_indexes] ui
);
      END_OF_SQL
    end
    
    def remove_undesired_statistics_sql
      <<-"END_OF_SQL"
PRINT N'Removing undesired statistics objects:';
-- Iterate over statistics in [xmigra].[statistics] that don't have an entry in
-- [xmigra].[updated_statistics].
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @statsobj_name NVARCHAR(256); -- Name of statistics object to drop
DECLARE @table_name SYSNAME; -- Name of table owning the statistics object
DECLARE @match_count INT; -- Number of matching statistics object names

DECLARE Stats_cursor CURSOR LOCAL FOR
SELECT 
  QUOTENAME(xs.[Name]), 
  MAX(QUOTENAME(OBJECT_SCHEMA_NAME(ss.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(ss.object_id))), 
  COUNT(ss.object_id)
FROM [xmigra].[statistics] xs
INNER JOIN sys.stats ss ON ss.[name] = xs.[Name]
WHERE xs.[Columns] NOT IN (
  SELECT us.[Columns]
  FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = xs.[Name]
)
GROUP BY xs.[Name];

OPEN Stats_cursor;

FETCH NEXT FROM Stats_cursor INTO @statsobj_name, @table_name, @match_count;

WHILE @@FETCH_STATUS = 0 BEGIN
  IF @match_count > 1
  BEGIN
    RAISERROR(N'Multiple indexes are named %s', 11, 1, @statsobj_name);
  END;
  
  SET @sqlcmd = N'DROP STATISTICS ' + @table_name + N'.' + @statsobj_name + N';';
  EXEC sp_executesql @sqlcmd;
  PRINT N'    Removed statistics object ' + @statsobj_name + N'.'
  
  FETCH NEXT FROM Stats_cursor INTO @statsobj_name, @table_name, @match_count;
END;

CLOSE Stats_cursor;
DEALLOCATE Stats_cursor;

DELETE FROM [xmigra].[statistics]
WHERE [Columns] NOT IN (
  SELECT us.[Columns]
  FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = [Name]
);
      END_OF_SQL
    end
    
    def create_new_indexes_sql
      indexes.collect do |index|
        index_id_literal = MSSQLSpecifics.string_literal(index.id)
        index_name_literal = MSSQLSpecifics.string_literal(index.name)
        <<-"END_OF_SQL"
PRINT N'Index ' + #{index_id_literal} + ':';
IF EXISTS(
  SELECT * FROM [xmigra].[updated_indexes] ui
  WHERE ui.[IndexID] = #{index_id_literal}
  AND ui.[IndexID] NOT IN (
    SELECT i.[IndexID] FROM [xmigra].[indexes] i
  )
)
BEGIN
  IF EXISTS (
    SELECT * FROM sys.indexes
    WHERE [name] = #{index_name_literal}
  )
  BEGIN
    RAISERROR(N'An index already exists named %s', 11, 1, #{index_name_literal});
  END;
  
  PRINT N'    Creating...';
  #{index.definition_sql};
  
  IF (SELECT COUNT(*) FROM sys.indexes WHERE [name] = #{index_name_literal}) <> 1
  BEGIN
    RAISERROR(N'Index %s was not created by its definition.', 11, 1,
      #{index_name_literal});
  END;

  INSERT INTO [xmigra].[indexes] ([IndexID], [name])
  VALUES (#{index_id_literal}, #{index_name_literal});
END
ELSE
BEGIN
  PRINT N'    Already exists.';
END;
        END_OF_SQL
      end.join(ddl_block_separator)
    end
    
    def create_new_statistics_sql
      stats_objs.collect do |stats_obj|
        stats_name = MSSQLSpecifics.string_literal(stats_obj.name)
        strlit = lambda {|s| MSSQLSpecifics.string_literal(s)}
        
        stats_obj.creation_sql
        <<-"END_OF_SQL"
PRINT N'Statistics object #{stats_obj.name}:';
IF EXISTS (
  SELECT * FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = #{stats_name}
  AND us.[Columns] NOT IN (
    SELECT s.[Columns]
    FROM [xmigra].[statistics] s
    WHERE s.[Name] = us.[Name]
  )
)
BEGIN
  IF EXISTS (
    SELECT * FROM sys.stats
    WHERE [name] = #{stats_name}
  )
  BEGIN
    RAISERROR(N'A statistics object named %s already exists.', 11, 1, #{stats_name})
  END;
  
  PRINT N'    Creating...';
  #{stats_obj.creation_sql}
  
  INSERT INTO [xmigra].[statistics] ([Name], [Columns])
  VALUES (#{stats_name}, #{strlit[stats_obj.columns]})
END
ELSE
BEGIN
  PRINT N'    Already exists.';
END;
        END_OF_SQL
      end.join(ddl_block_separator)
    end
    
    def upgrade_cleanup_sql
      <<-"END_OF_SQL"
PRINT N'Cleaning up from the upgrade:';
DROP TABLE [xmigra].[migrations];
DROP TABLE [xmigra].[updated_indexes];
DROP TABLE [xmigra].[updated_statistics];
      END_OF_SQL
    end
    
    def ensure_permissions_table_sql
      strlit = MSSQLSpecifics.method(:string_literal)
      <<-"END_OF_SQL"
-- ------------ SET UP XMIGRA PERMISSION TRACKING OBJECTS ------------ --

PRINT N'Setting up XMigra permission tracking:';
IF NOT EXISTS (
  SELECT * FROM sys.schemas
  WHERE name = N'xmigra'
)
BEGIN
  EXEC sp_executesql N'
    CREATE SCHEMA [xmigra] AUTHORIZATION [dbo];
  ';
END;
GO

IF NOT EXISTS(
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[revokable_permissions]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[revokable_permissions] (
    [permissions] nvarchar(200) NOT NULL,
    [object] nvarchar(260) NOT NULL,
    [principal_id] int NOT NULL
  ) ON [PRIMARY];
END;
GO

IF EXISTS(
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[ip_prepare_revoke]')
  AND type IN (N'P', N'PC')
)
BEGIN
  DROP PROCEDURE [xmigra].[ip_prepare_revoke];
END;
GO

CREATE PROCEDURE [xmigra].[ip_prepare_revoke]
(
  @permissions nvarchar(200),
  @object nvarchar(260),
  @principal sysname
)
AS
BEGIN
  INSERT INTO [xmigra].[revokable_permissions] ([permissions], [object], [principal_id])
  VALUES (@permissions, @object, DATABASE_PRINCIPAL_ID(@principal));
END;
      END_OF_SQL
    end
    
    def revoke_previous_permissions_sql
      <<-"END_OF_SQL"

-- ------------- REVOKING PREVIOUSLY GRANTED PERMISSIONS ------------- --

PRINT N'Revoking previously granted permissions:';
-- Iterate over permissions listed in [xmigra].[revokable_permissions]
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @permissions NVARCHAR(200); 
DECLARE @object NVARCHAR(260); 
DECLARE @principal NVARCHAR(150);

DECLARE Permission_cursor CURSOR LOCAL FOR
SELECT
  xp.[permissions],
  xp.[object],
  QUOTENAME(sdp.name)
FROM [xmigra].[revokable_permissions] xp
INNER JOIN sys.database_principals sdp ON xp.principal_id = sdp.principal_id;

OPEN Permission_cursor;

FETCH NEXT FROM Permission_cursor INTO @permissions, @object, @principal;

WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sqlcmd = N'REVOKE ' + @permissions + N' ON ' + @object + ' FROM ' + @principal + N';';
  BEGIN TRY
    EXEC sp_executesql @sqlcmd;
  END TRY
  BEGIN CATCH
  END CATCH
  
  FETCH NEXT FROM Permission_cursor INTO @permissions, @object, @principal;
END;

CLOSE Permission_cursor;
DEALLOCATE Permission_cursor;

DELETE FROM [xmigra].[revokable_permissions];
      END_OF_SQL
    end
    
    def granting_permissions_comment_sql
      <<-"END_OF_SQL"
      
-- ---------------------- GRANTING PERMISSIONS ----------------------- --

      END_OF_SQL
    end
    
    def grant_permissions_sql(permissions, object, principal)
      strlit = MSSQLSpecifics.method(:string_literal)
      permissions_string = permissions.to_a.join(', ')
      
      <<-"END_OF_SQL"
PRINT N'Granting #{permissions_string} on #{object} to #{principal}:';
GRANT #{permissions_string} ON #{object} TO #{principal};
    EXEC [xmigra].[ip_prepare_revoke] #{strlit[permissions_string]}, #{strlit[object]}, #{strlit[principal]};
      END_OF_SQL
    end
    
    def insert_access_creation_record_sql
      name_literal = MSSQLSpecifics.string_literal(quoted_name)
      
      <<-"END_OF_SQL"
INSERT INTO [xmigra].[access_objects] ([type], [name])
VALUES (N'#{self.class::OBJECT_TYPE}', #{name_literal});
      END_OF_SQL
    end
    
    # Call on an extended Migration object to get the SQL to execute.
    def migration_application_sql
      id_literal = MSSQLSpecifics.string_literal(id)
      template = <<-"END_OF_SQL"
IF EXISTS (
  SELECT * FROM [xmigra].[migrations]
  WHERE [MigrationID] = #{id_literal}
  AND [Install] <> 0
)
BEGIN
  PRINT #{MSSQLSpecifics.string_literal('Applying "' + File.basename(file_path) + '":')};
  
%s

  INSERT INTO [xmigra].[applied] ([MigrationID], [Description])
  VALUES (#{id_literal}, #{MSSQLSpecifics.string_literal(description)});
END;
      END_OF_SQL
      
      parts = []
      
      each_batch(sql) do |batch|
        parts << batch
      end
      
      return (template % parts.collect do |batch|
        "EXEC sp_executesql @statement = " + MSSQLSpecifics.string_literal(batch) + ";"
      end.join("\n"))
    end
    
    def each_batch(sql)
      current_batch_lines = []
      sql.each_line do |line|
        if line.strip.upcase == 'GO'
          batch = current_batch_lines.join('')
          yield batch unless batch.strip.empty?
          current_batch_lines.clear
        else
          current_batch_lines << line
        end
      end
      unless current_batch_lines.empty?
        batch = current_batch_lines.join('')
        yield batch unless batch.strip.empty?
      end
    end
    
    def batch_separator
      "GO\n"
    end
    
    def check_existence_sql(for_existence, error_message)
      error_message = sprintf(error_message, quoted_name)
      
      return <<-"END_OF_SQL"
    
IF #{"NOT" if for_existence} #{existence_test_sql}
RAISERROR(N'#{error_message}', 11, 1);
      END_OF_SQL
    end
    
    def creation_notice
      return "PRINT " + MSSQLSpecifics.string_literal("Creating #{printable_type} #{quoted_name}:") + ";"
    end
    
    def name_parts
      if m = DBNAME_PATTERN.match(name)
        [m[1], m[2]].compact.collect do |p|
          MSSQLSpecifics.strip_identifier_quoting(p)
        end
      else
        raise XMigra::Error, "Invalid database object name"
      end
    end
    
    def quoted_name
      name_parts.collect do |p|
        "[]".insert(1, p)
      end.join('.')
    end
    
    def object_type_codes
      MSSQLSpecifics.object_type_codes(self)
    end
    
    def existence_test_sql
      object_type_list = object_type_codes.collect {|t| "N'#{t}'"}.join(', ')
      
      return <<-"END_OF_SQL"
EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'#{quoted_name}')
  AND type IN (#{object_type_list})
)
      END_OF_SQL
    end
    
    def branch_id_literal
      @mssql_branch_id_literal ||= MSSQLSpecifics.string_literal(XMigra.secure_digest(branch_identifier))
    end
    
    def upgrading_to_new_branch_test_sql
      (<<-"END_OF_SQL").chomp
(EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
  WHERE [Next] = #{branch_id_literal}
))
      END_OF_SQL
    end
    
    def branch_upgrade_sql
      parts = [<<-"END_OF_SQL"]
IF #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Migrating from previous schema branch:';
  
  DECLARE @sqlcmd NVARCHAR(MAX);
  
  DECLARE CmdCursor CURSOR LOCAL FOR
  SELECT bu.[UpgradeSql]
  FROM [xmigra].[branch_upgrade] bu
  WHERE bu.[Next] = #{branch_id_literal}
  ORDER BY bu.[ApplicationOrder] ASC;
  
  OPEN CmdCursor;
  
  FETCH NEXT FROM CmdCursor INTO @sqlcmd;
  
  WHILE @@FETCH_STATUS = 0 BEGIN
    EXECUTE sp_executesql @sqlcmd;
    
    FETCH NEXT FROM CmdCursor INTO @sqlcmd;
  END;
  
  CLOSE CmdCursor;
  DEALLOCATE CmdCursor;
  
  DECLARE @applied NVARCHAR(80);
  DECLARE @old_branch NVARCHAR(80);
  
  SELECT TOP(1) @applied = [CompletesMigration], @old_branch = [Current]
  FROM [xmigra].[branch_upgrade]
  WHERE [Next] = #{branch_id_literal};
  
  -- Delete the "applied" record for the migration if there was one, so that
  -- a new record with this ID can be inserted.
  DELETE FROM [xmigra].[applied] WHERE [MigrationID] = @applied;
  
  -- Create a "version bridge" record in the "applied" table for the branch upgrade
  INSERT INTO [xmigra].[applied] ([MigrationID], [VersionBridgeMark], [Description])
  VALUES (@applied, 1, N'Branch upgrade from branch ' + @old_branch);
END;

DELETE FROM [xmigra].[branch_upgrade];

      END_OF_SQL
      
      if branch_upgrade.applicable? migrations
        batch_template = <<-"END_OF_SQL"
INSERT INTO [xmigra].[branch_upgrade]
([Current], [Next], [CompletesMigration], [UpgradeSql])
VALUES (
  #{branch_id_literal},
  #{MSSQLSpecifics.string_literal(branch_upgrade.target_branch)},
  #{MSSQLSpecifics.string_literal(branch_upgrade.migration_completed_id)},
  %s
);
        END_OF_SQL
        
        each_batch(branch_upgrade.sql) do |batch|
          # Insert the batch into the [xmigra].[branch_upgrade] table
          parts << (batch_template % MSSQLSpecifics.string_literal(batch))
        end
      else
        # Insert a placeholder that only declares the current branch of the schema
        parts << <<-"END_OF_SQL"
INSERT INTO [xmigra].[branch_upgrade] ([Current]) VALUES (#{branch_id_literal});
        END_OF_SQL
      end
      
      return parts.join("\n")
    end
    
    class << self
      def strip_identifier_quoting(s)
        case
        when s.empty? then return s
        when s[0,1] == "[" && s[-1,1] == "]" then return s[1..-2]
        when s[0,1] == '"' && s[-1,1] == '"' then return s[1..-2]
        else return s
        end
      end
    
      def object_type_codes(type)
        case type
        when StoredProcedure then %w{P PC}
        when View then ['V']
        when Function then %w{AF FN FS FT IF TF}
        end
      end
      
      def string_literal(s)
        "N'#{s.gsub("'","''")}'"
      end
    end
  end
  
  class VersionControlError < XMigra::Error; end
  
  module SubversionSpecifics
    PRODUCTION_PATH_PROPERTY = 'xmigra:production-path'
    
    class << self
      def manages(path)
        begin
          return true if File.directory?(File.join(path, '.svn'))
        rescue TypeError
          return false
        end
        
        `svn info "#{path}" 2>&1`
        return $?.success?
      end
      
      # Run the svn command line client in XML mode and return a REXML::Document
      def run_svn(subcmd, *args)
        options = (Hash === args[-1]) ? args.pop : {}
        no_result = !options.fetch(:get_result, true)
        raw_result = options.fetch(:raw, false)
        
        cmd_parts = ["svn", subcmd.to_s]
        cmd_parts << "--xml" unless no_result || raw_result
        cmd_parts.concat(
          args.collect {|a| '""'.insert(1, a)}
        )
        cmd_str = cmd_parts.join(' ')
        
        output = `#{cmd_str}`
        raise(VersionControlError, "Subversion command failed with exit code #{$?.exitstatus}") unless $?.success?
        return output if raw_result && !no_result
        return REXML::Document.new(output) unless no_result
      end
    end
    
    def subversion(*args)
      SubversionSpecifics.run_svn(*args)
    end
    
    def check_working_copy!
      return unless production
      
      schema_info = subversion_info
      file_paths = Array.from_generator(method(:each_file_path))
      status = subversion(:status, '--no-ignore', path)
      unversioned_files = status.elements.each("status/target/entry/@path")
      unversioned_files = unversioned_files.collect {|a| File.expand_path(a.to_s)}
      
      unless (file_paths & unversioned_files).empty?
        raise VersionControlError, "Some source files are not versions found in the repository"
      end
      status = nil
      
      wc_rev = {}
      working_rev = schema_info.elements["info/entry/@revision"].value.to_i
      file_paths.each do |fp|
        fp_info = subversion(:info, fp)
        wc_rev[fp] = fp_wc_rev = fp_info.elements["info/entry/@revision"].value.to_i
        if working_rev != fp_wc_rev
          raise VersionControlError, "The working copy contains objects at multiple revisions"
        end
      end
      
      migrations.each do |m|
        fpath = m.file_path
        
        log = subversion(:log, "-r#{wc_rev[fpath]}:1", "--stop-on-copy", fpath)
        if log.elements["log/logentry[2]"]
          raise VersionControlError, "'#{fpath}' has been modified in the repository since it was created or copied"
        end
      end
      
      # Since a production script was requested, warn if we are not generating
      # from a production branch
      if branch_use != :production and self.respond_to? :warning
        self.warning(<<END_OF_MESSAGE)
The branch backing the target working copy is not marked as a production branch.
END_OF_MESSAGE
      end
    end
    
    def vcs_information
      info = subversion_info
      return [
        "Repository URL: #{info.elements["info/entry/url"].text}",
        "Revision: #{info.elements["info/entry/@revision"].value}"
      ].join("\n")
    end
    
    def get_conflict_info
      # Check if the structure head is conflicted
      structure_dir = Pathname.new(self.path) + SchemaManipulator::STRUCTURE_SUBDIR
      status = subversion(:status, structure_dir + MigrationChain::HEAD_FILE)
      return nil if status.elements["status/target/entry/wc-status/@item"].value != "conflicted"
      
      chain_head = lambda do |extension|
        pattern = MigrationChain::HEAD_FILE + extension
        if extension.include? '*'
          files = structure_dir.glob(MigrationChain::HEAD_FILE + extension)
          raise VersionControlError, "Multiple #{pattern} files in structure directory" if files.length > 1
          raise VersionControlError, "#{pattern} file missing from structure directory" if files.length < 1
        else
          files = [structure_dir.join(pattern)]
        end
        
        # Using YAML.parse_file and YAML::Syck::Node#transform rerenders
        # scalars in the same style they were read from the source file:
        return YAML.parse_file(files[0]).transform
      end
      
      if (structure_dir + (MigrationChain::HEAD_FILE + ".working")).exist?
        # This is a merge conflict
        
        # structure/head.yaml.working is from the current branch
        # structure/head.yaml.merge-left.r* is the branch point
        # structure/head.yaml.merge-right.r* is from the merged-in branch
        this_head = chain_head.call(".working")
        other_head = chain_head.call(".merge-right.r*")
        branch_point = chain_head.call(".merge-left.r*")[MigrationChain::LATEST_CHANGE]
        
        conflict = MigrationConflict.new(structure_dir, branch_point, [other_head, this_head])
        
        branch_use {|u| conflict.branch_use = u}
      else
        # This is an update conflict
        
        # structure/head.yaml.mine is from the working copy
        # structure/head.yaml.r<lower> is the common ancestor
        # structure/head.yaml.r<higher> is the newer revision
        working_head = chain_head.call('.mine')
        oldrev, newrev = nil, 0
        structure_dir.glob(MigrationChain::HEAD_FILE + '.r*') do |fn|
          if fn.to_s =~ /.r(\d+)$/
            rev = $1.to_i
            if oldrev.nil? or rev < oldrev
              oldrev = rev
            end
            if newrev < rev
              newrev = rev
            end
          end
        end
        repo_head = chain_head.call(".r#{newrev}")
        branch_point = chain_head.call(".r#{oldrev}")[MigrationChain::LATEST_CHANGE]
        
        conflict = MigrationConflict.new(structure_dir, branch_point, [repo_head, working_head])
        branch_use {|u| conflict.branch_use = u}
        
        fix_target, = conflict.migration_tweak
        fix_target_st = subversion(:status, fix_target)
        if fix_target_st.elements['status/target/entry/wc-status/@item'].value == 'modified'
          conflict.scope = :working_copy
        end
      end
      
      tool = self
      conflict.after_fix = proc {tool.resolve_conflict!(structure_dir + MigrationChain::HEAD_FILE)}
      
      return conflict
    end
    
    def branch_use
        # Look for xmigra:production-path on the database directory (self.path)
      return nil unless prod_path_element = subversion(:propget, PRODUCTION_PATH_PROPERTY, self.path).elements['properties/target/property']
      
      prod_path_pattern = Regexp.new(prod_path_element.text)
      
      use = prod_path_pattern.match(branch_identifier) ? :production : :development
      if block_given?
        yield use
      else
        return use
      end
    end
    
    def branch_identifier
      return @subversion_branch_id if defined? @subversion_branch_id
      dir_info = subversion_info
      return @subversion_branch_id = dir_info.elements['info/entry/url'].text[
        dir_info.elements['info/entry/repository/root'].text.length..-1
      ]
    end
    
    def production_pattern
      subversion(:propget, PRODUCTION_PATH_PROPERTY, self.path, :raw=>true)
    end
    def production_pattern=(pattern)
      subversion(:propset, PRODUCTION_PATH_PROPERTY, pattern, self.path, :get_result=>false)
    end
    
    def resolve_conflict!(path)
      subversion(:resolve, '--accept=working', path, :get_result=>false)
    end
    
    
    def vcs_move(old_path, new_path)
      subversion(:move, old_path, new_path, :get_result=>false)
    end
    
    def vcs_remove(path)
      subversion(:remove, path, :get_result=>false)
    end
    
    def subversion_info
      return @subversion_info if defined? @subversion_info
      return @subversion_info = subversion(:info, self.path)
    end
  end
  
  module GitSpecifics
    MASTER_HEAD_ATTRIBUTE = 'xmigra-master'
    MASTER_BRANCH_SUBDIR = 'xmigra-master'
    
    class << self
      def manages(path)
        run_git(:status, :check_exit=>true)
      end
      
      def run_git(subcmd, *args)
        options = (Hash === args[-1]) ? args.pop : {}
        check_exit = options.fetch(:check_exit, false)
        no_result = !options.fetch(:get_result, true)
        
        cmd_parts = ["git", subcmd.to_s]
        cmd_parts.concat(
          args.flatten.collect {|a| '""'.insert(1, a)}
        )
        cmd_str = cmd_parts.join(' ')
        
        output = `#{cmd_str}`
        return ($?.success? ? output : nil) if options[:get_result] == :on_success
        return $?.success? if check_exit
        raise(VersionControlError, "Git command failed with exit code #{$?.exitstatus}") unless $?.success?
        return output unless no_result
      end
      
      def attr_values(attr, path, options={})
        value_list = run_git('check-attr', attr, '--', path).each_line.map do |line|
          line.chomp.split(/: /, 3)[2]
        end
        return value_list unless options[:single]
        raise VersionControlError, options[:single] + ' ambiguous' if value_list.length > 1
        if (value_list.empty? || value_list == ['unspecified']) && options[:required]
          raise VersionControlError, options[:single] + ' undefined'
        end
        return value_list[0]
      end
    end
    
    def git(*args)
      Dir.chdir(self.path) do |pwd|
        GitSpecifics.run_git(*args)
      end
    end
    
    def check_working_copy!
      return unless production
      
      file_paths = Array.from_generator(method(:each_file_path))
      unversioned_files = git(
        'diff-index',
        %w{-z --no-commit-id --name-only HEAD},
        '--',
        self.path
      ).split("\000").collect do |path|
        File.expand_path(self.path + path)
      end
      
      # Check that file_paths and unversioned_files are disjoint
      unless (file_paths & unversioned_files).empty?
        raise VersionControlError, "Some source files differ from their committed versions"
      end
      
      migrations.each do |m|
        # Check that the migration has not changed in the currently checked-out branch
        fpath = m.file_path
        
        history = git(:log, %w{--format=%H --}, fpath).split
        if history[1]
          raise VersionControlError, "'#{fpath}' has been modified in the current branch of the repository since its introduction"
        end
      end
      
      # Since a production script was requested, warn if we are not generating
      # from a production branch
      if branch_use != :production and self.respond_to? :warning
        self.warning(<<END_OF_MESSAGE)
The branch backing the target working copy is not marked as a production branch.
END_OF_MESSAGE
      end
    end
    
    def vcs_information
      return [
        "Branch: #{branch_identifier}",
        "Path: #{git_internal_path}",
        "Commit: #{git_schema_commit}"
      ].join("\n")
    end
    
    def branch_identifier
      return self.git_branch_info[0]
    end
    
    def branch_use(commit=nil)
      if commit
        self.git_fetch_master_branch
        
        # If there are no commits between the master head and *commit*, then
        # *commit* is production-ish
        return (self.git_commits_in? self.git_master_local_branch..commit) ? :production : :development
      end
      
      return nil unless self.git_master_head(:required=>false)
      
      return self.git_branch_info[1]
    end
    
    def vcs_move(old_path, new_path)
      git(:mv, old_path, new_path, :get_result=>false)
    end
    
    def vcs_remove(path)
      git(:rm, path, :get_result=>false)
    end
    
    def production_pattern
      ".+"
    end
    
    def production_pattern=(pattern)
      raise VersionControlError, "Under version control by git, XMigra does not support production patterns."
    end
    
    def get_conflict_info
      structure_dir = Pathname.new(self.path) + SchemaManipulator::STRUCTURE_SUBDIR
      head_file = structure_dir + MigrationChain::HEAD_FILE
      stage_numbers = []
      git('ls-files', '-uz', '--', head_file).split("\000").each {|ref|
        if m = /[0-7]{6} [0-9a-f]{40} (\d)\t\S*/
          stage_numbers |= [m[1].to_i]
        end
      }
      return nil unless stage_numbers.sort == [1, 2, 3]
      
      chain_head = lambda do |stage_number|
        return YAML.parse(
          git(:show, ":#{stage_number}:#{head_file}")
        ).transform
      end
      
      # Ours (2) before theirs (3)...
      heads = [2, 3].collect(&chain_head)
      # ... unless merging from upstream
      if self.git_merging_from_upstream?
        heads.reverse!
      end
      
      branch_point = chain_head.call(1)[MigrationChain::LATEST_CHANGE]
      
      conflict = MigrationConflict.new(structure_dir, branch_point, heads)
      
      # Standard git usage never commits directly to the master branch, and
      # there is no effective way to tell if this is happening.
      conflict.branch_use = :development
      
      tool = self
      conflict.after_fix = proc {tool.resolve_conflict!(head_file)}
      
      return conflict
    end
    
    def resolve_conflict!(path)
      git(:add, '--', path, :get_result=>false)
    end
    
    def git_master_head(options={})
      options = {:required=>true}.merge(options)
      return @git_master_head if defined? @git_master_head
      master_head = GitSpecifics.attr_values(
        MASTER_HEAD_ATTRIBUTE,
        self.path,
        :single=>'Master branch',
        :required=>options[:required]
      )
      return nil if master_head.nil?
      return @git_master_head = master_head
    end
    
    def git_branch
      return git('rev-parse', %w{--abbrev-ref HEAD}).chomp
    end
    
    def git_schema_commit
      return @git_commit if defined? @git_commit
      reported_commit = git(:log, %w{-n1 --format=%H --}, self.path).chomp
      raise VersionControlError, "Schema not committed" if reported_commit.empty?
      return @git_commit = reported_commit
    end
    
    def git_branch_info
      return @git_branch_info if defined? @git_branch_info
      
      self.git_fetch_master_branch
      
      # If there are no commits between the master head and HEAD, this working
      # copy is production-ish
      return @git_branch_info = if self.branch_use('HEAD') == :production
        [self.git_master_head, :production]
      else
        host = `hostname`
        path = git('rev-parse', '--show-toplevel')
        ["#{git_branch} of #{path} on #{host} (commit #{git_schema_commit})", :development]
      end
    end
    
    def git_fetch_master_branch
      master_url, remote_branch = self.git_master_head.split('#', 2)
      
      git(:fetch, '-f', master_url, "#{remote_branch}:#{git_master_local_branch}", :get_result=>false)
    end
    
    def git_master_local_branch
      "#{MASTER_BRANCH_SUBDIR}/#{git_branch}"
    end
    
    def git_internal_path
      return @git_internal_path if defined? @git_internal_path
      path_prefix = git('rev-parse', %w{--show-prefix}).chomp[0..-2]
      internal_path = '.'
      if path_prefix.length > 0
        internal_path += '/' + path_prefix
      end
      return @git_internal_path = internal_path
    end
    
    def git_merging_from_upstream?
      upstream = git('rev-parse', '@{u}')
      return false if upstream.nil?
      
      # Check if there are any commits in #{upstream}..MERGE_HEAD
      begin
        return !(self.git_commits_in? upstream..'MERGE_HEAD')
      rescue VersionControlError
        return false
      end
    end
    
    def git_commits_in?(range)
      git(
        :log,
        '--pretty=format:%H',
        '-1',
        "#{range.begin}..#{range.end}",
        '--',
        self.path
      ) != ''
    end
  end

  class SchemaManipulator
    DBINFO_FILE = 'database.yaml'
    PERMISSIONS_FILE = 'permissions.yaml'
    ACCESS_SUBDIR = 'access'
    INDEXES_SUBDIR = 'indexes'
    STRUCTURE_SUBDIR = 'structure'
    VERINC_FILE = 'branch-upgrade.yaml'
    
    def initialize(path)
      @path = Pathname.new(path)
      @db_info = YAML.load_file(@path + DBINFO_FILE)
      raise TypeError, "Expected Hash in #{DBINFO_FILE}" unless Hash === @db_info
      @db_info = Hash.new do |h, k|
        raise Error, "#{DBINFO_FILE} missing key #{k.inspect}"
      end.update(@db_info)
      
      extend(@db_specifics = case @db_info['system']
      when 'Microsoft SQL Server' then MSSQLSpecifics
      else NoSpecifics
      end)
      
      extend(@vcs_specifics = [
        SubversionSpecifics,
        GitSpecifics,
      ].find {|s| s.manages(path)} || NoSpecifics)
    end
    
    attr_reader :path
    
    def branch_upgrade_file
      @path.join(STRUCTURE_SUBDIR, VERINC_FILE)
    end
  end

  class SchemaUpdater < SchemaManipulator
    DEV_SCRIPT_WARNING = <<-"END_OF_TEXT"
*********************************************************
***                    WARNING                        ***
*********************************************************

THIS SCRIPT IS FOR USE ONLY ON DEVELOPMENT DATABASES.

IF RUN ON AN EMPTY DATABASE IT WILL CREATE A DEVELOPMENT
DATABASE THAT IS NOT GUARANTEED TO FOLLOW ANY COMMITTED
MIGRATION PATH.

RUNNING THIS SCRIPT ON A PRODUCTION DATABASE WILL FAIL.
        END_OF_TEXT
    
    def initialize(path)
      super(path)
      
      @file_based_groups = []
      
      begin
        @file_based_groups << (@access_artifacts = AccessArtifactCollection.new(
          @path.join(ACCESS_SUBDIR),
          :db_specifics=>@db_specifics,
          :filename_metavariable=>@db_info.fetch('filename metavariable', nil)
        ))
        @file_based_groups << (@indexes = IndexCollection.new(
          @path.join(INDEXES_SUBDIR),
          :db_specifics=>@db_specifics
        ))
        @file_based_groups << (@migrations = MigrationChain.new(
          @path.join(STRUCTURE_SUBDIR),
          :db_specifics=>@db_specifics
        ))
        
        @branch_upgrade = BranchUpgrade.new(branch_upgrade_file)
        @file_based_groups << [@branch_upgrade] if @branch_upgrade.found?
      rescue Error
        raise
      rescue StandardError
        raise Error, "Error initializing #{self.class} components"
      end
      
      @production = false
    end
    
    attr_accessor :production
    attr_reader :migrations, :access_artifacts, :indexes, :branch_upgrade
    
    def inspect
      "<#{self.class.name}: path=#{path.to_s.inspect}, db=#{@db_specifics}, vcs=#{@vcs_specifics}>"
    end
    
    def in_ddl_transaction
      yield
    end
    
    def ddl_block_separator; "\n"; end
    
    def update_sql
      raise XMigra::Error, "Incomplete migration chain" unless @migrations.complete?
      raise XMigra::Error, "Unchained migrations exist" unless @migrations.includes_all?
      if respond_to? :warning
        @branch_upgrade.warnings.each {|w| warning(w)}
        if @branch_upgrade.found? && !@branch_upgrade.applicable?(@migrations)
          warning("#{branch_upgrade.file_path} does not apply to the current migration chain.")
        end
      end
      
      check_working_copy!
      
      intro_comment = @db_info.fetch('script comment', '')
      intro_comment << if production
        sql_comment_block(vcs_information || "")
      else
        sql_comment_block(DEV_SCRIPT_WARNING)
      end
      intro_comment << "\n\n"
      
      # If supported, wrap transactionality around modifications
      intro_comment + in_ddl_transaction do
        script_parts = [
          # Check for blatantly incorrect application of script, e.g. running
          # on master or template database.
          :check_execution_environment_sql,
          
          # Create schema version control (SVC) tables if they don't exist
          :ensure_version_tables_sql,
          
          # Create and fill a temporary table with migration IDs known by
          # the script with order information
          :create_and_fill_migration_table_sql,
          
          # Create and fill a temporary table with index information known by
          # the script
          :create_and_fill_indexes_table_sql,
          
          # Check that all migrations applied to the database are known to
          # the script (as far back as the most recent "version bridge" record)
          :check_preceding_migrations_sql,
          
          # Check that there are no "gaps" in the chain of migrations
          # that have already been applied
          :check_chain_continuity_sql,
          
          # Mark migrations in the temporary table that should be installed
          :select_for_install_sql,
          
          # Check production configuration of database
          :production_config_check_sql,
          
          # Remove all access artifacts
          :remove_access_artifacts_sql,
          
          # Remove all undesired indexes
          :remove_undesired_indexes_sql,
          
          # Apply a branch upgrade if indicated
          :branch_upgrade_sql,
          
          # Apply selected migrations
          :apply_migration_sql,
          
          # Create all access artifacts
          :create_access_artifacts_sql,
          
          # Create any desired indexes that don't yet exist
          :create_new_indexes_sql,
          
          # Any cleanup needed
          :upgrade_cleanup_sql,
        ]
        
        amend_script_parts(script_parts)
        
        script_parts.map {|mn| self.send(mn)}.flatten.compact.join(ddl_block_separator)
      end
    end
    
    def amend_script_parts(parts)
    end
    
    def sql_comment_block(text)
      text.lines.collect {|l| '-- ' + l.chomp + "\n"}.join('')
    end
    
    def check_working_copy!
      raise VersionControlError, "XMigra source not under version control" if production
    end
    
    def create_access_artifacts_sql
      scripts = []
      @access_artifacts.each_definition_sql {|s| scripts << s}
      return scripts unless scripts.empty?
    end
    
    def apply_migration_sql
      # Apply selected migrations
      @migrations.collect do |m|
        m.migration_application_sql
      end
    end
    
    def branch_upgrade_sql
    end
    
    def upgrade_cleanup_sql
    end
    
    def vcs_information
    end
    
    def each_file_path
      @file_based_groups.each do |group|
        group.each {|item| yield item.file_path}
      end
    end
  end
  
  class NewMigrationAdder < SchemaManipulator
    OBSOLETE_VERINC_FILE = 'version-upgrade-obsolete.yaml'
    
    def initialize(path)
      super(path)
    end
    
    def add_migration(summary, options={})
      struct_dir = @path.join(STRUCTURE_SUBDIR)
      FileUtils.mkdir_p(struct_dir) unless struct_dir.exist?
      
      # Load the head YAML from the structure subdir if it exists or create
      # default empty migration chain
      head_file = struct_dir.join(MigrationChain::HEAD_FILE)
      head_info = if head_file.exist?
        YAML.parse_file(head_file).transform
      else
        {}
      end
      Hash === head_info or raise XMigra::Error, "Invalid #{MigrationChain::HEAD_FILE} format"
      
      new_fpath = struct_dir.join(
        [Date.today.strftime("%Y-%m-%d"), summary].join(' ') + '.yaml'
      )
      raise(XMigra::Error, "Migration file\"#{new_fpath.basename}\" already exists") if new_fpath.exist?
      
      new_data = {
        Migration::FOLLOWS=>head_info.fetch(MigrationChain::LATEST_CHANGE, Migration::EMPTY_DB),
        'sql'=>options.fetch(:sql, "<<<<< INSERT SQL HERE >>>>>\n"),
        'description'=>options.fetch(:description, "<<<<< DESCRIPTION OF MIGRATION >>>>>").dup.extend(FoldedYamlStyle),
        Migration::CHANGES=>options.fetch(:changes, ["<<<<< WHAT THIS MIGRATION CHANGES >>>>>"]),
      }
      
      # Write the head file first, in case a lock is required
      old_head_info = head_info.dup
      head_info[MigrationChain::LATEST_CHANGE] = new_fpath.basename('.yaml').to_s
      File.open(head_file, "w") do |f|
        YAML.dump(head_info, f)
      end
      
      begin
        File.open(new_fpath, "w") do |f|
          YAML.dump(new_data, f)
        end
      rescue
        # Revert the head file to it's previous state
        File.open(head_file, "w") do |f|
          YAML.dump(old_head_info, f)
        end
        
        raise
      end
      
      # Obsolete any existing branch upgrade file
      bufp = branch_upgrade_file
      if bufp.exist?
        warning("#{bufp.relative_path_from(@path)} is obsolete and will be renamed.") if respond_to? :warning
        
        obufp = bufp.dirname.join(OBSOLETE_VERINC_FILE)
        rm_method = respond_to?(:vcs_remove) ? method(:vcs_remove) : FileUtils.method(:rm)
        mv_method = respond_to?(:vcs_move) ? method(:vcs_move) : FileUtils.method(:mv)
        
        rm_method.call(obufp) if obufp.exist?
        mv_method.call(bufp, obufp)
      end
      
      return new_fpath
    end
  end
  
  class PermissionScriptWriter < SchemaManipulator
    def initialize(path)
      super(path)
      
      @permissions = YAML.load_file(self.path + PERMISSIONS_FILE)
      raise TypeError, "Expected Hash in #{PERMISSIONS_FILE}" unless Hash === @permissions
    end
    
    def in_ddl_transaction
      yield
    end
    
    def ddl_block_separator; "\n"; end
    
    def permissions_sql
      intro_comment = @db_info.fetch('script comment', '') + "\n\n"
      
      intro_comment + in_ddl_transaction do
        [
          # Check for blatantly incorrect application of script, e.g. running
          # on master or template database.
          check_execution_environment_sql,
          
          # Create table for recording granted permissions if it doesn't exist
          ensure_permissions_table_sql,
          
          # Revoke permissions previously granted through an XMigra permissions
          # script
          revoke_previous_permissions_sql,
          
          # Grant the permissions indicated in the source file
          grant_specified_permissions_sql,
          
        ].flatten.compact.join(ddl_block_separator)
      end
    end
    
    def grant_specified_permissions_sql
      granting_permissions_comment_sql +
        enum_for(:each_specified_grant).map(&method(:grant_permissions_sql)).join("\n")
    end
    
    def each_specified_grant
      @permissions.each_pair do |object, grants|
        grants.each_pair do |principal, permissions|
          permissions = [permissions] unless permissions.is_a? Enumerable
          yield permissions, object, principal
        end
      end
    end
    
    def line_comment(contents)
      "-- " + contents + " --\n"
    end
    
    def header(content, size)
      dashes = size - content.length - 2
      l_dashes = dashes / 2
      r_dashes = dashes - l_dashes
      ('-' * l_dashes) + ' ' + content + ' ' + ('-' * r_dashes)
    end
  end
  
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
  end
  
  class Program
    ILLEGAL_PATH_CHARS = "\"<>:|"
    ILLEGAL_FILENAME_CHARS = ILLEGAL_PATH_CHARS + "/\\"
    
    class TerminatingOption < Exception; end
    class ArgumentError < XMigra::Error; end
    module QuietError; end
    
    class << self
      def subcommand(name, description, &block)
        (@subcommands ||= {})[name] = block
        (@subcommand_descriptions ||= {})[name] = description
      end
      
      # Run the given command line.
      # 
      # An array of command line arguments may be given as the only argument
      # or arguments may be given as call parameters.  Returns nil if the
      # command completed or a TerminatingOption object if a terminating
      # option (typically "--help") was passed.
      def run(*argv)
        options = (Hash === argv.last) ? argv.pop : {}
        argv = argv[0] if argv.length == 1 && Array === argv[0]
        prev_subcommand = @active_subcommand
        begin
          @active_subcommand = subcmd = argv.shift
          
          begin
            if subcmd == "help" || subcmd.nil?
              help(argv)
              return
            end
            
            begin
              (@subcommands[subcmd] || method(:show_subcommands_as_help)).call(argv)
            rescue StandardError => error
              raise unless options[:error]
              options[:error].call(error)
            end
          rescue TerminatingOption => stop
            return stop
          end
        ensure
          @active_subcommand = prev_subcommand
        end
      end
      
      def help(argv)
        if (argv.length != 1) || (argv[0] == '--help')
          show_subcommands
          return
        end
        
        argv << "--help"
        run(argv)
      end
      
      def show_subcommands(_1=nil)
        puts
        puts "Use '#{File.basename($0)} help <subcommand>' for help on one of these subcommands:"
        puts
        
        descs = @subcommand_descriptions
        cmd_width = descs.enum_for(:each_key).max_by {|i| i.length}.length + 2
        descs.each_pair do |cmd, description|
          printf("%*s - ", cmd_width, cmd)
          description.lines.each_with_index do |line, i|
            indent = if (i > 0)..(i == description.lines.count - 1)
              cmd_width + 3
            else
              0
            end
            puts(" " * indent + line.chomp)
          end
        end
      end
      
      def show_subcommands_as_help(_1=nil)
        show_subcommands
        raise ArgumentError.new("Invalid subcommand").extend(QuietError)
      end
      
      def command_line(argv, use, cmdopts = {})
        options = OpenStruct.new
        argument_desc = cmdopts[:argument_desc]
        
        optparser = OptionParser.new do |flags|
          subcmd = @active_subcommand || "<subcmd>"
          flags.banner = [
            "Usage: #{File.basename($0)} #{subcmd} [<options>]",
            argument_desc
          ].compact.join(' ')
          flags.banner << "\n\n" + cmdopts[:help].chomp if cmdopts[:help]
          
          flags.separator ''
          flags.separator 'Subcommand options:'
          
          if use[:target_type]
            options.target_type = :unspecified
            allowed = [:exact, :substring, :regexp]
            flags.on(
              "--by=TYPE", allowed,
              "Specify how TARGETs are matched",
              "against subject strings",
              "(#{allowed.collect {|i| i.to_s}.join(', ')})"
            ) do |type|
              options.target_type = type
            end
          end
          
          if use[:dev_branch]
            options.dev_branch = false
            flags.on("--dev-branch", "Favor development branch usage assumption") do
              options.dev_branch = true
            end
          end
          
          unless use[:edit].nil?
            options.edit = use[:edit] ? true : false
            flags.banner << "\n\n" << (<<END_OF_HELP).chomp
When opening an editor, the program specified by the environment variable
VISUAL is preferred, then the one specified by EDITOR.  If neither of these
environment variables is set no editor will be opened.
END_OF_HELP
            flags.on("--[no-]edit", "Open the resulting file in an editor",
                     "(defaults to #{options.edit})") do |v|
              options.edit = %w{EDITOR VISUAL}.any? {|k| ENV.has_key?(k)} && v
            end
          end
          
          if use[:search_type]
            options.search_type = :changes
            allowed = [:changes, :sql]
            flags.on(
              "--match=SUBJECT", allowed,
              "Specify the type of subject against",
              "which TARGETs match",
              "(#{allowed.collect {|i| i.to_s}.join(', ')})"
            ) do |type|
              options.search_type = type
            end
          end
          
          if use[:outfile]
            options.outfile = nil
            flags.on("-o", "--outfile=FILE", "Output to FILE") do |fpath|
              options.outfile = File.expand_path(fpath)
            end
          end
          
          if use[:production]
            options.production = false
            flags.on("-p", "--production", "Generate script for production databases") do 
              options.production = true
            end
          end
          
          options.source_dir = Dir.pwd
          flags.on("--source=DIR", "Work from/on the schema in DIR") do |dir|
            options.source_dir = File.expand_path(dir)
          end
          
          flags.on_tail("-h", "--help", "Show this message") do
            puts
            puts flags
            raise TerminatingOption.new('--help')
          end
        end
        
        argv = optparser.parse(argv)
        
        if use[:target_type] && options.target_type == :unspecified
          options.target_type = case options.search_type
          when :changes then :strict
          else :substring
          end
        end
        
        return argv, options
      end
      
      def output_to(fpath_or_nil)
        if fpath_or_nil.nil?
          yield(STDOUT)
        else
          File.open(fpath_or_nil, "w") do |stream|
            yield(stream)
          end
        end
      end
      
      def argument_error_unless(test, message)
        return if test
        raise ArgumentError, XMigra.program_message(message, :cmd=>@active_subcommand)
      end
      
      def edit(fpath)
        case
        when (editor = ENV['VISUAL']) && PLATFORM == :mswin
          system(%Q{start #{editor} "#{fpath}"})
        when editor = ENV['VISUAL']
          system(%Q{#{editor} "#{fpath}" &})
        when editor = ENV['EDITOR']
          system(%Q{#{editor} "#{fpath}"})
        end
      end
    end
    
    subcommand 'overview', "Explain usage of this tool" do |argv|
      argument_error_unless([[], ["-h"], ["--help"]].include?(argv),
                            "'%prog %cmd' does not accept arguments.")
      
      formalizations = {
        /xmigra/i=>'XMigra',
      }
      
      section = proc do |name, content|
        puts
        puts name
        puts "=" * name.length
        puts XMigra.program_message(
          content,
          :prog=>/%program_cmd\b/
        )
      end
      
      puts XMigra.program_message(<<END_HEADER) # Overview

===========================================================================
# Usage of %program_name
===========================================================================
END_HEADER
      
      begin; section['Introduction', <<END_SECTION]

%program_name is a tool designed to assist development of software using
relational databases for persistent storage.  During the development cycle, this
tool helps manage:

  - Migration of production databases to newer versions, including migration
    between parallel, released versions.
  
  - Using transactional scripts, so that unexpected database conditions do not
    lead to corrupt production databases.
  
  - Protection of production databases from changes still under development.
  
  - Parallel development of features requiring database changes.
  
  - Assignment of permissions to database objects.

To accomplish this, the database schema to be created is decomposed into
several parts and formatted in text files according to certain rules.  The
%program_name tool is then used to manipulate, query, or generate scripts from
the set of files.
END_SECTION
      end
      begin; section['Schema Files and Folders', <<END_SECTION]

    SCHEMA (root folder/directory of decomposed schema)
    +-- database.yaml
    +-- permissions.yaml (optional)
    +-- structure
    |   +-- head.yaml
    |   +-- <migration files>
    |   ...
    +-- access
    |   +-- <stored procedure definition files>
    |   +-- <view definition files>
    |   +-- <user defined function definition files>
    |   ...
    +-- indexes
        +-- <index definition files>
        ...

  --------------------------------------------------------------------------
  NOTE: In case-sensitive filesystems, all file and directory names dictated
  by %program_name are lowercase.
  --------------------------------------------------------------------------

All data files used by %program_name conform to the YAML 1.0 data format
specification.  Please refer to that specification for information
on the specifics of encoding particular values.  This documentation, at many
points, makes reference to "sections" of a .yaml file; such a section is,
technically, an entry in the mapping at the top level of the .yaml file with
the given key.  The simplest understanding of this is that the section name
followed immediately (no whitespace) by a colon (':') and at least one space
character appears in the left-most column, and the section contents appear
either on the line after the colon-space or in an indented block starting on
the next line (often used with a scalar block indicator ('|' or '>') following
the colon-space).

The decomposed database schema lives within a filesystem subtree rooted at a
single folder (i.e. directory).  For examples in this documentation, that
folder will be called SCHEMA.  Two important files are stored directly in the
SCHEMA directory: database.yaml and permissions.yaml.  The "database.yaml" file
provides general information about the database for which scripts are to be
generated.  Please see the section below detailing this file's contents for
more information.  The "permissions.yaml" file specifies permissions to be
granted when generating a permission-granting script (run
'%program_cmd help permissions' for more information).

Within the SCHEMA folder, %program_name expects three other folders: structure,
access, and indexes.
END_SECTION
      end
      begin; section['The "SCHEMA/structure" Folder', <<END_SECTION]

Every relational database has structures in which it stores the persistent
data of the related application(s).  These database objects are special in
relation to other parts of the database because they contain information that
cannot be reproduced just from the schema definition.  Yet bug fixes and
feature additions will need to update this structure and good programming
practice dictates that such changes, and the functionalities relying on them,
need to be tested.  Testability, in turn, dictates a repeatable sequence of
actions to be executed on the database starting from a known state.

%program_name models the evolution of the persistent data storage structures
of a database as a chain of "migrations," each of which makes changes to the
database storage structure from a previous, known state of the database.  The
first migration starts at an empty database and each subsequent migration
starts where the previous migration left off.  Each migration is stored in
a file within the SCHEMA/structure folder.  The names of migration files start
with a date (YYYY-MM-DD) and include a short description of the change.  As
with other files used by the %program_name tool, migration files are in the
YAML format, using the ".yaml" extension.  Because some set of migrations
will determine the state of production databases, migrations themselves (as
used to produce production upgrade scripts) must be "set in stone" -- once
committed to version control (on a production branch) they must never change
their content.

Migration files are usually generated by running the '%program_cmd new'
command (see '%program_cmd help new' for more information) and then editing
the resulting file.  The migration file has several sections: "starting from",
"sql", "changes", and "description".  The "starting from" section indicates the
previous migration in the chain (or "empty database" for the first migration).
SQL code that effects the migration on the database is the content of the "sql"
section (usually given as a YAML literal block).  The "changes" section
supports '%program_cmd history', allowing a more user-friendly look at the
evolution of a subset of the database structure over the migration chain.
Finally, the "description" section is intended for a prose description of the
migration, and is included in the upgrade metadata stored in the database.  Use
of the '%program_cmd new' command is recommended; it handles several tiresome
and error-prone tasks: creating a new migration file with a conformant name,
setting the "starting from" section to the correct value, and updating
SCHEMA/structure/head.yaml to reference the newly generated file.

The SCHEMA/structure/head.yaml file deserves special note: it contains a
reference to the last migration to be applied.  Because of this, parallel
development of database changes will cause conflicts in the contents of this
file.  This is by design, and '%program_cmd unbranch' will assist in resolving
these conflicts.

Care must be taken when committing migration files to version control; because
the structure of production databases will be determined by the chain of
migrations (starting at an empty database, going up to some certain point),
it is imperative that migrations used to build these production upgrade scripts
not be modified once committed to the version control system.  When building
a production upgrade script, %program_name verifies that this constraint is
followed.  Therefore, if the need arises to commit a migration file that may
require amendment, the best practice is to commit it to a development branch.

Migrating a database from one released version (which may receive bug fixes
or critical feature updates) to another released version which developed along
a parallel track is generally a tricky endeavor.  Please see the section on
"branch upgrades" below for information on how %program_name supports this
use case.
END_SECTION
      end
      begin; section['The "SCHEMA/access" Folder', <<END_SECTION]

In addition to the structures that store persistent data, many relational
databases also support persistent constructs for providing consistent access
(creation, retrieval, update, and deletion) to the persistent data even as the
actual storage structure changes, allowing for a degree of backward
compatibility with applications.  These constructs do not, of themselves,
contain persistent data, but rather specify procedures for accessing the
persistent data.

In %program_name, such constructs are defined in the SCHEMA/access folder, with
each construct (usually) having its own file.  The name of the file must be
a valid SQL name for the construct defined.  The filename may be accessed
within the definition by the filename metavariable, by default "[{filename}]"
(without quotation marks); this assists renaming such constructs, making the
operation of renaming the construct a simple rename of the containing file
within the filesystem (and version control repository).  Use of files in this
way creates a history of each "access object's" definition in the version
control system organized by the name of the object.

The definition of the access object is given in the "sql" section of the
definition file, usually with a YAML literal block.  This SQL MUST define the
object for which the containing file is named; failure to do so will result in
failure of the script when it is run against the database.  After deleting
all access objects previously created by %program_name, the generated script
first checks that the access object does not exist, then runs the definition
SQL, and finally checks that the object now exists.

In addition to the SQL definition, %program_name needs to know what kind of
object is to be created by this definition.  This information is presented in
the "define" section, and is currently limited to "function",
"stored procedure", and "view".

Some database management systems enforce a rule that statements defining access
objects (or at least, some kinds of access objects) may not reference access
objects that do not yet exist.  (A good example is Microsoft SQL Server's rule
about user defined functions that means a definition for the function A may
only call the user defined function B if B exists when A is defined.)  To
accommodate this situation, %program_name provides an optional "referencing"
section in the access object definition file.  The content of this section
must be a YAML sequence of scalars, each of which is the name of an access
object file (the name must be given the same way the filename is written, not
just a way that is equivalent in the target SQL language).  The scalar values
must be appropriately escaped as necessary (e.g. Microsoft SQL Server uses
square brackets as a quotation mechanism, and square brackets have special
meaning in YAML, so it is necessary use quoted strings or a scalar block to
contain them).  Any access objects listed in this way will be created before
the referencing object.
END_SECTION
      end
      begin; section['The "SCHEMA/indexes" Folder', <<END_SECTION]

Database indexes vary from the other kinds of definitions supported by
%program_name: while SCHEMA/structure elements only hold data and
SCHEMA/access elements are defined entirely by their code in the schema and
can thus be efficiently re-created, indexes have their whole definition in
the schema, but store data gleaned from the persistent data.  Re-creation of
an index is an expensive operation that should be avoided when unnecessary.

To accomplish this end, %program_name looks in the SCHEMA/indexes folder for
index definitions.  The generated scripts will drop and (re-)create only
indexes whose definitions are changed.  %program_name uses a very literal
comparison of the SQL text used to create the index to determine "change;"
even so much as a single whitespace added or removed, even if insignificant to
the database management system, will be enough to cause the index to be dropped
and re-created.

Index definition files use only the "sql" section to provide the SQL definition
of the index.  Index definitions do not support use of the filename
metavariable because renaming an index would cause it to be dropped and
re-created.
END_SECTION
      end
      begin; section['The "SCHEMA/database.yaml" File', <<END_SECTION]

The SCHEMA/database.yaml file consists of several sections that provide general
information about the database schema.  The following subsection detail some
contents that may be included in this file.

system
------

The "system" section specifies for %program_name which database management
system shall be targeted for the generation of scripts.  Currently the
supported values are:

  - Microsoft SQL Server

Each system can also have sub-settings that modify the generated scripts.

  Microsoft SQL Server:
    The "MSSQL 2005 compatible" setting in SCEMA/database.yaml, if set to
    "true", causes INSERT statements to be generated in a more verbose and
    SQL Server 2005 compatible manner.

Also, each system may modify in other ways the behavior of the generator or
the interpretation of the definition files:

  Microsoft SQL Server:
    The SQL in the definition files may use the "GO" metacommand also found in
    Microsoft SQL Server Management Studio and sqlcmd.exe.  This metacommand
    must be on a line by itself where used.  It should produce the same results
    as it would in MSSMS or sqlcmd.exe, except that the overall script is
    transacted.

script comment
--------------

The "script comment" section defines a body of SQL to be inserted at the top
of all generated scripts.  This is useful for including copyright information
in the resulting SQL.

filename metavariable
---------------------

The "filename metavariable" section allows the schema to override the filename
metavariable that is used for access object definitions.  The default value
is "[{filename}]" (excluding the quotation marks).  If that string is required
in one or more access object definitions, this section allows the schema to
dictate another value.
END_SECTION
      end
      begin; section['Script Generation Modes', <<END_SECTION]

%program_name supports two modes of upgrade script creation: development and
production.  (Permission script generation is not constrained to these modes.)
Upgrade script generation defaults to development mode, which does less
work to generate a script and skips tests intended to ensure that the script
could be generated again at some future point from the contents of the version
control repository.  The resulting script can only be run on an empty database
or a database that was set up with a development mode script earlier on the
same migration chain; running a development mode script on a database created
with a production script fails by design (preventing a production database from
undergoing a migration that has not been duly recorded in the version control
system).  Development scripts have a big warning comment at the beginning of
the script as a reminder that they are not suitable to use on a production
system.

Use of the '--production' flag with the '%program_cmd upgrade' command
enables production mode, which carries out a significant number of
additional checks.  These checks serve two purposes: making sure that all
migrations to be applied to a production database are recorded in the version
control system and that all of the definition files in the whole schema
represent a single, coherent point in the version history (i.e. all files are
from the same revision).  Where a case arises that a script needs to be
generated that cannot meet these two criteria, it is almost certainly a case
that calls for a development script.  There is always the option of creating
a new production branch and committing the %program_name schema files to that
branch if a production script is needed, thus meeting the criteria of the test.

Note that "development mode" and "production mode" are not about the quality
of the scripts generated or the "build mode" of the application that may access
the resulting database, but rather about the designation of the database
to which the generated scripts may be applied.  "Production" scripts certainly
should be tested in a non-production environment before they are applied to
a production environment with irreplaceable data.  But "development" scripts,
by design, can never be run on production systems (so that the production
systems only move from one well-documented state to another).
END_SECTION
      end
      begin; section['Branch Upgrades', <<END_SECTION]

Maintaining a single, canonical chain of database schema migrations released to
customers dramatically reduces the amount of complexity inherent in
same-version product upgrades.  But expecting development and releases to stay
on a single migration chain is overly optimistic; there are many circumstances
that lead to divergent migration chains across instances of the database.  A
bug fix on an already released version or some emergency feature addition for
an enormous profit opportunity are entirely possible, and any database
evolution system that breaks under those requirements will be an intolerable
hinderance.

%program_name supports these situations through the mechanism of "branch
upgrades."  A branch upgrade is a migration containing SQL commands to effect
the conversion of the head of the current branch's migration chain (i.e. the
state of the database after the most recent migration in the current branch)
into some state along another branch's migration chain.  These commands are not
applied when the upgrade script for this branch is run.  Rather, they are saved
in the database and run only if, and then prior to, an upgrade script for the
targeted branch is run against the same database.

Unlike regular migrations, changes to the branch upgrade migration MAY be
committed to the version control repository.

::::::::::::::::::::::::::::::::::: EXAMPLE :::::::::::::::::::::::::::::::::::
::                                                                           ::

Product X is about to release version 2.0.  Version 1.4 of Product X has
been in customers' hands for 18 months and seven bug fixes involving database
structure changes have been implemented in that time.  Our example company has
worked out the necessary SQL commands to convert the current head of the 1.4
migration chain to the same resulting structure as the head of the 2.0
migration chain.  Those SQL commands, and the appropriate metadata about the
target branch (version 2.0), the completed migration (the one named as the head
of the 2.0 branch), and the head of the 1.4 branch are all put into the
SCHEMA/structure/branch-upgrade.yaml file as detailed below.  %program_name
can then script the storage of these commands into the database for execution
by a Product X version 2.0 upgrade script.

Once the branch-upgrade.yaml file is created and committed to version control
in the version 1.4 branch, two upgrade scripts need to be generated: a
version 1.4 upgrade script and a version 2.0 upgrade script, each from its
respective branch in version control.  For each version 1.4 installation, the
1.4 script will first be run, bringing the installation up to the head of
version 1.4 and installing the instructions for upgrading to a version 2.0
database.  Then the version 2.0 script will be run, which will execute the
stored instructions for bringing the database from version 1.4 to version 2.0.

Had the branch upgrade not brought the version 1.4 database all the way up to
the head of version 2.0 (i.e. if the YAML file indicates a completed migration
prior to the version 2.0 head), the version 2.0 script would then apply any
following migrations in order to bring the database up to the version 2.0 head.

::                                                                           ::
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

In addition to the "sql" section, which has the same function as the "sql"
section of a regular migration, the SCHEMA/structure/branch-upgrade.yaml file
has three other required sections.

starting from
-------------

As with regular migrations, the branch-upgrade.yaml specifies a "starting from"
point, which should always be the head migration of the current branch (see
SCHEMA/structure/head.yaml).  If this section does not match with the latest
migration in the migration chain, no branch upgrade information will be
included in the resulting upgrade script and a warning will be issued during
script generation.  This precaution prevents out-of-date branch upgrade
commands from being run.

resulting branch
----------------

The "resulting branch" section must give the identifier of the branch
containing the migration chain into which the included SQL commands will
migrate the current chain head.  This identifier can be obtained with the
'%program_cmd branchid' command run against a working copy of the
target branch.

completes migration to
----------------------

Because the migration chain of the target branch is likely to be extended over
time, it is necessary to pin down the intended result state of the branch
upgrade to one particular migration in the target chain.  The migration name
listed in the "completes migration to" section should be the name of the
migration (the file basename) which brings the target branch database to the
same state as the head state of the current branch  after applying the
branch upgrade commands.
END_SECTION
      end
      puts
    end
    
    subcommand 'new', "Create a new migration file" do |argv|
      args, options = command_line(argv, {:edit=>true},
                                   :argument_desc=>"MIGRATION_SUMMARY",
                                   :help=> <<END_OF_HELP)
This command generates a new migration file and ties it into the current
migration chain.  The name of the new file is generated from today's date and
the given MIGRATION_SUMMARY.  The resulting new file may be opened in an
editor (see the --[no-]edit option).
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      migration_summary = args[0]
      argument_error_unless(
        migration_summary.chars.all? {|c| !ILLEGAL_FILENAME_CHARS.include?(c)},
        "Migration summary may not contain any of: " + ILLEGAL_FILENAME_CHARS
      )
      
      tool = NewMigrationAdder.new(options.source_dir).extend(WarnToStderr)
      new_fpath = tool.add_migration(migration_summary)
      
      edit(new_fpath) if options.edit
    end
    
    subcommand 'upgrade', "Generate an upgrade script" do |argv|
      args, options = command_line(argv, {:production=>true, :outfile=>true},
                                   :help=> <<END_OF_HELP)
Running this command will generate an update script from the source schema.
Generation of a production script involves more checks on the status of the
schema source files but produces a script that may be run on a development,
production, or empty database.  If the generated script is not specified for
production it may only be run on a development or empty database; it will not
run on production databases.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      sql_gen = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      sql_gen.production = options.production
      
      output_to(options.outfile) do |out_stream|
        out_stream.print(sql_gen.update_sql)
      end
    end
    
    subcommand 'render', "Generate SQL script for an access object" do |argv|
      args, options = command_line(argv, {:outfile=>true},
                                   :argument_desc=>"ACCESS_OBJECT_FILE",
                                   :help=> <<END_OF_HELP)
This command outputs the creation script for the access object defined in the
file at path ACCESS_OBJECT_FILE, making any substitutions in the same way as
the update script generator.
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      argument_error_unless(File.exist?(args[0]),
                            "'%prog %cmd' must target an existing access object definition.")
      
      sql_gen = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      
      artifact = sql_gen.access_artifacts[args[0]] || sql_gen.access_artifacts.at_path(args[0])
      output_to(options.outfile) do |out_stream|
        out_stream.print(artifact.creation_sql)
      end
    end
    
    subcommand 'unbranch', "Fix a branched migration chain" do |argv|
      args, options = command_line(argv, {:dev_branch=>true},
                                   :help=> <<END_OF_HELP)
Use this command to fix a branched migration chain.  The need for this command
usually arises when code is pulled from the repository into the working copy.

Because this program checks that migration files are unaltered when building
a production upgrade script it is important to use this command only:

  A) after updating in any branch, or

  B) after merging into (including synching) a development branch

If used in case B, the resulting changes may make the migration chain in the
current branch ineligible for generating production upgrade scripts.  When the
development branch is (cleanly) merged back to the production branch it will
still be possible to generate a production upgrade script from the production
branch.  In case B the resulting script (generated in development mode) should
be thoroughly tested.

Because of the potential danger to a production branch, this command checks
the branch usage before executing.  Inherent branch usage can be set through
the 'productionpattern' command.  If the target working copy has not been
marked with a production-branch pattern, the branch usage is ambiguous and
this command makes the fail-safe assumption that the branch is used for
production.  This assumption can be overriden with the --dev-branch option.
Note that the --dev-branch option will NOT override the production-branch
pattern if one exists.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      conflict = tool.get_conflict_info
      
      unless conflict
        STDERR.puts("No conflict!")
        return
      end
      
      if conflict.scope == :repository
        if conflict.branch_use == :production
          STDERR.puts(<<END_OF_MESSAGE)

The target working copy is on a production branch.  Because fixing the branched
migration chain would require modifying a committed migration, this operation
would result in a migration chain incapable of producing a production upgrade
script, leaving this branch unable to fulfill its purpose.

END_OF_MESSAGE
          raise(XMigra::Error, "Branch use conflict")
        end
        
        dev_branch = (conflict.branch_use == :development) || options.dev_branch
        
        unless dev_branch
          STDERR.puts(<<END_OF_MESSAGE)

The target working copy is neither marked for production branch recognition
nor was the --dev-branch option given on the command line.  Because fixing the
branched migration chain would require modifying a committed migration, this
operation would result in a migration chain incapable of producing a production
upgrage which, because the usage of the working copy's branch is ambiguous, 
might leave this branch unable to fulfill its purpose.

END_OF_MESSAGE
          raise(XMigra::Error, "Potential branch use conflict")
        end
        
        if conflict.branch_use == :undefined
          STDERR.puts(<<END_OF_MESSAGE)

The branch of the target working copy is not marked with a production branch
recognition pattern.  The --dev-branch option was given to override the
ambiguity, but it is much safer to use the 'productionpattern' command to
permanently mark the schema so that production branches can be automatically
recognized.

END_OF_MESSAGE
          # Warning, not error
        end
      end
      
      conflict.fix_conflict!
    end
    
    subcommand 'productionpattern', "Set the recognition pattern for production branches" do |argv|
      args, options = command_line(argv, {},
                                   :argument_desc=>"PATTERN",
                                   :help=> <<END_OF_HELP)
This command sets the production branch recognition pattern for the schema.
The pattern given will determine whether this program treats the current
working copy as a production or development branch.  The PATTERN given
is a Ruby Regexp that is used to evaluate the branch identifier of the working
copy.  Each supported version control system has its own type of branch
identifier:

  Subversion: The path within the repository, starting with a slash (e.g.
              "/trunk", "/branches/my-branch", "/foo/bar%20baz")

If PATTERN matches the branch identifier, the branch is considered to be a
production branch.  If PATTERN does not match, then the branch is a development
branch.  Some operations (e.g. 'unbranch') are prevented on production branches
to avoid making the branch ineligible for generating production upgrade
scripts.

In specifying PATTERN, it is not necessary to escape Ruby special characters
(especially including the slash character), but special characters for the
shell or command interpreter need their usual escaping.  The matching algorithm
used for PATTERN does not require the match to start at the beginning of the
branch identifier; specify the anchor as part of PATTERN if desired.
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      Regexp.compile(args[0])
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      
      tool.production_pattern = args[0]
    end
    
    subcommand 'branchid', "Print the branch identifier string" do |argv|
      args, options = command_line(argv, {},
                                   :help=> <<END_OF_HELP)
This command prints the branch identifier string to standard out (followed by
a newline).
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      
      puts tool.branch_identifier
    end
    
    subcommand 'history', "Show all SQL from migrations changing the target" do |argv|
      args, options = command_line(argv, {:outfile=>true, :target_type=>true, :search_type=>true},
                                   :argument_desc=>"TARGET [TARGET [...]]",
                                   :help=> <<END_OF_HELP)
Use this command to get the SQL run by the upgrade script that modifies any of
the specified TARGETs.  By default this command uses a full item match against
the contents of each item in each migration's "changes" key (i.e.
--by=exact --match=changes).  Migration SQL is printed in order of application
to the database.
END_OF_HELP
      
      argument_error_unless(args.length >= 1,
                            "'%prog %cmd' requires at least one argument.")
      
      target_matches = case options.target_type
      when :substring
        proc {|subject| args.any? {|a| subject.include?(a)}}
      when :regexp
        patterns = args.map {|a| Regexp.compile(a)}
        proc {|subject| patterns.any? {|pat| pat.match(subject)}}
      else
        targets = Set.new(args)
        proc {|subject| targets.include?(subject)}
      end
      
      criteria_met = case options.search_type
      when :sql
        proc {|migration| target_matches.call(migration.sql)}
      else
        proc {|migration| migration.changes.any? {|subject| target_matches.call(subject)}}
      end
      
      tool = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      
      output_to(options.outfile) do |out_stream|
        tool.migrations.each do |migration|
          next unless criteria_met.call(migration)
          
          out_stream << tool.sql_comment_block(File.basename(migration.file_path))
          out_stream << migration.sql
          out_stream << "\n" << tool.batch_separator if tool.respond_to? :batch_separator
          out_stream << "\n"
        end
      end
    end
	
    subcommand 'permissions', "Generate a permission assignment script" do |argv|
      args, options = command_line(argv, {:outfile=>true},
                                   :help=> <<END_OF_HELP)
This command generates and outputs a script that assigns permissions within
a database instance.  The permission information is read from the
permissions.yaml file in the schema root directory (the same directory in which
database.yaml resides) and has the format:

    dbo.MyTable:
      Alice: SELECT
      Bob:
        - SELECT
        - INSERT

(More specifically: The top-level object is a mapping whose scalar keys are
the names of the objects to be modified and whose values are mappings from
security principals to either a single permission or a sequence of
permissions.)  The file is in YAML format; use quoted strings if necessary
(e.g. for Microsoft SQL Server "square bracket escaping", enclose the name in
single or double quotes within the permissions.yaml file to avoid
interpretation of the square brackets as delimiting a sequence).

Before establishing the permissions listed in permissions.yaml, the generated
script first removes any permissions previously granted through use of an
XMigra permissions script.  To accomplish this, the script establishes a table
if it does not yet exist.  The code for this precedes the code to remove
previous permissions.  Thus, the resulting script has the sequence:

    - Establish permission tracking table (if not present)
    - Revoke all previously granted permissions (only those granted
      by a previous XMigra script)
    - Grant permissions indicated in permissions.yaml

To facilitate review of the script, the term "GRANT" is avoided except for
the statements granting the permissions laid out in the source file.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      sql_gen = PermissionScriptWriter.new(options.source_dir).extend(WarnToStderr)
      
      output_to(options.outfile) do |out_stream|
        out_stream.print(sql_gen.permissions_sql)
      end
    end
  end
end

if $0 == __FILE__
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
