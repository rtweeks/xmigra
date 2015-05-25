require 'pathname'
require 'xmigra/plugin'
require 'xmigra/revert_file'

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
    
    attr_reader :id, :follows, :description, :changes
    attr_accessor :file_path
    
    def schema_dir
      Pathname(file_path).dirname.join('..')
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
    
    def reversion
      result = RevertFile.new(self)
      return result if result.exist?
    end
    
    class << self
      def id_from_filename(fname)
        XMigra.secure_digest(fname.upcase) # Base64 encoded digest
      end
    end
  end
end
