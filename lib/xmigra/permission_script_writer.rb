
require 'xmigra/schema_manipulator'

module XMigra
  class PermissionScriptWriter < SchemaManipulator
    def initialize(path)
      super(path)
      
      @permissions = YAML.load_file(self.path + PERMISSIONS_FILE)
      raise TypeError, "Expected Hash in #{PERMISSIONS_FILE}" unless Hash === @permissions
    end
    
    def in_ddl_transaction
      yield
    end
    
    def ddl_block_separator; "\n"; end
    
    def permissions_sql
      intro_comment = @db_info.fetch('script comment', '') + "\n\n"
      
      intro_comment + in_ddl_transaction do
        [
          # Check for blatantly incorrect application of script, e.g. running
          # on master or template database.
          check_execution_environment_sql,
          
          # Create table for recording granted permissions if it doesn't exist
          ensure_permissions_table_sql,
          
          # Revoke permissions previously granted through an XMigra permissions
          # script
          revoke_previous_permissions_sql,
          
          # Grant the permissions indicated in the source file
          grant_specified_permissions_sql,
          
        ].flatten.compact.join(ddl_block_separator)
      end
    end
    
    def grant_specified_permissions_sql
      granting_permissions_comment_sql +
        enum_for(:each_specified_grant).map(&method(:grant_permissions_sql)).join("\n")
    end
    
    def each_specified_grant
      @permissions.each_pair do |object, grants|
        grants.each_pair do |principal, permissions|
          permissions = [permissions] unless permissions.is_a? Enumerable
          yield permissions, object, principal
        end
      end
    end
    
    def line_comment(contents)
      "-- " + contents + " --\n"
    end
    
    def header(content, size)
      dashes = size - content.length - 2
      l_dashes = dashes / 2
      r_dashes = dashes - l_dashes
      ('-' * l_dashes) + ' ' + content + ' ' + ('-' * r_dashes)
    end
  end
end
