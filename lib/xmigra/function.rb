
require 'xmigra/access_artifact'

module XMigra
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
end
