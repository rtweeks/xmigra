
module XMigra
  class SchemaManipulator
    DBINFO_FILE = 'database.yaml'
    PERMISSIONS_FILE = 'permissions.yaml'
    ACCESS_SUBDIR = 'access'
    INDEXES_SUBDIR = 'indexes'
    STRUCTURE_SUBDIR = 'structure'
    VERINC_FILE = 'branch-upgrade.yaml'
    
    PLUGIN_KEY = 'XMigra plugin'
    
    def initialize(path)
      @path = Pathname.new(path)
      @db_info = YAML.load_file(@path + DBINFO_FILE)
      raise TypeError, "Expected Hash in #{DBINFO_FILE}" unless Hash === @db_info
      @db_info = Hash.new do |h, k|
        raise Error, "#{DBINFO_FILE} missing key #{k.inspect}"
      end.update(@db_info)
      
      db_system = @db_info['system']
      extend(
        @db_specifics = DatabaseSupportModules.find {|m|
          m::SYSTEM_NAME == db_system
        } || NoSpecifics
      )
      
      extend(
        @vcs_specifics = VersionControlSupportModules.find {|m|
          m.manages(path)
        } || NoSpecifics
      )
      
      if @db_info.has_key? PLUGIN_KEY
        @plugin = @db_info[PLUGIN_KEY]
      end
    end
    
    attr_reader :path, :plugin
    
    def branch_upgrade_file
      @path.join(STRUCTURE_SUBDIR, VERINC_FILE)
    end
    
    def load_plugin!
      Plugin.load! plugin if plugin
    end
  end
end
