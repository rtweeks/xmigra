
module XMigra
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
end
