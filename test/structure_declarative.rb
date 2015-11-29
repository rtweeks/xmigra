DECLARATIVE_DIR = Pathname('structure/declarative')

def add_foo_declarative
  DECLARATIVE_DIR.mkpath unless DECLARATIVE_DIR.exist?
  (decl_file = DECLARATIVE_DIR.join('foo.yaml')).open('w') do |f|
    f.print('--- !table
columns:
- name: id
  type: bigint
  primary key: true
  
- name: weapon
  type: varchar(32)
')
  end
  return decl_file
end

run_test "XMigra detects new declarative file" do
  in_xmigra_schema do
    add_foo_declarative
    
    tool = XMigra::SchemaUpdater.new('.')
    tool.load_plugin!
    assert("Migration chain incomplete") {tool.migrations.complete?}
    assert("Migration chain misses some migrations") {tool.migrations.includes_all?}
    assert_raises(XMigra::DeclarativeMigration::MissingImplementationError) do
      tool.update_sql
    end
  end
end

run_test "MigrationChain provides DeclarativeMigration::Missing for new file" do
  in_xmigra_schema do
    decl_file = add_foo_declarative
    
    tool = XMigra::SchemaUpdater.new('.')
    assert_eq(
      tool.migrations.path,
      Pathname('structure')
    )
    assert_eq(
      tool.migrations.path.join(XMigra::DeclarativeMigration::SUBDIR),
      Pathname('structure/declarative')
    )
    assert_eq(
      Dir.glob('structure/declarative/*.yaml'),
      ['structure/declarative/foo.yaml']
    )
    assert_include(
      tool.migrations.latest_declarative_implementations.keys,
      decl_file.expand_path
    )
    assert_eq(
      tool.migrations.latest_declarative_implementations[decl_file],
      XMigra::DeclarativeMigration::Missing
    )
  end
end

run_test "XMigra can create an implementing migration for creation" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    # tool = XMigra::ImpdeclMigrationAdder.new('.')
    # new_fpath = tool.add_migration_implementing_changes(decl_file)
    XMigra::Program.run(
      ['impdecl', '--no-edit', decl_file.to_s]
    )
  end
end

run_test "XMigra can create an implementing migration for adoption" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    XMigra::Program.run(
      ['impdecl', '--adopt', '--no-edit', decl_file.to_s]
    )
  end
end

run_test "Generated migration implementing adoption has no sql" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file, :adopt=>true)
    
    impdecl_data = YAML.load_file(new_fpath)
    assert {!impdecl_data.has_key? 'sql'}
  end
end

run_test "Adoption migrations are valid when generating upgrade" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    XMigra::Program.run(
      ['impdecl', '--adopt', '--no-edit', decl_file.to_s]
    )
    
    XMigra::Program.run(['upgrade'])
  end
end

run_test "XMigra does not allow renunciation for new declarative" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    assert_raises(XMigra::Program::ArgumentError) do
      XMigra::Program.run(
        ['impdecl', '--renounce', '--no-edit', decl_file.to_s]
      )
    end
  end
end

run_test "XMigra can build an upgrade script including an impdecl migration" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    tool = XMigra::SchemaUpdater.new('.')
    assert("SchemaUpdater does not know Git specifics") {tool.is_a? XMigra::GitSpecifics}
    assert("At least one migration does not know Git specifics") do
      tool.migrations.all? {|m| m.is_a? XMigra::GitSpecifics}
    end
    tool.update_sql
  end
end

run_test "XMigra can create an implementing migration for revision" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_data = YAML.load_file(decl_file)
    decl_data['columns'] << {
      'name'=>'caliber',
      'type'=>'float(53)',
    }
    decl_file.open('w') do |f|
      $xmigra_yamler.dump(decl_data, f)
    end
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath2 = tool.add_migration_implementing_changes(decl_file)
  end
end

run_test "XMigra does not allow adoption for revised declarative" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_data = YAML.load_file(decl_file)
    decl_data['columns'] << {
      'name'=>'caliber',
      'type'=>'float(53)',
    }
    decl_file.open('w') do |f|
      $xmigra_yamler.dump(decl_data, f)
    end
    
    assert_raises(XMigra::Program::ArgumentError) do
      XMigra::Program.run(
        ['impdecl', '--adopt', '--no-edit', decl_file.to_s]
      )
    end
  end
end

run_test "A declarative is only revised after an implementing migration" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    do_or_die %Q{git add "#{decl_file}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_data = YAML.load_file(decl_file)
    decl_data['columns'] << {
      'name'=>'caliber',
      'type'=>'float(53)',
    }
    decl_file.open('w') do |f|
      $xmigra_yamler.dump(decl_data, f)
    end
    
    XMigra::Program.run(
      ['impdecl', '--adopt', '--no-edit', decl_file.to_s]
    )
  end
end

run_test "XMigra does not allow renunciation for revised declarative" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_data = YAML.load_file(decl_file)
    decl_data['columns'] << {
      'name'=>'caliber',
      'type'=>'float(53)',
    }
    decl_file.open('w') do |f|
      $xmigra_yamler.dump(decl_data, f)
    end
    
    assert_raises(XMigra::Program::ArgumentError) do
      XMigra::Program.run(
        ['impdecl', '--renounce', '--no-edit', decl_file.to_s]
      )
    end
  end
end

run_test "XMigra can create an implementing migration for destruction" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_file.delete
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath2 = tool.add_migration_implementing_changes(decl_file)
  end
end

run_test "XMigra can create an implementing migration for renunciation" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_file.delete
    
    XMigra::Program.run(
      ['impdecl', '--renounce', '--no-edit', decl_file.to_s]
    )
  end
end

run_test "Generated migration implementing destruction has no sql" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_file.delete
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file, :renounce=>true)
    
    impdecl_data = YAML.load_file(new_fpath)
    assert {!impdecl_data.has_key? 'sql'}
  end
end

run_test "XMigra does not allow adoption for deleted declarative" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    tool = XMigra::ImpdeclMigrationAdder.new('.')
    new_fpath = tool.add_migration_implementing_changes(decl_file)
    
    impdecl_data = YAML.load_file(new_fpath)
    impdecl_data.delete(XMigra::DeclarativeMigration::QUALIFICATION_KEY)
    impdecl_data['sql'] = '
      CREATE TABLE foo (
        id BIGINT PRIMARY KEY,
        weapon VARCHAR(64)
      );
    '
    File.open(new_fpath, 'w') do |f|
      $xmigra_yamler.dump(impdecl_data, f)
    end
    
    do_or_die %Q{git add "#{decl_file}" "#{new_fpath}"}
    do_or_die %Q{git commit -m "Create foo table"}
    
    decl_file.delete
    
    assert_raises XMigra::Program::ArgumentError do
      XMigra::Program.run(
        ['impdecl', '--adopt', '--no-edit', decl_file.to_s]
      )
    end
  end
end
