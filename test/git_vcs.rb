#!/usr/bin/env ruby


GIT_PRESENT = begin
  `git --version` && $?.success?
rescue
  false
end

def initialize_git_repo(dir)
  Dir.chdir(dir) do
    do_or_die "git init", "Failed to initialize git repository"
    initialize_xmigra_schema
  end
end

def commit_all(msg)
  do_or_die "git add -A"
  do_or_die "git commit -m \"#{msg}\""
end

def commit_a_migration(desc_tail)
  XMigra::NewMigrationAdder.new('.').tap do |tool|
    tool.add_migration "Create #{desc_tail}"
  end
  commit_all "Added #{desc_tail}"
end

def get_migration_chain_head
  (Pathname('.') + XMigra::SchemaManipulator::STRUCTURE_SUBDIR + XMigra::MigrationChain::HEAD_FILE).open do |f|
    YAML.load(f)[XMigra::MigrationChain::LATEST_CHANGE]
  end
end

def make_this_branch_master
  open('.gitattributes', 'w') do |f|
    f.puts("%s %s=file://%s#%s" % [
      XMigra::SchemaManipulator::DBINFO_FILE,
      XMigra::GitSpecifics::MASTER_HEAD_ATTRIBUTE,
      Dir.pwd,
      `git rev-parse --abbrev-ref HEAD`.chomp
    ])
  end
  commit_all "Updated master database location"
end

