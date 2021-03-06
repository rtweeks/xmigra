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
      @sql = info.has_key?('sql') ? info["sql"].dup.freeze : nil
      @description = info["description"].dup.freeze
      @changes = (info[CHANGES] || []).dup.freeze
      @changes.each {|c| c.freeze}
      @all_info = Marshal.load(Marshal.dump(info))
    end
    
    attr_reader :id, :follows, :description, :changes
    attr_accessor :file_path
    
    def schema_dir
      @schema_dir ||= begin
        result = Pathname(file_path).dirname
        while result.basename.to_s != SchemaManipulator::STRUCTURE_SUBDIR
          result = result.dirname
        end
        result.join('..')
      end
    end
    
    def sql
      if Plugin.active
        (@sql || "").dup.tap do |result|
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
