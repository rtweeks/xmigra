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
          SUBTYPES.find {|t| t::IDENTIFIER == identifier}
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
        
        def initialize(name, constr_spec)
          @name = name
          @columns = constr_spec['columns'] || Constraint.bad_spec(
            %Q{#{self.class::IDENTIFIER} constraint #{@name} must specify columns}
          )
          validate_columns
        end
        
        attr_accessor :name
        attr_reader :columns
        
        def constrained_colnames
          columns
        end
        
        protected
        def validate_columns
          unless columns.kind_of? Array
            Constraint.bad_spec(
              %Q{#{self.class::IDENTIFIER} constraint #{@name} expected "columns" to be a sequence (Array)}
            )
          end
          if columns.uniq.length < columns.length
            Constraint.bad_spec(
              %Q{#{self.class::IDENTIFIER} constraint #{@name} has one or more duplicate columns}
            )
          end
        end
      end
      
      class PrimaryKey < Constraint
        IDENTIFIER = "primary key"
        IMPLICIT_PREFIX = "PK_"
      end
      
      class UniquenessConstraint < Constraint
        IDENTIFIER = "unique"
        IMPLICIT_PREFIX = "UQ_"
      end
      
      class ForeignKey < Constraint
        IDENTIFIER = "foreign key"
        IMPLICIT_PREFIX = "FK_"
        
        def initialize(name, constr_spec)
          super(name, constr_spec)
          @referent = constr_spec['link to'] || Constraint.bad_spec(
            %Q{Foreign key constraint #{@name} does not specify "link to" (referent)}
          )
        end
        
        def constrained_colnames
          columns.keys
        end
        
        protected
        def validate_columns
          unless columns.kind_of? Hash
            Constraint.bad_spec(
              %Q{Foreign key constraint #{@name} expected "columns" to be a mapping (Hash) referrer -> referent}
            )
          end
        end
      end
      
      def initialize(name, structure)
        @name = name
        @columns_by_name = (structure['columns'] || raise(
          SpecificationError,
          "No columns specified for table #{@name}"
        )).inject({}) do |result, item|
          column = Column.new(item)
          result[column.name] = column
          result
        end
        @primary_key = columns.select(&:primary_key?).tap do |cols|
          break nil if cols.empty?
          break PrimaryKey.new(nil, {'columns'=>cols})
        end
        @constraints = structure['constraints'].inject({}) do |result, name_spec_pair|
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
        
        unless errors.empty?
          raise SpecificationError, errors.join("\n")
        end
      end
      
      attr_accessor :name
      attr_reader :constraints
      
      def columns
        @columns_by_name.values
      end
      
      def get_column(name)
        @columns_by_name[name]
      end
      
      def has_column?(name)
        @columns_by_name.has_key? name
      end
    end
  end
end
