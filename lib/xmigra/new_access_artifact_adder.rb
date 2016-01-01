
require 'xmigra/schema_manipulator'

module XMigra
  class NewAccessArtifactAdder < SchemaManipulator
    class UnsupportedArtifactType < XMigra::Error
      def initialize(artifact_type, system_name)
        super("#{system_name} does not support #{artifact_type} artifacts")
        @artifact_type = artifact_type
        @system_name = system_name
      end
      
      attr_reader :artifact_type, :system_name
    end
    
    def initialize(path)
      super(path)
    end
    
    def add_artifact(type, name)
      access_dir = @path.join(ACCESS_SUBDIR)
      FileUtils.mkdir_p(access_dir) unless access_dir.exist?
      
      new_fpath = access_dir.join(name + '.yaml')
      raise(XMigra::Error, "Access object \"#{new_fpath.basename}\" already exists") if new_fpath.exist?
      
      template_method = begin
        method("#{type}_definition_template_sql".to_sym)
      rescue NameError
        proc {''}
      end
      new_data = {
        'define'=>type.to_s,
        'sql'=>template_method.call.dup.extend(LiteralYamlStyle),
      }
      
      File.open(new_fpath, "w") do |f|
        $xmigra_yamler.dump(new_data, f)
      end
      
      return new_fpath
    end
  end
end
