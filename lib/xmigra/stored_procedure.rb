
require 'xmigra/access_artifact'

module XMigra
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
end
