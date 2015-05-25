
require "tsort"
require 'xmigra/plugin'

module XMigra
  class AccessArtifactCollection
    def initialize(path, options={})
      @items = Hash.new
      db_specifics = options[:db_specifics]
      filename_metavariable = options[:filename_metavariable]
      filename_metavariable = filename_metavariable.dup.freeze if filename_metavariable
      
      XMigra.each_access_artifact(path) do |artifact|
        artifact.extend(db_specifics) if db_specifics
        artifact.filename_metavariable = filename_metavariable
        
        if Plugin.active
          next unless Plugin.active.include_access_artifact?(artifact)
          Plugin.active.amend_access_artifact(artifact)
        end
        
        @items[artifact.name] = artifact
      end
      
      if Plugin.active
        Plugin.active.each_additional_access_artifact(db_specifics) do |artifact|
          @items[artifact.name] = artifact
        end
      end
    end
    
    def [](name)
      @items[name]
    end
    
    def names
      @items.keys
    end
    
    def at_path(fpath)
      fpath = File.expand_path(fpath)
      return find {|i| i.file_path == fpath}
    end
    
    def each(&block); @items.each_value(&block); end
    alias tsort_each_node each
    
    def tsort_each_child(node)
      node.depends_on.each do |child|
        yield @items[child]
      end
    end
    
    include Enumerable
    include TSort
    
    def each_definition_sql
      tsort_each do |artifact|
        yield artifact.definition_sql
      end
    end
  end
end
