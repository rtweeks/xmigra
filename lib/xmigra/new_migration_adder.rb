
require 'xmigra/schema_manipulator'

module XMigra
  class NewMigrationAdder < SchemaManipulator
    OBSOLETE_VERINC_FILE = 'version-upgrade-obsolete.yaml'
    
    # Return this class (not an instance of it) from a Proc yielded by
    # each_possible_production_chain_extension_handler to continue through the
    # handler chain.
    class IgnoreHandler; end
    
    def initialize(path)
      super(path)
    end
    
    def add_migration(summary, options={})
      struct_dir = @path.join(STRUCTURE_SUBDIR)
      FileUtils.mkdir_p(struct_dir) unless struct_dir.exist?
      
      # Load the head YAML from the structure subdir if it exists or create
      # default empty migration chain
      head_file = struct_dir.join(MigrationChain::HEAD_FILE)
      head_info = if head_file.exist?
        YAML.parse_file(head_file).transform
      else
        {}
      end
      Hash === head_info or raise XMigra::Error, "Invalid #{MigrationChain::HEAD_FILE} format"
      
      if !head_info.empty? && respond_to?(:vcs_production_contents) && (production_head_contents = vcs_production_contents(head_file))
        production_head_info = YAML.load(production_head_contents)
        extending_production = head_info[MigrationChain::LATEST_CHANGE] == production_head_info[MigrationChain::LATEST_CHANGE]
      else
        extending_production = false
      end
      
      new_fpath = struct_dir.join(
        [Date.today.strftime("%Y-%m-%d"), summary].join(' ') + '.yaml'
      )
      raise(XMigra::Error, "Migration file\"#{new_fpath.basename}\" already exists") if new_fpath.exist?
      
      new_data = {
        Migration::FOLLOWS=>head_info.fetch(MigrationChain::LATEST_CHANGE, Migration::EMPTY_DB),
        'sql'=>options.fetch(:sql, "<<<<< INSERT SQL HERE >>>>>\n").dup.extend(LiteralYamlStyle),
        'description'=>options.fetch(:description, "<<<<< DESCRIPTION OF MIGRATION >>>>>").dup.extend(FoldedYamlStyle),
        Migration::CHANGES=>options.fetch(:changes, ["<<<<< WHAT THIS MIGRATION CHANGES >>>>>"]),
      }
      
      # Write the head file first, in case a lock is required
      old_head_info = head_info.dup
      head_info[MigrationChain::LATEST_CHANGE] = new_fpath.basename('.yaml').to_s
      File.open(head_file, "w") do |f|
        $xmigra_yamler.dump(head_info, f)
      end
      
      begin
        File.open(new_fpath, "w") do |f|
          $xmigra_yamler.dump(new_data, f)
        end
      rescue
        # Revert the head file to it's previous state
        File.open(head_file, "w") do |f|
          $xmigra_yamler.dump(old_head_info, f)
        end
        
        raise
      end
      
      # Obsolete any existing branch upgrade file
      bufp = branch_upgrade_file
      if bufp.exist?
        warning("#{bufp.relative_path_from(@path)} is obsolete and will be renamed.") if respond_to? :warning
        
        obufp = bufp.dirname.join(OBSOLETE_VERINC_FILE)
        rm_method = respond_to?(:vcs_remove) ? method(:vcs_remove) : FileUtils.method(:rm)
        mv_method = respond_to?(:vcs_move) ? method(:vcs_move) : FileUtils.method(:mv)
        
        rm_method.call(obufp) if obufp.exist?
        mv_method.call(bufp, obufp)
      end
      
      production_chain_extended if extending_production
      
      return new_fpath
    end
    
    # Called when the chain of migrations in the production/master branch is
    # extended with a new migration.
    #
    # This method calls each_possible_production_chain_extension_handler to
    # generate a chain of handlers.
    #
    def production_chain_extended
      Dir.chdir(self.path) do
        each_possible_production_chain_extension_handler do |handler|
          if handler.kind_of? Proc
            handler_result = handler[]
            break true unless handler_result == IgnoreHandler
          else
            handler_result = system(handler)
            break true unless handler_result.nil?
          end
        end
      end
    end
    
    # Yield command strings or Proc instances to attempt handling the
    # production-chain-extension event
    #
    # Strings yielded by this method will be executed using Kernel#system.  If
    # this results in `nil` (command does not exist), processing will continue
    # through the remaining handlers.
    #
    # Procs yielded by this method will be executed without any parameters.
    # Unless the invocation returns IgnoreHandler, event processing will
    # terminate after invocation.
    #
    def each_possible_production_chain_extension_handler
      yield "on-prod-chain-extended-local"
      if respond_to?(:vcs_prod_chain_extension_handler) && (vcs_handler = vcs_prod_chain_extension_handler)
        yield vcs_handler.to_s
      end
      yield "on-prod-chain-extended"
      yield Proc.new {
        next unless respond_to? :warning
        warning(<<END_MESSAGE)
This command has extended the production migration chain.

Backing up your development database now may be advantageous in case you need
to accept migrations developed in parallel from upstream before merging your
work back to the mainline.
END_MESSAGE
      }
    end
  end
end
