
require 'xmigra/migration'
require 'xmigra/plugin'

module XMigra
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
    
    attr_reader :file_path, :base_migration, :target_branch, :migration_completed
    
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
    
    def sql
      if Plugin.active
        @sql.dup.tap do |result|
          Plugin.active.amend_source_sql(result)
        end
      else
        @sql
      end
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
end
