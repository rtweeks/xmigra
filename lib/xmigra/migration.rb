
module XMigra
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
end
