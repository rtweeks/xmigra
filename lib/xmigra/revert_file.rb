require 'pathname'

module XMigra
  class RevertFile
    REVERSION_SUBDIR = 'rollback'
    
    def initialize(migration)
      @migration = migration
      mig_path = Pathname(migration.file_path)
      @description = "REVERT #{migration.description} (#{mig_path.basename})"
      @path = migration.schema_dir.join(
        REVERSION_SUBDIR,
        mig_path.basename.to_s.sub(/\..*?$/, '.sql')
      )
    end
    
    attr_reader :path, :description
    
    def to_s
      if @path.exist?
        @sql ||= "-- %s:\n\n%s\n%s" % [
          @description,
          @path.read,
          @migration.reversion_tracking_sql
        ]
      else
        "-- #@description: No reversion given\n"
      end
    end
    
    def inspect
      "#<#{self.class.name} %s%s>" % [
        @path,
        (" (missing)" unless @path.exist?),
      ]
    end
    
    def exist?
      @path.exist?
    end
  end
end
