DECLARATIVE_DIR = Pathname('structure/declarative')

def add_foo_declarative(object_tag = '!table', options={})
  DECLARATIVE_DIR.mkpath unless DECLARATIVE_DIR.exist?
  (decl_file = DECLARATIVE_DIR.join('foo.yaml')).open('w') do |f|
    f.print("--- #{object_tag}
columns:
- name: id
  type: bigint
  primary key: true
  #{options[:id_extra_info].to_s.lines.join("\n  ")}
  
- name: weapon
  type: varchar(32)
  #{options[:weapon_extra_info].to_s.lines.join("\n  ")}
")
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

run_test "XMigra detects mismatched implementing migration and declarative" do
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
    tool.add_migration_implementing_changes(decl_file)
    
    decl_data = YAML.load_file(decl_file)
    decl_data['columns'] << {
      'name'=>'dweomer',
      'type'=>'text',
    }
    decl_file.open('w') do |f|
      $xmigra_yamler.dump(decl_data, f)
    end
    
    tool = XMigra::SchemaUpdater.new('.')
    assert_raises XMigra::DeclarativeMigration::MissingImplementationError do
      tool.update_sql
    end
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

class ImpdeclSupportMockFactory
  def initialize
    @instances = []
  end
  
  attr_reader :instances
  
  class Instance
    include XMigra::ImpdeclMigrationAdder::SupportedDatabaseObject
    
    def initialize(name, declared_structure)
      @name = name
      @declared_structure = declared_structure
      
      @creation_calls = []
      @revision_calls = []
      @destruction_calls = []
    end
    
    attr_reader :name, :declared_structure
    attr_reader :creation_calls, :revision_calls, :destruction_calls
    
    def creation_sql(*args)
      @creation_calls << args
      method :check_execution_environment_sql
      return nil
    end
    
    def sql_to_effect_from(*args)
      @revision_calls << args
      method :check_execution_environment_sql
      return nil
    end
    
    def destruction_sql(*args)
      @destruction_calls << args
      method :check_execution_environment_sql
      return nil
    end
  end
  
  def new(name, declared_structure)
    Instance.new(name, declared_structure).tap do |instance|
      @instances << instance
    end
  end
end

def has_dbspecifics(o)
  XMigra::DatabaseSupportModules.find {|m| o.kind_of? m}
end

run_test "XMigra uses an associated handler to generate construction SQL" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    test_tag = "!test_tag_value"
    decl_file = add_foo_declarative(test_tag)
    
    support_mock_factory = ImpdeclSupportMockFactory.new
    XMigra::ImpdeclMigrationAdder.register_support_type(
      test_tag,
      support_mock_factory
    ) do
      tool = XMigra::ImpdeclMigrationAdder.new('.')
      tool.strict = true
      assert {has_dbspecifics(tool)}
      assert_include(
        XMigra::DatabaseSupportModules,
        tool.instance_variable_get(:@db_specifics)
      )
      assert {!tool.instance_variable_get(:@db_specifics).nil?}
      tool.add_migration_implementing_changes(decl_file)
    end
    
    # Check that using XMigra::ImpdeclMigrationAdder#register_support_type with
    # a block does not polute the support type mapping outside the block
    assert {XMigra::ImpdeclMigrationAdder.support_type(test_tag).nil?}
    
    # support_mock_factory should have created exactly 1 instance
    assert_eq(support_mock_factory.instances.length, 1)
    sql_factory = support_mock_factory.instances[0]
    
    
    assert {sql_factory.instance_of? ImpdeclSupportMockFactory::Instance}
    assert_eq(sql_factory.name, 'foo')
    assert {sql_factory.declared_structure.kind_of? Hash}
    assert_eq(sql_factory.creation_calls, [[]])
    assert_eq(sql_factory.revision_calls, [])
    assert_eq(sql_factory.destruction_calls, [])
    assert {has_dbspecifics(sql_factory)}
  end
end

run_test "XMigra uses an associated handler to generate revision SQL" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    test_tag = "!test_tag_value"
    decl_file = add_foo_declarative(test_tag)
    
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
    
    decl_tree = YAML.parse_stream(decl_file.read)
    columns_seq = decl_tree.children[0].children[0].children[1]
    columns_seq.children << YAML.parse(YAML.dump({
      'name'=>'caliber',
      'type'=>'float(53)',
    })).children[0]
    decl_file.open('w') do |f|
      f.write(decl_tree.to_yaml)
    end
    
    support_mock_factory = ImpdeclSupportMockFactory.new
    XMigra::ImpdeclMigrationAdder.register_support_type(
      test_tag,
      support_mock_factory
    ) do
      tool = XMigra::ImpdeclMigrationAdder.new('.')
      tool.strict = true
      tool.add_migration_implementing_changes(decl_file)
    end
    
    assert_eq(support_mock_factory.instances.length, 2)
    old_state, sql_factory = support_mock_factory.instances
    [:creation_calls, :revision_calls, :destruction_calls].each do |mname|
      assert_eq(old_state.send(mname), [])
    end
    assert_eq(sql_factory.creation_calls, [])
    assert_eq(sql_factory.revision_calls, [[old_state]])
    assert_eq(sql_factory.destruction_calls, [])
  end
end

run_test "XMigra uses an associated handler to generate destruction SQL" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    test_tag = "!test_tag_value"
    decl_file = add_foo_declarative(test_tag)
    
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
    
    support_mock_factory = ImpdeclSupportMockFactory.new
    XMigra::ImpdeclMigrationAdder.register_support_type(
      test_tag,
      support_mock_factory
    ) do
      tool = XMigra::ImpdeclMigrationAdder.new('.')
      tool.strict = true
      tool.add_migration_implementing_changes(decl_file)
    end
    
    assert_eq(support_mock_factory.instances.length, 1)
    sql_factory = support_mock_factory.instances[0]
    assert_eq(sql_factory.creation_calls, [])
    assert_eq(sql_factory.revision_calls, [])
    assert_eq(sql_factory.destruction_calls, [[]])
  end
end

run_test "DeclarativeSupport::Table can create tables with \"NOT NULL\" columns" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative("!table")
    
    deserializer = XMigra::ImpdeclMigrationAdder::SupportedObjectDeserializer.new(decl_file.basename('.yaml').to_s, XMigra::NoSpecifics)
    table_yaml = YAML.parse_file(decl_file)
    table = deserializer.deserialize(table_yaml.children[0])
    table.get_column('weapon').nullable = false
    
    assert('weapon column did not have "NOT NULL"') do
      table.table_creation_items.any? do |i|
        next unless i.kind_of?(XMigra::DeclarativeSupport::Table::ColumnCreationFragment)
        next unless i.column.name == 'weapon'
        next unless i.creation_sql =~ /NOT\s+NULL/
        true
      end
    end
  end
end

run_test "DeclarativeSupport::Table can add or remove \"NOT NULL\" from columns" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    deserializer = XMigra::ImpdeclMigrationAdder::SupportedObjectDeserializer.new(decl_file.basename('.yaml').to_s, XMigra::PgSQLSpecifics)
    table_yaml = YAML.parse_file(decl_file)
    table_null = deserializer.deserialize(table_yaml.children[0])
    table_notnull = deserializer.deserialize(table_yaml.children[0])
    table_notnull.get_column('weapon').nullable = false
    
    delta = XMigra::DeclarativeSupport::Table::Delta.new(table_null, table_notnull)
    assert_eq(delta.constraints_to_drop, [])
    assert_eq(delta.new_columns, [])
    assert_eq(delta.removed_columns, [])
    assert_eq(delta.new_constraint_sql_clauses, [])
    assert_eq(delta.altered_column_pairs.length, 1)
    stmts = table_notnull.alter_table_columns_sql_statements(delta.altered_column_pairs)
    assert_eq(stmts.length, 1)
    assert_eq(stmts[0].gsub(/\s+/, ' ').upcase, "ALTER TABLE FOO ALTER COLUMN WEAPON SET NOT NULL;")
    
    delta = XMigra::DeclarativeSupport::Table::Delta.new(table_notnull, table_null)
    assert_eq(delta.constraints_to_drop, [])
    assert_eq(delta.new_columns, [])
    assert_eq(delta.removed_columns, [])
    assert_eq(delta.new_constraint_sql_clauses, [])
    assert_eq(delta.altered_column_pairs.length, 1)
    stmts = table_null.alter_table_columns_sql_statements(delta.altered_column_pairs)
    assert_eq(stmts.length, 1)
    assert_eq(stmts[0].gsub(/\s+/, ' ').upcase, "ALTER TABLE FOO ALTER COLUMN WEAPON DROP NOT NULL;")
  end
end

run_test "DeclarativeSupport::Table can create tables including columns with defaults" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    deserializer = XMigra::ImpdeclMigrationAdder::SupportedObjectDeserializer.new(decl_file.basename('.yaml').to_s, XMigra::NoSpecifics)
    table_yaml = YAML.parse_file(decl_file)
    table = deserializer.deserialize(table_yaml.children[0])
    table.add_default('weapon', "'knife'")
    
    assert('weapon column does not have default') do
      table.table_creation_items.any? do |i|
        next unless i.kind_of?(XMigra::DeclarativeSupport::Table::ColumnCreationFragment)
        next unless i.column.name == 'weapon'
        next unless i.creation_sql =~ /DEFAULT\s+'knife'/
        true
      end
    end
    assert('default rendered as table constraint during table creation') do
      !table.table_creation_items.any? do |i|
        i.kind_of?(XMigra::DeclarativeSupport::Table::DefaultConstraint)
      end
    end
  end
end

run_test "DeclarativeSupport::Table can add default constraints to or remove them from columns" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    deserializer = XMigra::ImpdeclMigrationAdder::SupportedObjectDeserializer.new(decl_file.basename('.yaml').to_s, XMigra::PgSQLSpecifics)
    table_yaml = YAML.parse_file(decl_file)
    table_notdefaulted = deserializer.deserialize(table_yaml.children[0])
    table_defaulted = deserializer.deserialize(table_yaml.children[0])
    table_defaulted.add_default('weapon', "'knife'")
    
    delta = XMigra::DeclarativeSupport::Table::Delta.new(table_notdefaulted, table_defaulted)
    assert_eq(delta.new_columns, [])
    assert_eq(delta.altered_column_pairs, [])
    assert_eq(delta.removed_columns, [])
    assert_eq(delta.constraints_to_drop, [])
    assert_eq(delta.new_constraint_sql_clauses.length, 1)
    assert_eq(
      delta.new_constraint_sql_clauses[0].gsub(/\s+/, ' ').upcase,
      "CONSTRAINT DF_WEAPON DEFAULT 'KNIFE' FOR WEAPON"
    )
    
    delta = XMigra::DeclarativeSupport::Table::Delta.new(table_defaulted, table_notdefaulted)
    assert_eq(delta.new_columns, [])
    assert_eq(delta.altered_column_pairs, [])
    assert_eq(delta.removed_columns, [])
    assert_eq(delta.new_constraint_sql_clauses, [])
    assert_eq(delta.constraints_to_drop.length, 1)
    assert_eq(delta.constraints_to_drop[0], "DF_weapon")
  end
end

run_test "DeclarativeSupport::Table can alter an existing default constraint on a column" do
  in_xmigra_schema do
    do_or_die "git init", "Unable to initialize git repository"
    decl_file = add_foo_declarative
    
    deserializer = XMigra::ImpdeclMigrationAdder::SupportedObjectDeserializer.new(decl_file.basename('.yaml').to_s, XMigra::PgSQLSpecifics)
    table_yaml = YAML.parse_file(decl_file)
    table_old = deserializer.deserialize(table_yaml.children[0])
    table_old.add_default('weapon', "'knife'")
    table_new = deserializer.deserialize(table_yaml.children[0])
    table_new.add_default('weapon', "'rock'")
    
    delta = XMigra::DeclarativeSupport::Table::Delta.new(table_old, table_new)
    assert_eq(delta.new_columns, [])
    assert_eq(delta.altered_column_pairs, [])
    assert_eq(delta.removed_columns, [])
    assert_eq(delta.constraints_to_drop.length, 1)
    assert_eq(delta.constraints_to_drop[0], "DF_weapon")
    assert_eq(delta.new_constraint_sql_clauses.length, 1)
    assert_eq(
      delta.new_constraint_sql_clauses[0].gsub(/\s+/, ' ').upcase,
      "CONSTRAINT DF_WEAPON DEFAULT 'ROCK' FOR WEAPON"
    )
  end
end