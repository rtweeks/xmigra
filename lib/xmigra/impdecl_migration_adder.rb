require 'xmigra/declarative_migration'
require 'xmigra/new_migration_adder'

module XMigra
  class ImpdeclMigrationAdder < NewMigrationAdder
    class NoChangesError < Error; end
    
    @support_types = {}
    def self.register_support_type(tag, klass)
      if @support_types.has_key? tag
        raise Error, "#{@support_types[tag]} already registered to handle #{tag}"
      end
      @support_types[tag] = klass
    end
    
    def self.support_type(tag)
      @support_types[tag]
    end
    
    module SupportedDatabaseObject
      module ClassMethods
        def for_declarative_tagged(tag)
          XMigra::ImpdeclMigrationAdder.register_support_type(tag, self)
        end
      end
      
      def self.included(mod)
        mod.extend(ClassMethods)
      end
      
      # Classes including this Module should define:
      #     #creation_sql
      #     #sql_to_effect_from(old_state)
      #     #destruction_sql
      #
      # and expect to receive as arguments to their constructor the name of
      # the object and the Ruby-ized data present at the top level of the
      # declarative file.
    end
    
    def initialize(path)
      super(path)
      @migrations = MigrationChain.new(
        self.path.join(STRUCTURE_SUBDIR),
        :db_specifics=>@db_specifics,
        :vcs_specifics=>@vcs_specifics,
      )
    end
    
    def add_migration_implementing_changes(file_path, options={})
      file_path = Pathname(file_path)
      prev_impl = @migrations.latest_declarative_implementations[file_path]
      decl_stat = prev_impl.declarative_status
      
      # Declarative doesn't make any sense without version control
      unless VersionControlSupportModules.find {|m| self.kind_of? m}
        raise Error, "#{self.path} is not under version control (required for declarative)"
      end
      
      # Check if an implementation is needed/allowed
      if bad_rel = {
          :equal=>"the same revision as",
          :older=>"an older revision than",
      }[decl_stat]
        raise NoChangesError, "#{file_path} changed in #{bad_rel} the latest implementing migration #{prev_impl.file_path}"
      end
      
      # This should require the same user to generate a migration on the same
      # day starting from the same committed version working on the same
      # branch to cause a collision of migration file names:
      file_hash = begin
        file_base = begin
          [
            SchemaUpdater.new(path).branch_identifier,
            vcs_latest_revision(file_path),
          ].join("\x00")
        rescue VersionControlError
          ''
        end
        XMigra.secure_digest(
          [(ENV['USER'] || ENV['USERNAME']).to_s, file_base.to_s].join("\x00"),
          :encoding=>:base32
        )[0,12]
      end
      summary = "#{file_path.basename('.yaml')}-#{file_hash}.decl"
      
      add_migration_options = {
        :file_path=>file_path,
      }
      
      # Figure out the goal of the change to the declarative
      fail_options = []
      case decl_stat
      when :unimplemented
        fail_options << :renounce
        add_migration_options[:goal] = options[:adopt] ? 'adoption' : 'creation'
      when :newer
        fail_options.concat [:adopt, :renounce]
        add_migration_options[:goal] = 'revision'
      when :missing
        fail_options << :adopt
        add_migration_options[:goal] = options[:renounce] ? 'renunciation' : 'destruction'
      end
      
      if opt = fail_options.find {|o| options[o]}
        raise Program::ArgumentError, "--#{opt} flag is invalid when declarative file is #{decl_stat}"
      end
      
      add_migration_options[:delta] = prev_impl.delta(file_path).extend(LiteralYamlStyle)
      unless options[:adopt] || options[:renounce]
        if suggested_sql = build_suggested_sql(decl_stat, file_path, prev_impl)
          add_migration_options[:sql] = suggested_sql
          add_migration_options[:sql_suggested] = true
        end
      end
      
      add_migration(summary, add_migration_options)
    end
    
    def migration_data(head_info, options)
      target_object = options[:file_path].basename('.yaml')
      goal = options[:goal].to_sym
      super(head_info, options).tap do |data|
        # The "changes" key is not used by declarative implementation
        #migrations -- the "of object" (TARGET_KEY) is used instead
        data.delete(Migration::CHANGES)
        
        data[DeclarativeMigration::GOAL_KEY] = options[:goal].to_s
        data[DeclarativeMigration::TARGET_KEY] = target_object.to_s
        data[DeclarativeMigration::DECLARATION_VERSION_KEY] = begin
          if [:renunciation, :destruction].include?(goal)
            'DELETED'
          else
            XMigra.secure_digest(options[:file_path].read)
          end
        end
        data['delta'] = options[:delta]
        
        # Reorder "sql" key to here (unless adopting or renouncing, then
        # remove "sql" completely)
        provided_sql = data.delete('sql')
        unless [:adoption, :renunciation].include? goal
          data['sql'] = provided_sql
          data[DeclarativeMigration::QUALIFICATION_KEY] = begin
            if options[:sql_suggested]
              'suggested SQL'
            else
              'unimplemented'
            end
          end 
        end
        
        # Reorder "description" key to here with 
        data.delete('description')
        data['description'] = "Declarative #{goal} of #{target_object}"
      end
    end
    
    def build_suggested_sql(decl_stat, file_path, prev_impl)
      d = SupportedObjectDeserializer(
        file_path.basename('.yaml')
      )
      case decl_stat
      when :unimplemented
        initial_state = YAML.parse_file(file_path)
        initial_state = d.deserialize(initial_state.children[0])
        
        if initial_state.kind_of?(SupportedDatabaseObject)
          initial_state.creation_sql
        end
      when :newer
        old_state = YAML.parse(
          vcs_contents(file_path, :revision=>prev_impl.vcs_latest_revision),
          file_path
        )
        old_state = d.deserialize(old_state.children[0])
        new_state = YAML.parse_file(file_path)
        new_state = d.deserialize(new_state.children[0])
        
        if new_state.kind_of?(SupportedDatabaseObject) && old_state.class == new_state.class
          new_state.sql_to_effect_from old_state
        end
      when :missing
        penultimate_state = YAML.parse(
          vcs_contents(file_path, :revision=>prev_impl.vcs_latest_revision),
          file_path
        )
        penultimate_state = d.deserialize(penultimate_state.children[0])
        
        if penultimate_state.kind_of?(SupportedDatabaseObject)
          penultimate_state.destruction_sql
        end
      end
    rescue StandardError
      nil
    end
    
    class SupportedObjectDeserializer
      def initialize(object_name)
        @object_name = object_name
      end
      
      attr_reader :object_name
      
      def deserialize(yaml_node)
        data = yaml_node.to_ruby
        if klass = ImpdeclMigrationAdder.support_type(yaml_node.tag)
          klass.new(@object_name, data)
        else
          if data.respond_to? :name=
            data.name = @object_name
          elsif data.kind_of? Hash
            data['name'] = @object_name
          end
          data
        end
      end
    end
  end
end
