
require 'xmigra/index'
require 'xmigra/plugin'

module XMigra
  class IndexCollection
    def initialize(path, options={})
      @items = Hash.new
      db_specifics = options[:db_specifics]
      Dir.glob(File.join(path, '*.yaml')).each do |fpath|
        info = YAML.load_file(fpath)
        info['name'] = File.basename(fpath, '.yaml')
        index = Index.new(info)
        index.extend(db_specifics) if db_specifics
        index.file_path = File.expand_path(fpath)
        
        if Plugin.active
          next unless Plugin.active.include_index?(index)
          Plugin.active.amend_index(index)
        end
        
        @items[index.name] = index
      end
    end
    
    def [](name)
      @items[name]
    end
    
    def names
      @items.keys
    end
    
    def each(&block); @items.each_value(&block); end
    include Enumerable
    
    def each_definition_sql
      each {|i| yield i.definition_sql}
    end
    
    def empty?
      @items.empty?
    end
  end
end
