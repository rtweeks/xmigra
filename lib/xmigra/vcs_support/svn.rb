
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
        raw_result = options.fetch(:raw, false)
        
        cmd_parts = ["svn", subcmd.to_s]
        cmd_parts << "--xml" unless no_result || raw_result
        cmd_parts.concat(
          args.collect {|a| '""'.insert(1, a)}
        )
        cmd_str = cmd_parts.join(' ')
        
        output = `#{cmd_str}`
        raise(VersionControlError, "Subversion command failed with exit code #{$?.exitstatus}") unless $?.success?
        return output if raw_result && !no_result
        return REXML::Document.new(output) unless no_result
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
  end
end
