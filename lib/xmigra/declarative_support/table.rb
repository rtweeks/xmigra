require 'xmigra/declarative_support'

module XMigra
  module DeclarativeSupport
    class Table
      include ImpdeclMigrationAdder::SupportedDatabaseObject
      for_declarative_tagged "!table"
      
      class Column
        SPEC_ATTRS = [:name, :type]
        
        def initialize(col_spec)
          @primary_key = !!col_spec['primary key']
          SPEC_ATTRS.each do |a|
            instance_variable_set("@#{a}".to_sym, col_spec[a.to_s])
          end
        end
        
        attr_accessor *SPEC_ATTRS
        
        def primary_key?
          @primary_key
        end
        def primary_key=
          @primary_key
        end
      end
      
      class Constraint
        SUBTYPES = []
        def self.inherited(subclass)
          SUBTYPES << subclass
        end
        
        def self.each_type(&blk)
          SUBTYPES.each(&blk)
        end
        
        def self.type_by_identifier(identifier)
          SUBTYPES.find {|t| t.const_defined?(:IDENTIFIER) && t::IDENTIFIER == identifier}
        end
        
        def self.bad_spec(message)
          raise SpecificationError, message
        end
        
        def self.deserialize(name, constr_spec)
          constraint_type = constr_spec['type'] || implicit_type(name) || bad_spec(
            "No type specified (or inferrable) for constraint #{name}"
          )
          constraint_type = Constraint.type_by_identifier(constraint_type) || bad_spec(
            %Q{Unknown constraint type "#{constraint_type}" for constraint #{name}}
          )
          
          constraint_type.new(name, constr_spec)
        end
        
        def self.implicit_type(name)
          return if name.nil?
          Constraint.each_type.find do |type|
            next unless type.const_defined?(:IMPLICIT_PREFIX)
            break type::IDENTIFIER if name.start_with?(type::IMPLICIT_PREFIX)
          end
        end
        
        def constraint_type
          self.class::IDENTIFIER.gsub(' ', '_').to_sym
        end
        
        def initialize(name, constr_spec)
          @name = name
        end
        
        attr_accessor :name
        
        protected
        def creation_name_sql
          return "" if name.nil?
          "CONSTRAINT #{name} "
        end
      end
      
      class ColumnListConstraint < Constraint
        def initialize(name, constr_spec)
          super(name, constr_spec)
          @columns = get_and_validate_columns(constr_spec)
        end
        
        attr_reader :columns
        
        def constrained_colnames
          columns
        end
        
        protected
        def get_and_validate_columns(constr_spec)
          (constr_spec.array_fetch('columns', ->(c) {c['name']}) || Constraint.bad_spec(
            %Q{#{self.class::IDENTIFIER} constraint #{name} must specify columns}
          )).tap do |cols|
            unless cols.kind_of? Array
              Constraint.bad_spec(
                %Q{#{self.class::IDENTIFIER} constraint #{@name} expected "columns" to be a sequence (Array)}
              )
            end
            if cols.uniq.length < cols.length
              Constraint.bad_spec(
                %Q{#{self.class::IDENTIFIER} constraint #{@name} has one or more duplicate columns}
              )
            end
          end
        end
      end
      
      class PrimaryKey < ColumnListConstraint
        IDENTIFIER = "primary key"
        IMPLICIT_PREFIX = "PK_"
        
        def creation_sql
          creation_name_sql + "PRIMARY KEY (#{constrained_colnames.join(', ')})"
        end
      end
      
      class UniquenessConstraint < ColumnListConstraint
        IDENTIFIER = "unique"
        IMPLICIT_PREFIX = "UQ_"
        
        def creation_sql
          creation_name_sql + "UNIQUE (#{constrained_colnames.join(', ')})"
        end
      end
      
      class ForeignKey < ColumnListConstraint
        IDENTIFIER = "foreign key"
        IMPLICIT_PREFIX = "FK_"
        
        def initialize(name, constr_spec)
          super(name, constr_spec)
          @referent = constr_spec['link to'] || Constraint.bad_spec(
            %Q{Foreign key constraint #{@name} does not specify "link to" (referent)}
          )
          @update_rule = constr_spec['on update'].tap {|v| break v.upcase if v}
          @delete_rule = constr_spec['on delete'].tap {|v| break v.upcase if v}
        end
        
        attr_accessor :referent, :update_rule, :delete_rule
        
        def constrained_colnames
          columns.keys
        end
        
        def referenced_colnames
          columns.values
        end
        
        def creation_sql
          "".tap do |result|
            result << creation_name_sql
            result << "FOREIGN KEY (#{constrained_colnames.join(', ')})"
            result << "\n    REFERENCES #{referent} (#{referenced_colnames.join(', ')})"
            if update_rule
              result << "\n    ON UPDATE #{update_rule}"
            end
            if delete_rule
              result << "\n    ON DELETE #{delete_rule}"
            end
          end
        end
        
        protected
        def get_and_validate_columns(constr_spec)
          (constr_spec.raw_item('columns') || Constraint.bad_spec(
            %Q{#{self.class::IDENTIFIER} constraint #{name} must specify columns}
          )).tap do |cols|
            unless cols.kind_of? Hash
              Constraint.bad_spec(
                %Q{Foreign key constraint #{@name} expected "columns" to be a mapping (Hash) referrer -> referent}
              )
            end
          end
        end
      end
      
      class CheckConstraint < Constraint
        IDENTIFIER = 'check'
        IMPLICIT_PREFIX = 'CK_'
        
        def initialize(name, constr_spec)
          super(name, constr_spec)
          @expression = constr_spec['verify'] || Constraint.bad_spec(
            %Q{Check constraint #{name} does not specify an expression to "verify"}
          )
        end
        
        attr_accessor :expression
        
        def creation_sql
          creation_name_sql + "CHECK (#{expression})"
        end
      end
      
      def initialize(name, structure)
        structure = StructureReader.new(structure)
        @name = name
        @columns_by_name = (structure.array_fetch('columns', ->(c) {c['name']}) || raise(
          SpecificationError,
          "No columns specified for table #{@name}"
        )).inject({}) do |result, item|
          column = Column.new(item)
          result[column.name] = column
          result
        end
        constraints = {}
        @primary_key = columns.select(&:primary_key?).tap do |cols|
          break nil if cols.empty?
          pk = PrimaryKey.new("PK_#{name.gsub('.', '_')}", {'columns'=>cols})
          break (constraints[pk.name] = pk)
        end
        @constraints = (structure['constraints'] || []).inject(constraints) do |result, name_spec_pair|
          constraint = Constraint.deserialize(*name_spec_pair)
          result[constraint.name] = constraint
          result
        end
        errors = []
        @constraints.each_value do |constraint|
          if constraint.kind_of? PrimaryKey
            if @primary_key && (!@primary_key.name.nil? || @primary_key.columns != constraint.columns)
              raise SpecificationError, "Multiple primary keys specified"
            end
            @primary_key = constraint
          end
          unknown_cols = constraint.constrained_colnames.reject do |colname|
            has_column?(colname)
          end
          unless unknown_cols.empty?
            errors << "#{constraint.class::IDENTIFIER} constraint #{constraint.name} references unknown column(s): #{unknown_cols.join(', ')}"
          end
        end
        
        structure.each_unused_standard_key do |k|
          errors << "Unrecognized standard key #{k.join('.')}"
        end
        
        unless errors.empty?
          raise SpecificationError, errors.join("\n")
        end
        
        @extensions = structure.each_extension.inject({}) do |result, kv_pair|
          key, value = kv_pair
          result[key] = value
          result
        end
      end
      
      attr_accessor :name
      attr_reader :constraints, :extensions
      
      def columns
        @columns_by_name.values
      end
      
      def get_column(name)
        @columns_by_name[name]
      end
      
      def has_column?(name)
        @columns_by_name.has_key? name
      end
      
      def creation_sql
        table_items = []
        table_items.concat(columns.map {|col| "#{col.name} #{col.type}"})
        table_items.concat(constraints.values.map(&:creation_sql))
        
        "CREATE TABLE #{name} (\n" + \
        table_items.map {|item| "  #{item}"}.join(",\n") + "\n" + \
        ");"
      end
      
      def sql_to_effect_from(old_state)
        parts = []
        
        # Look for changes to any constraint (adding constraints waits until columns added)
        constraints_to_drop = []
        new_constraint_sql_clauses = []
        old_constraint_sql = old_state.constraints.each_value.inject({}) do |result, constr|
          if constraints.has_key? constr.name
            result[constr.name] = constr.creation_sql
          else
            constraints_to_drop << constr.name
          end
          result
        end
        constraints.each_value do |constr|
          if old_constraint_sql.has_key? constr.name
            if old_constraint_sql[constr.name] != (crt_sql = constr.creation_sql)
              constraints_to_drop << constr.name
              new_constraint_sql_clauses << crt_sql
              parts << "ALTER TABLE #{name} ADD #{crt_sql};"
            end
          else
            new_constraint_sql_clauses << constr.creation_sql
          end
        end
        parts.concat remove_table_constraints_sql_statements(
          constraints_to_drop
        )
        
        # Look for new and altered columns
        new_columns = []
        altered_columns = []
        columns.each do |col|
          if !old_state.has_column? col.name
            new_columns << col
          elsif old_state.get_column(col.name).type != col.type
            altered_columns << col
          end
        end
        parts.concat add_table_columns_sql_statements(
          new_columns.lazy.map {|col| [col.name, col.type]}
        ).to_a
        
        # Look for altered columns
        parts.concat alter_table_columns_sql_statements(
          altered_columns.lazy.map {|col| [col.name, col.type]}
        ).to_a
        
        # Look for removed columns
        removed_columns = old_state.columns.reject {|col| has_column? col.name}
        parts.concat remove_table_columns_sql_statements(
          removed_columns.lazy.map(&:name)
        ).to_a
        
        # After new columns are added, add constraints
        parts.concat add_table_constraints_sql_statements(
          new_constraint_sql_clauses
        ).to_a
        
        (extensions.keys + old_state.extensions.keys).uniq.sort.each do |ext_key|
          case 
          when extensions.has_key?(ext_key) && !old_state.extensions.has_key?(ext_key)
            parts << "-- TODO: New extension #{ext_key}"
          when old_state.extensions.has_key?(ext_key) && !extensions.has_key?(ext_key)
            parts << "-- TODO: Extension #{ext_key} removed"
          else
            parts << "-- TODO: Modification to extension #{ext_key}"
          end
        end
        
        return parts.join("\n")
      end
      
      def remove_table_constraints_sql_statements(constraint_names)
        constraint_names.map do |constr|
          "ALTER TABLE #{name} DROP CONSTRAINT #{constr};"
        end
      end
      
      def add_table_columns_sql_statements(column_name_type_pairs)
        column_name_type_pairs.map do |col_name, col_type|
          "ALTER TABLE #{name} ADD COLUMN #{col_name} #{col_type};"
        end
      end
      
      def alter_table_columns_sql_statements(column_name_type_pairs)
        raise(NotImplementedError, "SQL 92 does not provide a standard way to alter a column's type") unless column_name_type_pairs.empty?
      end
      
      def remove_table_columns_sql_statements(column_names)
        column_names.map do |col_name|
          "ALTER TABLE #{name} DROP COLUMN #{col_name};"
        end
      end
      
      def add_table_constraints_sql_statements(constraint_def_clauses)
        constraint_def_clauses.map do |create_clause|
          "ALTER TABLE #{name} ADD #{create_clause};"
        end
      end
      
      def destruction_sql
        "DROP TABLE #{name};"
      end
    end
  end
end
