module XMigra
  module DeclarativeSupport
    class SpecificationError < Error; end
    
    class StructureReader
      EXTENSION_PREFIX = 'X-'
      
      def initialize(data, keypath=[])
        @keypath = keypath
        @data = data
        @children = []
        @used_keys = Set.new
      end
      
      def [](key)
        result, result_key = item_and_keypath(key)
        
        case result
        when Hash
          result = StructureReader.new(result, result_key).tap do |r|
            r.parent = self
          end
        when Array
          raise "Invalid to fetch an array via [] -- use array_fetch"
        end
        
        @used_keys << key if @data.kind_of? Hash
        return result
      end
      
      def array_fetch(key, key_finder_proc)
        result, result_key = item_and_keypath(key)
        unless result.kind_of? Array
          raise ::TypeError, "Expected key for array"
        end
        
        @used_keys << key if @data.kind_of? Hash
        return StructureReader.new(result, result_key).tap do |r|
          r.parent = self
          r.key_finder_proc = key_finder_proc
        end
      end
      
      def raw_item(key)
        @used_keys << key if @data.kind_of? Hash
        return @data[key]
      end
      
      def each
        to_enum(:each) unless block_given?
        
        if @data.kind_of? Hash
          @data.each_key {|k| yield k, self[k]}
        else
          (0...@data.length).each {|i| yield self[i]}
        end
      end
      include Enumerable
      
      def kind_of?(klass)
        return super(klass) || @data.kind_of?(klass)
      end
      
      def hash
        @data.hash
      end
      
      def eql?(other)
        @data.eql?(other)
      end
      
      def keys
        @data.keys
      end
      
      def values
        @data.values
      end
      
      def uniq
        collect {|o| o}.uniq
      end
      
      def length
        @data.length
      end
      
      def join(sep=$,)
        @data.join(sep)
      end
      
      def each_extension(&blk)
        return to_enum(:each_extension) if blk.nil?
        
        if @data.kind_of? Hash
          @data.each_pair do |k, val|
            next unless k.kind_of?(String) and k.start_with?(EXTENSION_PREFIX)
            blk.call((@keypath + [k]).join('.'), val)
          end
        end
        
        children.each do |child|
          child.each_extension(&blk)
        end
      end
      
      def each_unused_standard_key(&blk)
        return to_enum(:each_unused_standard_key) if blk.nil?
        
        if @data.kind_of? Hash
          @data.each_key do |k|
            next if @used_keys.include?(k)
            next if k.kind_of?(String) && k.start_with?(EXTENSION_PREFIX)
            blk.call(@keypath + [k]).join('.')
          end
        end
        children.each {|child| child.each_unused_standard_key(&blk)}
      end
      
      protected
      attr_accessor :key_finder_proc
      attr_reader :parent, :children
      
      def parent=(new_val)
        @parent.children.delete(self) if @parent
        @parent = new_val
        @parent.children << self if @parent
        new_val
      end
      
      def item_and_keypath(key)
        item = @data[key]
        subkey = begin
          if @key_finder_proc
            @keypath + [@key_finder_proc.call(item)]
          else
            @keypath + [key]
          end
        end
        return item, subkey
      end
    end
  end
end
