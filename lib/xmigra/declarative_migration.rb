
module XMigra
  module DeclarativeMigration
    VALID_GOALS = %w{creation adoption revision renunciation destruction}
    GOAL_KEY = 'does'
    TARGET_KEY = 'of object'
    DECLARATION_VERSION_KEY = 'to realize'
    SUBDIR = 'declarative'
    
    class MissingImplementationError < XMigra::Error
    end
    
    Missing = Class.new do
      def declarative_status
        :unimplemented
      end
    end.new
    
    module ChainSupport
      def latest_declarative_implementations
        @latest_declarative_implementations ||= Hash.new.tap do |files|
          each do |migration|
            # Skip non-declarative migrations
            next unless migration.is_a? DeclarativeMigration
            if (
              [:renunciation, :destruction].include?(migration.goal) &&
              migration.declarative_status == :missing
            )
              files.delete(migration.declarative_file_path)
            else
              files[migration.declarative_file_path] = migration
            end
          end
          
          Pathname(path).join(SUBDIR).glob('*.yaml') do |declarative|
            files[declarative] ||= DeclarativeMigration::Missing
          end
          
          files.freeze
        end
      end
      
      def unimplemented_declaratives
        @unimplemented_declaratives ||= latest_declarative_implementations.reject do |file_path, migration|
          [:equal, :older].include? migration.declarative_status
        end.keys
      end
      
      def check_declaratives_current!
        unless unimplemented_declaratives.empty?
          raise(
            MissingImplementationError,
            "Declaratives without migration implementing current state:\n" +
            unimplemented_declaratives.collect {|df| "    #{df.basename('.yaml')}\n"}.join("")
          )
        end
      end
    end
    
    def goal
      @declarative_goal ||= @all_info[GOAL_KEY].tap do |val|
        raise(ArgumentError, "'#{GOAL_KEY}' must be one of: #{VALID_GOALS.join(', ')}") unless VALID_GOALS.include?(goal)
      end.to_sym
    end
    
    def affected_object
      @declarative_target ||= @all_info[TARGET_KEY]
    end
    
    # This method is only used when the declarative file has uncommitted
    # modifications and the migration file is uncommitted
    def implemented_version
      @declarative_implemented_ver ||= (@all_info[DECLARATION_VERSION_KEY] if vcs_uncommitted?)
    end
    
    def implementation_of?(file_path)
      XMigra.secure_digest(file_path.read) == implemented_version
    end
    
    def declarative_file_path
      @declarative_file_path ||= Pathname(file_path).dirname.join(SUBDIR, affected_object + '.yaml')
    end
    
    def declarative_status
      @declarative_status ||= begin
        vcs_comparator(:expected_content_method=>:implementation_of?).relative_version(declarative_file_path)
      end
    end
  end
end
