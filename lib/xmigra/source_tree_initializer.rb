require 'pathname'
require 'xmigra/console_menu'
require 'xmigra/schema_manipulator'

module XMigra
  class SourceTreeInitializer
    class ConfigInfo
      def initialize(root_path)
        @root_path = Pathname(root_path)
        @dbinfo = {}
        @steps_after_dbinfo_creation = []
        @created_files = []
      end
      
      attr_reader :root_path, :dbinfo
      
      def created_files
        @created_files.dup
      end
      
      def created_file!(fpath)
        @created_files << Pathname(fpath)
      end
      
      def after_dbinfo_creation(&blk)
        @steps_after_dbinfo_creation << blk
      end
      
      def run_steps_after_dbinfo_creation!
        @steps_after_dbinfo_creation.each do |step|
          step.call
        end
      end
    end
    
    def initialize(root_path)
      @root_path = Pathname.new(root_path)
    end
    
    def dbinfo_path
      @root_path + SchemaManipulator::DBINFO_FILE
    end
    
    def get_user_input_block(input_type)
      puts "Input ends on a line containing nothing but a single '.'."
      "".tap do |result|
        while (line = $stdin.gets).strip != '.'
          result << line
        end
      end
    end
    
    def vcs_system
      @vcs_system ||= VersionControlSupportModules.find do |m|
        m.manages(@root_path)
      end
    end
    
    def create_files!
      schema_config = ConfigInfo.new(@root_path)
      
      if vcs_system.nil?
        puts "The indicated folder is not under version control.  Some features"
        puts "of this system require version control for full functionality.  If"
        puts "you later decide to use version control, you will need to configure"
        puts "it without assistance from this script."
        puts
        loop do
          print "Continue configuring schema management (y/N): "
          input_value = $stdin.gets.strip
          case input_value
          when /^y(es)?$/io then break
          when /^(n(o)?)?$/io then return
          end
        end
      end
      
      db_system = ConsoleMenu.new(
        "Supported Database Systems",
        DatabaseSupportModules,
        "Target system",
        :get_name => lambda {|m| m::SYSTEM_NAME}
      ).get_selection
      
      schema_config.dbinfo['system'] = db_system::SYSTEM_NAME
      if db_system.respond_to? :init_schema
        db_system.init_schema(schema_config)
      end
      
      if vcs_system.respond_to? :init_schema
        vcs_system.init_schema(schema_config)
      end
      
      puts "Enter a script comment.  This comment will be prepended to each"
      puts "generated script exactly as given here."
      script_comment = get_user_input_block('script comment').extend(LiteralYamlStyle)
      schema_config.dbinfo['script comment'] = script_comment if script_comment != ''
      
      schema_config.root_path.mkpath
      
      dbinfo_path.open('w') do |dbinfo_io|
        $xmigra_yamler.dump(schema_config.dbinfo, dbinfo_io)
      end
      schema_config.created_file! dbinfo_path
      
      schema_config.run_steps_after_dbinfo_creation!
      
      return schema_config.created_files
    end
  end
end
