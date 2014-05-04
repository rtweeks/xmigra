
module XMigra
  class AccessArtifact
    def definition_sql
      [
        check_existence_sql(false, "%s existed before definition"),
        creation_notice,
        creation_sql + ";",
        check_existence_sql(true, "%s was not created by definition"),
        insert_access_creation_record_sql,
      ].compact.join(ddl_block_separator)
    end
    
    attr_accessor :file_path, :filename_metavariable
    
    def ddl_block_separator
      "\n"
    end
    
    def check_existence_sql(for_existence, error_message)
      nil
    end
    
    def creation_notice
      nil
    end
    
    def creation_sql
      if metavar = filename_metavariable
        @definition.gsub(metavar) {|m| self.name}
      else
        @definition
      end
    end
    
    def insert_access_creation_record_sql
      nil
    end
    
    def printable_type
      self.class.name.split('::').last.scan(/[A-Z]+[a-z]*/).collect {|p| p.downcase}.join(' ')
    end
  end
end