if GIT_PRESENT
  run_test "Initialize a git repository" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
    end
  end
  
  run_test "XMigra recognizes git version control" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        tool = XMigra::SchemaManipulator.new('.')
        assert {tool.is_a? XMigra::MSSQLSpecifics}
      end
    end
  end
  
  run_test "XMigra can create a new migration" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        tool = XMigra::NewMigrationAdder.new('.')
        description = "Create the first table"
        fpath = tool.add_migration(description)
        assert_include fpath.to_s, description
      end
    end
  end
  
  run_test "XMigra can recognize a migration chain conflict" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        commit_a_migration "first table"
        do_or_die "git branch side"
        commit_a_migration "foo table"
        do_or_die "git checkout side 2>/dev/null"
        commit_a_migration "bar table"
        `git merge master` # This is not going to go well!
        
        XMigra::SchemaManipulator.new('.').tap do |tool|
          conflict = tool.get_conflict_info
          assert {not conflict.nil?}
        end
      end
    end
  end
  
  run_test "XMigra can fix a migration chain conflict" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        commit_a_migration "first table"
        do_or_die "git branch side"
        commit_a_migration "foo table"
        do_or_die "git checkout side 2>/dev/null"
        commit_a_migration "bar table"
        my_head = get_migration_chain_head
        `git merge master` # This is not going to go well!
        
        XMigra::SchemaManipulator.new('.').tap do |tool|
          conflict = tool.get_conflict_info
          assert {not conflict.nil?}
          conflict.fix_conflict!
          
          # Check that the merged migrations are at the end of the chain
          assert_neq get_migration_chain_head, my_head
        end
      end
    end
  end
  
  run_test "XMigra is aware of upstream branch relationship" do
    2.temp_dirs do |upstream, repo|
      initialize_git_repo(upstream)
      
      Dir.chdir(upstream) do
        commit_a_migration "first table"
      end
      
      `git clone "#{upstream}" "#{repo}" 2>/dev/null`
      
      Dir.chdir(upstream) do
        commit_a_migration "foo table"
      end
      
      Dir.chdir(repo) do
        commit_a_migration "bar table"
        
        # Get head migration
        downstream_head = get_migration_chain_head
        
        `git pull origin master 2>/dev/null`
        
        XMigra::SchemaManipulator.new('.').tap do |tool|
          conflict = tool.get_conflict_info
          assert {conflict}
          conflict.fix_conflict!
          
          # Check that head migration is still what it was (i.e.
          # merged migrations precede local branch migrations, preventing
          # modifications to upstream)
          assert_eq get_migration_chain_head, downstream_head
        end
      end
    end
  end
  
  run_test "XMigra will not generate a production script from a working tree that does not match the master branch" do
    2.temp_dirs do |upstream, repo|
      initialize_git_repo(upstream)
      
      Dir.chdir(upstream) do
        commit_a_migration "first table"
        make_this_branch_master
      end
      
      `git clone "#{upstream.expand_path}" "#{repo}" 2>/dev/null`
      
      Dir.chdir(upstream) do
        commit_a_migration "foo table"
      end
      
      Dir.chdir(repo) do
        commit_a_migration "bar table"
        
        XMigra::SchemaUpdater.new('.').tap do |tool|
          tool.production = true
          assert_neq(tool.branch_use, :production)
          assert_raises(XMigra::VersionControlError) {tool.update_sql}
        end
      end
    end
  end
  
  run_test "XMigra will generate a production script from an older commit from the master branch" do
    2.temp_dirs do |upstream, repo|
      initialize_git_repo(upstream)
      
      Dir.chdir(upstream) do
        commit_a_migration "first table"
        make_this_branch_master
      end
      
      `git clone "#{upstream.expand_path}" "#{repo}" 2>/dev/null`
      
      Dir.chdir(upstream) do
        commit_a_migration "foo table"
      end
      
      Dir.chdir(repo) do
        XMigra::SchemaUpdater.new('.').tap do |tool|
          tool.production = true
          assert_noraises {tool.update_sql}
        end
      end
    end
  end
  
  run_test "XMigra will generate a production script even if an access object's definition changes" do
    2.temp_dirs do |upstream, repo|
      initialize_git_repo(upstream)
      
      Dir.chdir(upstream) do
        commit_a_migration "first table"
        make_this_branch_master
        Dir.mkdir(XMigra::SchemaManipulator::ACCESS_SUBDIR)
        (Pathname(XMigra::SchemaManipulator::ACCESS_SUBDIR) + 'Bar.yaml').open('w') do |f|
          YAML.dump({'define'=>'stored procedure', 'sql'=>'definition goes here'}, f)
        end
        commit_all 'Defined Bar'
        (Pathname(XMigra::SchemaManipulator::ACCESS_SUBDIR) + 'Bar.yaml').open('w') do |f|
          YAML.dump({'define'=>'view', 'sql'=>'definition goes here'}, f)
        end
        commit_all 'Changed Bar to a view'
      end
      
      `git clone "#{upstream.expand_path}" "#{repo}" 2>/dev/null`
      
      Dir.chdir(upstream) do
        commit_a_migration "foo table"
      end
      
      Dir.chdir(repo) do
        XMigra::SchemaUpdater.new('.').tap do |tool|
          tool.production = true
          assert_noraises {tool.update_sql}
        end
      end
    end
  end
  
  run_test "XMigra detects extension of the production migration chain" do
    capture_chain_extension = Module.new do
      def production_chain_extended(*args)
        (@captured_call_args ||= []) << args
      end
      
      attr_reader :captured_call_args
    end
    
    2.temp_dirs do |upstream, repo|
      initialize_git_repo(upstream)
      
      Dir.chdir(upstream) do
        commit_a_migration "first table"
        make_this_branch_master
      end
      
      `git clone "#{upstream.expand_path}" "#{repo}" 2>/dev/null`
      
      Dir.chdir(repo) do
        XMigra::NewMigrationAdder.new('.') do |tool|
          tool.extend(capture_chain_extension)
          tool.add_migration('Create foo table')
          assert_eq tool.captured_call_args, [[]]
        end
      end
    end
  end
  
  run_test "XMigra does not put grants in upgrade by default" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        commit_a_migration "first table"
        File.open(XMigra::SchemaManipulator::PERMISSIONS_FILE, 'w') do |grants_file|
          YAML.dump(
            {
              "foo" => {
                "alice" => "ALL",
                "bob" => "SELECT",
                "candace" => ["INSERT", "SELECT", "UPDATE"],
              },
            }, 
            grants_file
          )
        end
        
        XMigra::SchemaUpdater.new('.').tap do |tool|
          sql = tool.update_sql
          assert_not_include sql, /GRANT\s+ALL.*?alice/
          assert_not_include sql, /GRANT\s+SELECT.*?bob/
          assert_not_include sql, /GRANT\s+INSERT.*?candace/
          assert_not_include sql, /GRANT\s+SELECT.*?candace/
          assert_not_include sql, /GRANT\s+UPDATE.*?candace/
        end
      end
    end
  end
  
  run_test "XMigra puts grants in upgrade when requested" do
    1.temp_dirs do |repo|
      initialize_git_repo(repo)
      
      Dir.chdir(repo) do
        commit_a_migration "first table"
        File.open(XMigra::SchemaManipulator::PERMISSIONS_FILE, 'w') do |grants_file|
          YAML.dump(
            {
              "foo" => {
                "alice" => "ALL",
                "bob" => "SELECT",
                "candace" => ["INSERT", "SELECT", "UPDATE"],
              },
            }, 
            grants_file
          )
        end
        
        XMigra::SchemaUpdater.new('.').tap do |tool|
          tool.include_grants = true
          
          sql = tool.update_sql
          assert_include sql, /GRANT\s+ALL.*?alice/
          assert_include sql, /GRANT\s+SELECT.*?bob/
          assert_include sql, /GRANT\s+INSERT.*?candace/
          assert_include sql, /GRANT.*?SELECT.*?candace/
          assert_include sql, /GRANT.*?UPDATE.*?candace/
        end
      end
    end
  end
end
