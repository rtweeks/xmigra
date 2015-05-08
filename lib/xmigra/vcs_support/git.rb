
module XMigra
  module GitSpecifics
    VersionControlSupportModules << self
    
    MASTER_HEAD_ATTRIBUTE = 'xmigra-master'
    MASTER_BRANCH_SUBDIR = 'xmigra-master'
    
    class AttributesFile
      def initialize(effect_root, access=:shared)
        @effect_root = Pathname(effect_root)
        @access = access
      end
      
      attr_reader :effect_root, :access
      
      def file_relative_path
        case @access
        when :local
          Pathname('.git/info/attributes')
        else
          Pathname('.gitattributes')
        end
      end
      
      def file_path
        @effect_root + file_relative_path
      end
      
      def path_from(path)
        file_path.relative_path_from(Pathname(path))
      end
      
      def description
        "".tap do |result|
          result << "#{path_from(Pathname.pwd)}"
          
          chars = []
          
          if file_path.exist?
            chars << "exists"
          end
          
          case access
          when :local
            chars << "local"
          end
          
          unless chars.empty?
            result << " (#{chars.join(', ')})"
          end
        end
      end
      
      def open(*args, &blk)
        file_path.open(*args, &blk)
      end
    end
    
    class << self
      def manages(path)
        run_git(:status, :check_exit=>true, :quiet=>true)
      end
      
      def run_git(subcmd, *args)
        options = (Hash === args[-1]) ? args.pop : {}
        check_exit = options.fetch(:check_exit, false)
        no_result = !options.fetch(:get_result, true)
        
        cmd_parts = ["git", subcmd.to_s]
        cmd_parts.concat(
          args.flatten.collect {|a| '""'.insert(1, a.to_s)}
        )
        case PLATFORM
        when :unix
          cmd_parts << "2>/dev/null"
        end if options[:quiet]
        
        cmd_str = cmd_parts.join(' ')
        
        output = begin
          `#{cmd_str}`
        rescue
          return false if check_exit
          raise
        end
        return ($?.success? ? output : nil) if options[:get_result] == :on_success
        return $?.success? if check_exit
        raise(VersionControlError, "Git command failed with exit code #{$?.exitstatus}") unless $?.success?
        return output unless no_result
      end
      
      def attr_values(attr, path, options={})
        value_list = run_git('check-attr', attr, '--', path).each_line.map do |line|
          line.chomp.split(/: /, 3)[2]
        end
        return value_list unless options[:single]
        raise VersionControlError, options[:single] + ' ambiguous' if value_list.length > 1
        if (value_list.empty? || value_list == ['unspecified']) && options[:required]
          raise VersionControlError, options[:single] + ' undefined'
        end
        return value_list[0]
      end
      
      def attributes_file_paths(path)
        wdroot = Dir.chdir path do
          Pathname(run_git('rev-parse', '--show-toplevel').strip).realpath
        end
        pwd = Pathname.pwd
        
        [].tap do |result|
          path.realpath.ascend do |dirpath|
            result << AttributesFile.new(dirpath)
            break if (wdroot <=> dirpath) >= 0
          end
          
          result << AttributesFile.new(wdroot, :local)
        end
      end
      
      def get_master_url
        print "Master repository URL (empty for none): "
        master_repo = $stdin.gets.strip
        return nil if master_repo.empty?
        
        loop do
          print "Master branch name: "
          master_branch = $stdin.gets.strip
          return "#{master_repo}##{master_branch}" unless master_branch.empty?
          puts "Master branch name required to set 'xmigra-master' --"
        end
      end
      
      def init_schema(schema_config)
        operations = []
        
        if master_url = get_master_url
          # Select locations for .gitattributes or .git/info/attributes
          attribs_file = ConsoleMenu.new(
            "Git Attributes Files",
            attributes_file_paths(schema_config.root_path),
            "File for storing 'xmigra-master' attribute",
            :get_name => lambda {|af| af.description}
          ).get_selection
          
          dbinfo_path = schema_config.root_path + SchemaManipulator::DBINFO_FILE
          attribute_pattern = "/#{dbinfo_path.relative_path_from(attribs_file.effect_root)}"
          
          schema_config.after_dbinfo_creation do
            attribs_file.open('a') do |attribs_io|
              attribs_io.puts "#{attribute_pattern} xmigra-master=#{master_url}"
            end
            schema_config.created_file! attribs_file.file_path
          end
        end
        
        return operations
      end
    end
    
    def git(*args)
      Dir.chdir(self.path) do |pwd|
        GitSpecifics.run_git(*args)
      end
    end
    
    def check_working_copy!
      return unless production
      
      file_paths = Array.from_generator(method(:each_file_path))
      unversioned_files = git(
        'diff-index',
        %w{-z --no-commit-id --name-only HEAD},
        '--',
        self.path
      ).split("\000").collect do |path|
        File.expand_path(self.path + path)
      end
      
      # Check that file_paths and unversioned_files are disjoint
      unless (file_paths & unversioned_files).empty?
        raise VersionControlError, "Some source files differ from their committed versions"
      end
      
      git_fetch_master_branch
      migrations.each do |m|
        # Check that the migration has not changed in the currently checked-out branch
        fpath = m.file_path
        
        history = git(:log, %w{--format=%H --}, fpath).split
        if history[1]
          raise VersionControlError, "'#{fpath}' has been modified in the current branch of the repository since its introduction"
        end
      end
      
      # Since a production script was requested, warn if we are not generating
      # from a production branch
      if branch_use != :production
        raise VersionControlError, "The working tree is not a commit in the master history."
      end
    end
    
    def vcs_information
      return [
        "Branch: #{branch_identifier}",
        "Path: #{git_internal_path}",
        "Commit: #{git_schema_commit}"
      ].join("\n")
    end
    
    def branch_identifier
      return (if self.production
        self.git_branch_info[0]
      else
        return @git_branch_identifier if defined? @git_branch_identifier
        
        @git_branch_identifier = (
          self.git_master_head(:required=>false) ||
          self.git_local_branch_identifier(:note_modifications=>true)
        )
      end)
    end
    
    def branch_use(commit=nil)
      if commit
        self.git_fetch_master_branch
        
        # If there are no commits between the master head and *commit*, then
        # *commit* is production-ish
        return (self.git_commits_in? self.git_master_local_branch..commit) ? :development : :production
      end
      
      return nil unless self.git_master_head(:required=>false)
      
      return self.git_branch_info[1]
    end
    
    def vcs_move(old_path, new_path)
      git(:mv, old_path, new_path, :get_result=>false)
    end
    
    def vcs_remove(path)
      git(:rm, path, :get_result=>false)
    end
    
    def production_pattern
      ".+"
    end
    
    def production_pattern=(pattern)
      raise VersionControlError, "Under version control by git, XMigra does not support production patterns."
    end
    
    def get_conflict_info
      structure_dir = Pathname.new(self.path) + SchemaManipulator::STRUCTURE_SUBDIR
      head_file = structure_dir + MigrationChain::HEAD_FILE
      stage_numbers = []
      git('ls-files', '-uz', '--', head_file).split("\000").each {|ref|
        if m = /[0-7]{6} [0-9a-f]{40} (\d)\t\S*/.match(ref)
          stage_numbers |= [m[1].to_i]
        end
      }
      return nil unless stage_numbers.sort == [1, 2, 3]
      
      chain_head = lambda do |stage_number|
        return YAML.parse(
          git(:show, ":#{stage_number}:#{head_file}")
        ).transform
      end
      
      # Ours (2) before theirs (3)...
      heads = [2, 3].collect(&chain_head)
      # ... unless merging from upstream
      if self.git_merging_from_upstream?
        heads.reverse!
      end
      
      branch_point = chain_head.call(1)[MigrationChain::LATEST_CHANGE]
      
      conflict = MigrationConflict.new(structure_dir, branch_point, heads)
      
      # Standard git usage never commits directly to the master branch, and
      # there is no effective way to tell if this is happening.
      conflict.branch_use = :development
      
      tool = self
      conflict.after_fix = proc {tool.resolve_conflict!(head_file)}
      
      return conflict
    end
    
    def resolve_conflict!(path)
      git(:add, '--', path, :get_result=>false)
    end
    
    def git_master_head(options={})
      options = {:required=>true}.merge(options)
      return @git_master_head if defined? @git_master_head
      master_head = GitSpecifics.attr_values(
        MASTER_HEAD_ATTRIBUTE,
        self.path + SchemaManipulator::DBINFO_FILE,
        :single=>'Master branch',
        :required=>options[:required]
      )
      return nil if master_head.nil?
      return @git_master_head = master_head
    end
    
    def git_branch
      return @git_branch if defined? @git_branch
      return @git_branch = git('rev-parse', %w{--abbrev-ref HEAD}).chomp
    end
    
    def git_schema_commit
      return @git_commit if defined? @git_commit
      reported_commit = git(:log, %w{-n1 --format=%H --}, self.path).chomp
      raise VersionControlError, "Schema not committed" if reported_commit.empty?
      return @git_commit = reported_commit
    end
    
    def git_branch_info
      return @git_branch_info if defined? @git_branch_info
      
      self.git_fetch_master_branch
      
      # If there are no commits between the master head and HEAD, this working
      # copy is production-ish
      return (@git_branch_info = if self.branch_use('HEAD') == :production
        [self.git_master_head, :production]
      else
        [self.git_local_branch_identifier, :development]
      end)
    end
    
    def git_local_branch_identifier(options={})
      host = `hostname`
      path = git('rev-parse', '--show-toplevel')
      return "#{git_branch} of #{path} on #{host} (commit #{git_schema_commit})"
    end
    
    def git_fetch_master_branch
      return if @git_master_branch_fetched
      master_url, remote_branch = self.git_master_head.split('#', 2)
      
      git(:fetch, '-f', master_url, "#{remote_branch}:#{git_master_local_branch}", :get_result=>false, :quiet=>true)
      @git_master_branch_fetched = true
    end
    
    def git_master_local_branch
      "#{MASTER_BRANCH_SUBDIR}/#{git_branch}"
    end
    
    def git_internal_path
      return @git_internal_path if defined? @git_internal_path
      path_prefix = git('rev-parse', %w{--show-prefix}).chomp[0..-2]
      internal_path = '.'
      if path_prefix.length > 0
        internal_path += '/' + path_prefix
      end
      return @git_internal_path = internal_path
    end
    
    def git_merging_from_upstream?
      upstream = git('rev-parse', '@{u}', :get_result=>:on_success, :quiet=>true)
      return false if upstream.nil?
      
      # Check if there are any commits in #{upstream}..MERGE_HEAD
      begin
        return !(self.git_commits_in? upstream..'MERGE_HEAD')
      rescue VersionControlError
        return false
      end
    end
    
    def git_commits_in?(range, path=nil)
      git(
        :log,
        '--pretty=format:%H',
        '-1',
        "#{range.begin.strip}..#{range.end.strip}",
        '--',
        path || self.path
      ) != ''
    end
  end
end
