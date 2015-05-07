module XMigra
  class ConsoleMenu
    def initialize(title, options, prompt, opts={})
      @title = title
      @prompt = prompt
      @title_width = opts[:title_width] || 40
      @title_rule = opts[:title_rule] || '='
      get_name = opts[:get_name] || lambda {|o| o.to_s}
      @name_map = {}
      @menu_map = {}
      options.each_with_index do |opt, i|
        opt_name = get_name[opt]
        @name_map[opt_name] = opt
        @menu_map[i + 1] = opt_name
      end
    end
    
    attr :title, :prompt, :title_width, :title_rule
    
    def show_once
      puts " #{title} ".center(@title_width, @title_rule)
      puts
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
      return nil
    end
    
    def get_selection
      selection = show_once
      while selection.nil?
        puts "That input did not uniquely identify one of the available options."
        puts
        selection = show_once
      end
      return @name_map[selection]
    end
  end
end
