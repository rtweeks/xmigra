module XMigra
  module Console
    class Menu
      def initialize(title, options, prompt, opts={})
        @title = title
        @prompt = prompt
        @title_width = opts[:title_width] || 40
        @title_rule = opts[:title_rule] || '='
        @trailing_newlines = opts[:trailing_newlines] || 3
        get_name = opts[:get_name] || lambda {|o| o.to_s}
        @name_map = {}
        @menu_map = {}
        options.each_with_index do |opt, i|
          opt_name = get_name[opt]
          @name_map[opt_name] = opt
          @menu_map[i + 1] = opt_name
        end
      end
      
      attr :title, :prompt, :title_width, :title_rule, :trailing_newlines
      
      def show_once
        Console.output_section(
          title, 
          :trailing_newlines => @trailing_newlines
        ) do
          @menu_map.each_pair do |item_num, name|
            puts "#{item_num.to_s.rjust(4)}. #{name}"
          end
          puts
          print prompt + ': '
          
          user_choice = $stdin.gets.strip
          @menu_map[user_choice.to_i].tap do |mapped|
            return mapped unless mapped.nil?
          end
          return user_choice if @menu_map.values.include? user_choice
          by_prefix = @menu_map.values.select {|e| e.start_with? user_choice}
          return by_prefix[0] if by_prefix.length == 1
        end
        return nil
      end
      
      def get_selection
        selection = nil
        loop do
          selection = show_once
          break unless selection.nil?
          puts "That input did not uniquely identify one of the available options."
          puts
        end
        @trailing_newlines.times {puts}
        return @name_map[selection]
      end
    end
    
    class InvalidInput < Exception
      def initialize(msg=nil)
        super(msg)
        @explicit_message = !msg.nil?
      end
      
      def explicit_message?
        @explicit_message
      end
    end
    
    class <<self
      def output_section(title=nil, opts={})
        trailing_newlines = opts[:trailing_newlines] || 3
        
        if title
          puts " #{title} ".center(40, '=')
          puts
        end
        
        (yield).tap do
          trailing_newlines.times {puts}
        end
      end
      
      def validated_input(prompt)
        loop do
          print prompt + ": "
          input_value = $stdin.gets.strip
          
          result = begin
            yield input_value
          rescue InvalidInput => e
            XMigra.log_error(e)
            puts e.message if e.explicit_message?
            next
          end
          
          return result unless result.nil?
        end
      end
      
      def yes_no(prompt, default_value)
        input_options = ""
        input_options << (default_value == :yes ? "Y" : "y")
        input_options << (default_value == :no ? "N" : "n")
        
        validated_input("#{prompt} [#{input_options}]") do |input_value|
          case input_value
          when /^y(es)?$/io
            true
          when /^n(o)?$/io
            false
          when ''
            {:yes => true, :no => false}[default_value]
          end
        end
      end
    end
  end
end
