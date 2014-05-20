
module XMigra
  class MigrationConflict
    def initialize(path, branch_point, heads)
      @path = Pathname.new(path)
      @branch_point = branch_point
      @heads = heads
      @branch_use = :undefined
      @scope = :repository
      @after_fix = nil
    end
    
    attr_accessor :branch_use, :scope, :after_fix
    
    def resolvable?
      head_0 = @heads[0]
      @heads[1].each_pair do |k, v|
        next unless head_0.has_key?(k)
        next if k == MigrationChain::LATEST_CHANGE
        return false unless head_0[k] == v
      end
      
      return true
    end
    
    def migration_tweak
      unless defined? @migration_to_fix and defined? @fixed_migration_contents
        # Walk the chain from @head[1][MigrationChain::LATEST_CHANGE] and find
        # the first migration after @branch_point
        branch_file = XMigra.yaml_path(@branch_point)
        cur_mig = XMigra.yaml_path(@heads[1][MigrationChain::LATEST_CHANGE])
        until cur_mig.nil?
          mig_info = YAML.load_file(@path.join(cur_mig))
          prev_mig = XMigra.yaml_path(mig_info[Migration::FOLLOWS])
          break if prev_mig == branch_file
          cur_mig = prev_mig
        end
        
        mig_info[Migration::FOLLOWS] = @heads[0][MigrationChain::LATEST_CHANGE]
        @migration_to_fix = cur_mig
        @fixed_migration_contents = mig_info
      end
      
      return @migration_to_fix, @fixed_migration_contents
    end
    
    def fix_conflict!
      raise(VersionControlError, "Unresolvable conflict") unless resolvable?
      
      file_to_fix, fixed_contents = migration_tweak
      
      # Rewrite the head file
      head_info = @heads[0].merge(@heads[1]) # This means @heads[1]'s LATEST_CHANGE wins
      File.open(@path.join(MigrationChain::HEAD_FILE), 'w') do |f|
        $xmigra_yamler.dump(head_info, f)
      end
      
      # Rewrite the first migration (on the current branch) after @branch_point
      File.open(@path.join(file_to_fix), 'w') do |f|
        $xmigra_yamler.dump(fixed_contents, f)
      end
      
      if @after_fix
        @after_fix.call
      end
    end
  end
end
