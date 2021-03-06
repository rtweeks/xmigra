
require 'xmigra/declarative_migration'
require 'xmigra/migration'

module XMigra
  class MigrationChain < Array
    HEAD_FILE = 'head.yaml'
    LATEST_CHANGE = 'latest change'
    MIGRATION_FILE_PATTERN = /^\d{4}-\d\d-\d\d.*\.yaml$/i
    
    include DeclarativeMigration::ChainSupport
    
    def initialize(path, options={})
      super()
      @path = Pathname(path)
      
      db_specifics = options[:db_specifics]
      vcs_specifics = options[:vcs_specifics]
      
      head_info = yaml_of_file(File.join(path, HEAD_FILE)) || {}
      file = head_info[LATEST_CHANGE]
      prev_file = HEAD_FILE
      files_loaded = []
      
      until file.nil?
        file = XMigra.yaml_path(file)
        fpath = File.join(path, file)
        break if (mig_info = yaml_of_file(fpath)).nil?
        files_loaded << file
        mig_info["id"] = Migration::id_from_filename(file)
        migration = Migration.new(mig_info)
        migration.file_path = File.expand_path(fpath)
        migration.extend(db_specifics) if db_specifics
        migration.extend(vcs_specifics) if vcs_specifics
        if migration.file_path.end_with? ".decl.yaml"
          migration.extend(DeclarativeMigration)
        end
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
    
    attr_reader :path
    
    # Test if the chain reaches back to the empty database
    def complete?
      length == 0 || self[0].follows.nil?
    end
    
    # Test if the chain encompasses all migration-like filenames in the path
    def includes_all?
      @other_migrations.empty?
    end
    
    protected
    def yaml_of_file(fpath)
      return nil unless File.file?(fpath)
      begin
        return YAML.load_file(fpath)
      rescue
        raise XMigra::Error, "Error loading/parsing #{fpath}"
      end
    end
  end
end
