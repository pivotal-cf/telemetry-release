require 'strscan'

log_line = '{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\\\"ta\", \"counter\": 42}, \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}" }'
reversed = log_line.reverse

scanner = StringScanner.new(reversed)
scanner.pos = 90

object_level = 1
iterations = 0
escaped_mode = true
in_string = false

puts "Starting backward scan"

loop do
  break if iterations > 150
  
  char = scanner.scan(/./)
  break unless char
  
  iterations += 1
  
  if !in_string
    case char
    when '}'
      object_level += 1
      puts "#{iterations}: pos #{scanner.pos-1}, level #{object_level}, scanned '#{char}'"
    when '{'
      object_level -= 1
      puts "#{iterations}: pos #{scanner.pos-1}, level #{object_level}, scanned '#{char}'"
      if object_level == 0
        puts "\nFOUND END"
        break
      end
    when '"'
      adj = scanner.peek(1)
      if escaped_mode && adj != '\\'
        puts "#{iterations}: pos #{scanner.pos-1}, skipping quote (adj=#{adj.inspect})"
        next
      end
      
      puts "#{iterations}: pos #{scanner.pos-1}, entering string"
      in_string = true
    end
  else
    # In string
    if char == '"'
      count = 0
      check_pos = scanner.pos - 2
      while check_pos >= 0 && reversed.byteslice(check_pos, 1) == '\\'
        count += 1
        check_pos -= 1
      end
      
      is_escaped = case count
      when 0, 1 then false
      else true
      end
      
      if !is_escaped
        puts "#{iterations}: pos #{scanner.pos-1}, exiting string (#{count} backslashes)"
        in_string = false
      end
    end
  end
end

puts "\nTotal iterations: #{iterations}, final level: #{object_level}, in_string: #{in_string}"
puts "Scanner at end: #{scanner.eos?}"
