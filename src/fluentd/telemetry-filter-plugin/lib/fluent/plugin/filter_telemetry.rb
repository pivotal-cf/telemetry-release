require 'fluent/plugin/filter'

module Fluent::Plugin
  class FilterTelemetry < Filter
    Fluent::Plugin.register_filter('telemetry', self)

    def filter(tag, time, record)
      if log_line = record["log"]
        LogTelemetryMessageExtractor.new(log_line).extract_message
      end
    end
  end


  class LogTelemetryMessageExtractor
    QUOTED_TOKEN = '"telemetry-source"'
    ESCAPED_QUOTED_TOKEN = '\"telemetry-source\"'

    def initialize(log_line)
      @log_line = log_line
    end

    def extract_message
      return unless (match = match_telemetry_token)

      @scanner = JSONObjectBorderScanner.new(@log_line, start_pos: match[:index], forwards: false)
      return unless (object_start_index = @scanner.find_end_of_json_obj(match[:escaped]))

      @scanner = JSONObjectBorderScanner.new(@log_line, start_pos: match[:index])
      return unless (object_end_index = @scanner.find_end_of_json_obj(match[:escaped]))

      potential_message = @log_line[object_start_index, object_end_index - object_start_index]
      potential_message = JSON.parse("\"#{potential_message}\"") if match[:escaped]
      JSON.parse(potential_message)
    end

    def match_telemetry_token
      if (index = @log_line.index(QUOTED_TOKEN))
        {index: index, escaped: false}
      elsif (index = @log_line.index(ESCAPED_QUOTED_TOKEN))
        {index: index, escaped: true}
      end
    end
  end


  class JSONObjectBorderScanner < StringScanner
    def initialize(string, start_pos: 0, forwards: true, object_level: 1)
      super(forwards ? string : string.reverse)
      self.pos = forwards ? start_pos : string.length - start_pos
      @object_level = object_level
      @forwards = forwards

      @start_obj_token, @end_obj_token = forwards ? %w({ }) : %w(} {)
    end

    def find_end_of_json_obj(escaped)
      # If we're in an escaped string, then quotes will be escaped with 3 backslashes instead of 1
      escape_lookahead_size = escaped ? 3 : 1

      loop do
        return unless (current_char = self.scan(/./))

        case current_char
        when @start_obj_token
          @object_level += 1
        when @end_obj_token
          @object_level -= 1
          return @forwards ? self.pos : self.string.length - self.pos if @object_level == 0
        when '"'
          next if escaped && adjacent_n_chars(1) != "\\"

          loop do
            return unless (current_char = self.scan(/./))
            break if current_char == '"' && adjacent_n_chars(escape_lookahead_size) !~ /^\\{#{escape_lookahead_size}}$/
          end
        else
          {}
        end
      end
      nil
    end

    def adjacent_n_chars(n)
      @forwards ? self.string[self.pos - n - 1, n] : self.peek(n)
    end
  end
end

