require 'fileutils'
require 'ostruct'
require 'pathname'
require 'stringio'
require 'tmpdir'

class Integer
  def temp_dirs(prefix='')
    tmpdirs = []
    begin
      (1..self).each do |i|
        tmpdirs << Pathname(Dir.mktmpdir([prefix, ".#{i}"]))
      end
      
      yield(*tmpdirs)
    ensure
      tmpdirs.each do |dp|
        begin
          FileUtils.remove_entry dp
        rescue
          # Skip failure
        end
      end
    end
  end
end

def do_or_die(command, message=nil, exc_type=Exception)
  output = `#{command}`
  $?.success? || raise(exc_type, message || ("Unable to " + command + "\n" + output))
end

def initialize_xmigra_schema(path='.', options={})
  (Pathname(path) + XMigra::SchemaManipulator::DBINFO_FILE).open('w') do |f|
    YAML.dump({
      'system' => $xmigra_test_system,
    }.merge(options[:db_info] || {}), f)
  end
end

def in_xmigra_schema
  1.temp_dirs do |schema|
    Dir.chdir(schema) do
      initialize_xmigra_schema
      yield
    end
  end
end

def add_migration(migration_name, reversion_sql=nil)
  tool = XMigra::NewMigrationAdder.new('.')
  mig_path = tool.add_migration migration_name
  mig_chain = XMigra::MigrationChain.new('structure')
  migration = mig_chain[-1]
  unless reversion_sql.nil?
    class <<migration
      def reversion_tracking_sql
        '-- TRACK REVERSION OF MIGRATION --'
      end
    end
    rev_file = XMigra::RevertFile.new(migration)
    rev_file.path.dirname.mkpath
    rev_file.path.open('w') do |rev_stream|
      rev_stream.puts reversion_sql
    end
  end
  return migration
end

def capture_stdout
  old_stdout, $stdout = $stdout, StringIO.new
  begin
    yield
    return $stdout.string
  ensure
    $stdout = old_stdout
  end
end
