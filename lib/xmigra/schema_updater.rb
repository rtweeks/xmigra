
require 'xmigra/plugin'
require 'xmigra/schema_manipulator'
require 'xmigra/reversion_script_building'

module XMigra
  class SchemaUpdater < SchemaManipulator
    include ReversionScriptBuilding
    
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
      if Plugin.active
        intro_comment = intro_comment.dup
        Plugin.active.amend_source_sql(intro_comment)
      end
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
        
        script_parts.map {|mn| self.send(mn)}.flatten.compact.join(ddl_block_separator).tap do |result|
          Plugin.active.amend_composed_sql(result) if Plugin.active
        end
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
end
