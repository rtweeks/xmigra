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

def commit_a_migration(desc_tail)
  XMigra::NewMigrationAdder.new('.').tap do |tool|
    tool.add_migration "Create #{desc_tail}"
  end
  do_or_die "git add -A"
  do_or_die "git commit -m \"Added #{desc_tail}\""
end

def get_migration_chain_head
  (Pathname('.') + XMigra::SchemaManipulator::STRUCTURE_SUBDIR + XMigra::MigrationChain::HEAD_FILE).open do |f|
    YAML.load(f)[XMigra::MigrationChain::LATEST_CHANGE]
  end
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
end
