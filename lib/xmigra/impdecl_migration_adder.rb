require 'xmigra/declarative_migration'
require 'xmigra/new_migration_adder'

module XMigra
  class ImpdeclMigrationAdder < NewMigrationAdder
    class NoChangesError < Error; end
    
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
      
      # The same user on the same day should not impdecl two different deltas
      # starting at the same committed version -- it will cause a migration
      # name collision.
      file_hash = begin
        file_base = begin
          SchemaUpdater.new(path).branch_identifier + vcs_latest_revision(file_path)
        rescue VersionControlError
          ''
        end
        XMigra.secure_digest(
          [(ENV['USER'] || ENV['USERNAME']).to_s, file_base.to_s].join("\x00")
        )[0,8].tr('+/', '-_')
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
          data[DeclarativeMigration::QUALIFICATION_KEY] = 'unimplemented'
        end
        
        # Reorder "description" key to here with 
        data.delete('description')
        data['description'] = "Declarative #{goal} of #{target_object}"
      end
    end
  end
end
