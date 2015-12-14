
module XMigra
  module DeclarativeMigration
    VALID_GOALS = %w{creation adoption revision renunciation destruction}
    GOAL_KEY = 'does'
    TARGET_KEY = 'of object'
    DECLARATION_VERSION_KEY = 'to realize'
    QUALIFICATION_KEY = 'implementation qualification'
    SUBDIR = 'declarative'
    
    class MissingImplementationError < Error
      COMMAND_LINE_HELP = "The '%prog impdecl' command may help resolve this error."
    end
    
    class QuestionableImplementationError < Error; end
    
    Missing = Class.new do
      def goal
        :newly_managed_object
      end
      
      def declarative_status
        :unimplemented
      end
      
      def delta(file_path)
        Pathname(file_path).readlines.map {|l| '+' + l}.join('')
      end
    end.new
    
    module ChainSupport
      def latest_declarative_implementations
        @latest_declarative_implementations ||= Hash.new do |h, file_path|
          ext_path = Pathname(file_path).expand_path
          if h.has_key? ext_path
            next h[ext_path]
          end
          raise Error, (
            "Unexpected file path '#{file_path}', known file paths:" +
            h.keys.collect {|kp| "    #{kp}\n"}.join('')
          )
        end.tap do |files|
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
          
          Dir.glob(Pathname(path).join(SUBDIR, '*.yaml').to_s) do |decl_file|
            decl_file_path = Pathname(decl_file).expand_path
            next if files.has_key?(decl_file_path)
            files[decl_file_path] = DeclarativeMigration::Missing
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
        
        questionable_migrations = latest_declarative_implementations.values.select {|m| m.questionable?}
        unless questionable_migrations.empty?
          raise(
            QuestionableImplementationError,
            "Implementing migrations with questionable SQL:\n" +
            questionable_migrations.collect {|m| "    #{m.file_path}\n"}.join("")
          )
        end
        
        questionable_migrations = latest_declarative_implementations.values.each do |m|
          next unless m.management_migration?
          raise(
            QuestionableImplementationError,
            "#{m.file_path} cannot execute SQL for a declarative #{m.goal}"
          ) unless m.sql.nil? || m.sql.empty?
        end
      end
    end
    
    def goal
      @declarative_goal ||= @all_info[GOAL_KEY].tap do |val|
        raise(ArgumentError, "'#{GOAL_KEY}' must be one of: #{VALID_GOALS.join(', ')}") unless VALID_GOALS.include?(val)
      end.to_sym
    end
    
    def affected_object
      @declarative_target ||= @all_info[TARGET_KEY].dup.freeze
    end
    
    # Override the way the base class handles changes -- this integrates with
    # the "history" command
    def changes
      if management_migration?
        []
      else
        [affected_object]
      end
    end
    
    def sql
      if management_migration?
        ''
      else
        super()
      end
    end
    
    def management_migration?
      [:adoption, :renunciation].include? goal
    end
    
    # This method is only used when the declarative file has uncommitted
    # modifications and the migration file is uncommitted
    def implemented_version
      @declarative_implemented_ver ||= (@all_info[DECLARATION_VERSION_KEY].dup.freeze if vcs_uncommitted?)
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
    
    def delta(file_path)
      vcs_changes_from(vcs_latest_revision, file_path)
    end
    
    def questionable?
      @all_info.has_key? QUALIFICATION_KEY
    end
  end
end
