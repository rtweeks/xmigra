require 'xmigra/console'

module XMigra
  module SubversionSpecifics
    VersionControlSupportModules << self
    
    PRODUCTION_PATH_PROPERTY = 'xmigra:production-path'
    
    class << self
      def manages(path)
        begin
          return true if File.directory?(File.join(path, '.svn'))
        rescue TypeError
          return false
        end
        
        `svn info "#{path}" 2>&1`
        return $?.success?
      end
      
      # Run the svn command line client in XML mode and return a REXML::Document
      def run_svn(subcmd, *args)
        options = (Hash === args[-1]) ? args.pop : {}
        no_result = !options.fetch(:get_result, true)
        raw_result = options.fetch(:raw, false) || subcmd.to_s == 'cat'
        
        cmd_parts = ["svn", subcmd.to_s]
        cmd_parts << "--xml" unless no_result || raw_result
        cmd_parts.concat(
          args.collect {|a| '""'.insert(1, a.to_s)}
        )
        cmd_str = cmd_parts.join(' ')
        
        output = `#{cmd_str} 2>/dev/null`
        raise(VersionControlError, "Subversion command failed with exit code #{$?.exitstatus}") unless $?.success?
        return output if raw_result && !no_result
        return REXML::Document.new(output) unless no_result
      end
      
      def init_schema(schema_config)
        Console.output_section "Subversion Integration" do
          puts "Establishing a \"production pattern,\" a regular expression for"
          puts "recognizing branch identifiers of branches used for production"
          puts "script generation, simplifies the process of resolving conflicts"
          puts "in the migration chain, should any arise."
          puts
          puts "No escaping (either shell or Ruby) of the regular expression is"
          puts "necessary when entered here."
          puts
          puts "Common choices are:"
          puts "    ^trunk/"
          puts "    ^version/"
          puts
          print "Production pattern (empty to skip): "
          
          production_pattern = $stdin.gets.chomp
          return if production_pattern.empty?
          schema_config.after_dbinfo_creation do
            tool = SchemaManipulator.new(schema_config.root_path).extend(WarnToStderr)
            tool.production_pattern = production_pattern
          end
        end
      end
    end
    
    def subversion(*args)
      SubversionSpecifics.run_svn(*args)
    end
    
    def check_working_copy!
      return unless production
      
      schema_info = subversion_info
      file_paths = Array.from_generator(method(:each_file_path))
      status = subversion(:status, '--no-ignore', path)
      unversioned_files = status.elements.each("status/target/entry/@path")
      unversioned_files = unversioned_files.collect {|a| File.expand_path(a.to_s)}
      
      unless (file_paths & unversioned_files).empty?
        raise VersionControlError, "Some source files are not versions found in the repository"
      end
      status = nil
      
      wc_rev = {}
      working_rev = schema_info.elements["info/entry/@revision"].value.to_i
      file_paths.each do |fp|
        fp_info = subversion(:info, fp)
        wc_rev[fp] = fp_wc_rev = fp_info.elements["info/entry/@revision"].value.to_i
        if working_rev != fp_wc_rev
          raise VersionControlError, "The working copy contains objects at multiple revisions"
        end
      end
      
      migrations.each do |m|
        fpath = m.file_path
        
        log = subversion(:log, "-r#{wc_rev[fpath]}:1", "--stop-on-copy", fpath)
        if log.elements["log/logentry[2]"]
          raise VersionControlError, "'#{fpath}' has been modified in the repository since it was created or copied"
        end
      end
      
      # Since a production script was requested, warn if we are not generating
      # from a production branch
      if branch_use != :production and self.respond_to? :warning
        self.warning(<<END_OF_MESSAGE)
