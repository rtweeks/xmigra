module XMigra
  def self.dedent(s, prefix='')
    margin = nil
    s.lines.map do |l|
      case 
      when margin.nil? && l =~ /^ *$/
        l
      when margin.nil?
        margin = /^ */.match(l)[0].length
        l[margin..-1]
      else
        /^(?: {0,#{margin}})(.*)/m.match(l)[1]
      end
    end.tap do |lines|
      lines.shift if lines.first == "\n"
    end.map do |l|
      prefix + l
    end.join('')
  end
end
