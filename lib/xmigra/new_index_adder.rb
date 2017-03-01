
require 'xmigra/schema_manipulator'

module XMigra
  class NewIndexAdder < SchemaManipulator
    def initialize(path)
      super(path)
    end
    
    def add_index(name)
      indexes_dir = @path.join(INDEXES_SUBDIR)
      FileUtils.mkdir_p(indexes_dir) unless indexes_dir.exist?
      
      new_fpath = indexes_dir.join(name + '.yaml')
      raise(XMigra::Error, "Index \"#{new_fpath.basename}\" already exists") if new_fpath.exist?
      
      index_creation_template = begin
        index_template_sql.gsub('[{filename}]', name)
      rescue NameError
        ''
      end
      new_data = {
        'sql'=>index_creation_template.dup.extend(LiteralYamlStyle),
      }
      
      File.open(new_fpath, "w") do |f|
        $xmigra_yamler.dump(new_data, f)
      end
      
      return new_fpath
    end
  end
end
