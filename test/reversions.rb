
def add_migration_reversion_pair(migration_name, reversion_sql)
  return [add_migration(migration_name, reversion_sql), reversion_sql]
end

run_test "Generate upgrade with no reversions" do
  in_xmigra_schema do
    XMigra::NewMigrationAdder.new('.').tap do |tool|
      tool.add_migration "Create foo table"
    end
    XMigra::Program.run(['upgrade', '--outfile=/dev/null'])
  end
end

run_test "Generate reversions script with no reversions" do
  in_xmigra_schema do
    XMigra::NewMigrationAdder.new('.').tap do |tool|
      tool.add_migration "Create foo table"
    end
    XMigra::Program.run(['reversions', '--outfile=/dev/null'])
  end
end

run_test "Migration reversion contains SQL in reversion file" do
  in_xmigra_schema do
    reversion_sql = "DROP TABLE foo;"
    migration = add_migration("Create foo table", reversion_sql)
    assert("Reversion commands did not contain expected SQL") {
      migration.reversion.to_s.include? reversion_sql
    }
  end
end

run_test "Generated revisions script for one migration" do
  in_xmigra_schema do
    reversion_sql = "DROP TABLE foo;"
    migration = add_migration("Create foo table", reversion_sql)
    assert("Reversions script did not contain reversion SQL") {
      XMigra::Program.run(['reversions'])
      test_output.include? reversion_sql
    }
  end
end

run_test "Generated revisions script for one migration removes application record" do
  in_xmigra_schema do
    reversion_sql = "DROP TABLE foo;"
    migration = add_migration("Create foo table", reversion_sql)
    assert("Reversions script does not remove migration application record") {
      XMigra::Program.run(['reversions'])
      script = test_output
      script =~ /DELETE\s+FROM\s+.?xmigra.?\..?applied.?\s+WHERE\s+.?MigrationID.?\s*=\s*'#{Regexp.escape migration.id}'\s*;/
    }
  end
end

run_test "Generate reversions script for two migrations" do
  in_xmigra_schema do
    migrations = []
    migrations << add_migration_reversion_pair("Create foo table", "DROP TABLE foo;")
    migrations << add_migration_reversion_pair("Add bar column to foo table", "ALTER TABLE foo DROP bar;")
    assert("ALTER TABLE appeared after DROP TABLE") {
      XMigra::Program.run(['reversions'])
      script = test_output
      (script =~ /ALTER\s+TABLE/) < (script =~ /DROP\s+TABLE/)
    }
  end
end