The branch backing the target working copy is not marked as a production branch.
END_OF_MESSAGE
      end
    end
    
    def vcs_information
      info = subversion_info
      return [
        "Repository URL: #{info.elements["info/entry/url"].text}",
        "Revision: #{info.elements["info/entry/@revision"].value}"
      ].join("\n")
    end
    
    def get_conflict_info
      # Check if the structure head is conflicted
      structure_dir = Pathname.new(self.path) + SchemaManipulator::STRUCTURE_SUBDIR
      status = subversion(:status, structure_dir + MigrationChain::HEAD_FILE)
      return nil if status.elements["status/target/entry/wc-status/@item"].value != "conflicted"
      
      chain_head = lambda do |extension|
        pattern = MigrationChain::HEAD_FILE + extension
        if extension.include? '*'
          files = structure_dir.glob(MigrationChain::HEAD_FILE + extension)
          raise VersionControlError, "Multiple #{pattern} files in structure directory" if files.length > 1
          raise VersionControlError, "#{pattern} file missing from structure directory" if files.length < 1
        else
          files = [structure_dir.join(pattern)]
        end
        
        # Using YAML.parse_file and YAML::Syck::Node#transform rerenders
        # scalars in the same style they were read from the source file:
        return YAML.parse_file(files[0]).transform
      end
      
      if (structure_dir + (MigrationChain::HEAD_FILE + ".working")).exist?
        # This is a merge conflict
        
        # structure/head.yaml.working is from the current branch
        # structure/head.yaml.merge-left.r* is the branch point
        # structure/head.yaml.merge-right.r* is from the merged-in branch
        this_head = chain_head.call(".working")
        other_head = chain_head.call(".merge-right.r*")
        branch_point = chain_head.call(".merge-left.r*")[MigrationChain::LATEST_CHANGE]
        
        conflict = MigrationConflict.new(structure_dir, branch_point, [other_head, this_head])
        
        branch_use {|u| conflict.branch_use = u}
      else
        # This is an update conflict
        
        # structure/head.yaml.mine is from the working copy
        # structure/head.yaml.r<lower> is the common ancestor
        # structure/head.yaml.r<higher> is the newer revision
        working_head = chain_head.call('.mine')
        oldrev, newrev = nil, 0
        structure_dir.glob(MigrationChain::HEAD_FILE + '.r*') do |fn|
          if fn.to_s =~ /.r(\d+)$/
            rev = $1.to_i
            if oldrev.nil? or rev < oldrev
              oldrev = rev
            end
            if newrev < rev
              newrev = rev
            end
          end
        end
        repo_head = chain_head.call(".r#{newrev}")
        branch_point = chain_head.call(".r#{oldrev}")[MigrationChain::LATEST_CHANGE]
        
        conflict = MigrationConflict.new(structure_dir, branch_point, [repo_head, working_head])
        branch_use {|u| conflict.branch_use = u}
        
        fix_target, = conflict.migration_tweak
        fix_target_st = subversion(:status, fix_target)
        if fix_target_st.elements['status/target/entry/wc-status/@item'].value == 'modified'
          conflict.scope = :working_copy
        end
      end
      
      tool = self
      conflict.after_fix = proc {tool.resolve_conflict!(structure_dir + MigrationChain::HEAD_FILE)}
      
      return conflict
    end
    
    def branch_use
        # Look for xmigra:production-path on the database directory (self.path)
      return nil unless prod_path_element = subversion(:propget, PRODUCTION_PATH_PROPERTY, self.path).elements['properties/target/property']
      
      prod_path_pattern = Regexp.new(prod_path_element.text)
      
      use = prod_path_pattern.match(branch_identifier) ? :production : :development
      if block_given?
        yield use
      else
        return use
      end
    end
    
    def branch_identifier
      return @subversion_branch_id if defined? @subversion_branch_id
      dir_info = subversion_info
      return @subversion_branch_id = dir_info.elements['info/entry/url'].text[
        dir_info.elements['info/entry/repository/root'].text.length..-1
      ]
    end
    
    def production_pattern
      subversion(:propget, PRODUCTION_PATH_PROPERTY, self.path, :raw=>true)
    end
    def production_pattern=(pattern)
      subversion(:propset, PRODUCTION_PATH_PROPERTY, pattern, self.path, :get_result=>false)
    end
    
    def resolve_conflict!(path)
      subversion(:resolve, '--accept=working', path, :get_result=>false)
    end
    
    def vcs_uncommitted?
      status = subversion_retrieve_status(file_path).elements['entry/wc-status']
      status.nil? || status.attributes['item'] == 'unversioned'
    end
    
    class VersionComparator
      # vcs_object.kind_of?(SubversionSpecifics)
      def initialize(vcs_object, options={})
        @object = vcs_object
        @expected_content_method = options[:expected_content_method]
        @path_status = Hash.new do |h, file_path|
          file_path = Pathname(file_path).expand_path
          next h[file_path] if h.has_key?(file_path)
          h[file_path] = @object.subversion_retrieve_status(file_path)
        end
      end
      
      def relative_version(file_path)
        # Comparing @object.file_path (a) to file_path (b)
        #
        # returns: :newer, :equal, :older, or :missing
        
        b_status = @path_status[file_path].elements['entry/wc-status']
        
        return :missing if b_status.nil? || ['deleted', 'missing'].include?(b_status.attributes['item'])
        
        a_status = @path_status[@object.file_path].elements['entry/wc-status']
        
        if ['unversioned', 'added'].include? a_status.attributes['item']
          if ['unversioned', 'added', 'modified'].include? b_status.attributes['item']
            return relative_version_by_content(file_path)
          end
          
          return :older
        elsif a_status.attributes['item'] == 'normal'
          return :newer unless b_status.attributes['item'] == 'normal'
          
          return begin
            a_revision = a_status.elements['commit'].attributes['revision'].to_i
            b_revision = b_status.elements['commit'].attributes['revision'].to_i
            
            if a_revision < b_revision
              :newer
            elsif b_revision < a_revision
              :older
            else
              :equal
            end
          end
        elsif b_status.attributes['item'] == 'normal'
          return :older
        else
          return relative_version_by_content(file_path)
        end
      end
      
      def relative_version_by_content(file_path)
        ec_method = @expected_content_method
        if !ec_method || @object.send(ec_method, file_path)
          return :equal
        else
          return :newer
        end
      end
    end
    
    def vcs_comparator(options={})
      VersionComparator.new(self, options)
    end
    
    def vcs_move(old_path, new_path)
      subversion(:move, old_path, new_path, :get_result=>false)
    end
    
    def vcs_remove(path)
      subversion(:remove, path, :get_result=>false)
    end
    
    def subversion_info
      return @subversion_info if defined? @subversion_info
      return @subversion_info = subversion(:info, self.path)
    end
    
    def vcs_production_contents(path)
      path = Pathname(path)
      
      # Check for a production pattern.  If none exists, there is no way to
      # identify which branches are production, so essentially no production
      # content:
      prod_pat = self.production_pattern
      return nil if prod_pat.nil?
      prod_pat = Regexp.compile(prod_pat.chomp)
      
      # Is the current branch a production branch?  If so, cat the committed
      # version:
      if branch_identifier =~ prod_pat
        return svn(:cat, path.to_s)
      end
      
      # Use an SvnHistoryTracer to walk back through the history of self.path
      # looking for a copy from a production branch.
      tracer = SvnHistoryTracer.new(self.path)
      
      while !(match = tracer.earliest_loaded_repopath =~ prod_pat) && tracer.load_parent_commit
        # loop
      end
      
      if match
        subversion(:cat, "-r#{tracer.earliest_loaded_revision}", path.to_s)
      end
    end
    
    def vcs_contents(path, options={})
      args = []
      
      if options[:revision]
        args << "-r#{options[:revision]}"
      end
      
      args << path.to_s
      
      subversion(:cat, *args)
    end
    
    def vcs_latest_revision(a_file=nil)
      if a_file.nil? && defined? @vcs_latest_revision
        return @vcs_latest_revision
      end
      
      val = subversion(:status, '-v', a_file || file_path).elements[
        'string(status/target/entry/wc-status/commit/@revision)'
      ]
      (val.nil? ? val : val.to_i).tap do |val|
        @vcs_latest_revision = val if a_file.nil?
      end
    end
    
    def vcs_changes_from(from_revision, file_path)
      subversion(:diff, '-r', from_revision, file_path, :raw=>true)
    end
    
    def vcs_most_recent_committed_contents(file_path)
      subversion(:cat, file_path)
    end
    
    def subversion_retrieve_status(file_path)
      subversion(:status, '-v', file_path).elements['status/target']
    end
  end
  
  class SvnHistoryTracer
    include SubversionSpecifics
    
    def initialize(path)
      @path = Pathname(path)
      info_doc = subversion(:info, path.to_s)
      @root_url = info_doc.elements['string(info/entry/repository/root)']
      @most_recent_commit = info_doc.elements['string(info/entry/@revision)'].to_i
      @history = []
      @next_query = [branch_identifier, @most_recent_commit]
      @history.unshift(@next_query.dup)
    end
    
    attr_reader :path, :most_recent_commit, :history
    
    def load_parent_commit
      log_doc = next_earlier_log
      if copy_elt = copying_element(log_doc)
        trailing_part = branch_identifier[copy_elt.text.length..-1]
        @next_query = [
          copy_elt.attributes['copyfrom-path'] + trailing_part,
          copy_elt.attributes['copyfrom-rev'].to_i
        ]
        @history.unshift(@next_query)
        @next_query.dup
      elsif change_elt = log_doc.elements['/log/logentry']
        @next_query[1] = change_elt.attributes['revision'].to_i - 1
        @next_query.dup if @next_query[1] > 0
      else
        @next_query[1] -= 1
        @next_query.dup if @next_query[1] > 0
      end
    end
    
    def history_exhausted?
      @next_query[1] <= 0
    end
    
    def earliest_loaded_repopath
      history[0][0]
    end
    
    def earliest_loaded_url
      @root_url + history[0][0]
    end
    
    def earliest_loaded_revision
      history[0][1]
    end
    
    def earliest_loaded_pinned_url(rel_path=nil)
      pin_rev = @history[0][1]
      if rel_path.nil?
        [earliest_loaded_url, pin_rev.to_s].join('@')
      else
        rel_path = Pathname(rel_path)
        "#{earliest_loaded_url}/#{rel_path}@#{pin_rev}"
      end
    end
    
    def copying_element(log_doc)
      log_doc.each_element %Q{/log/logentry/paths/path[@copyfrom-path]} do |elt|
        return elt if elt.text == @next_query[0]
        return elt if @next_query[0].start_with? (elt.text + '/')
      end
      return nil
    end
    
    def next_earlier_log
      subversion(:log, '-l1', '-v', "-r#{@next_query[1]}:1", self.path)
    end
  end
end
