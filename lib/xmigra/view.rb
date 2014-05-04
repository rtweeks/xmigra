
require 'xmigra/access_artifact'

module XMigra
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
end
