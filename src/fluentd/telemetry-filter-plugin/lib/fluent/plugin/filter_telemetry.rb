# frozen_string_literal: true

require 'fluent/plugin/filter'
require 'date'

module Fluent
  module Plugin
    # FilterTelemetry extracts telemetry messages from log records
    #
    # This filter processes log records looking for telemetry messages that contain:
    # 1. A "telemetry-source" field identifying the source of the telemetry
    # 2. A "telemetry-time" field with an RFC 3339 formatted timestamp
    #
    # The filter can handle telemetry messages in various formats:
    # - Directly as JSON objects in the log line
    # - Embedded within other JSON structures
    # - Escaped as JSON strings within log messages
    # - Surrounded by arbitrary text
    #
    # @example Valid telemetry message
    #   { "telemetry-source": "my-component", "telemetry-time": "2009-11-10T23:00:00Z", "data": {...} }
    #
    # @example Embedded in log line
    #   Tue 14-Mar-2019 [Thread-14] com.java.SomeClass {"telemetry-source": "my-component", ...} additional text
    #
    # If an agent-version is present in the input record, it will be added to the output
    # as "telemetry-agent-version".
    #
    # Messages that don't contain both required fields or have invalid timestamps are rejected.
    #
    # == PERFORMANCE AND MEMORY CHARACTERISTICS
    #
    # This filter performs complex JSON parsing and boundary detection which has significant
    # memory overhead. Based on performance benchmarks (see spec/plugin/filter_telemetry_spec.rb
    # benchmark tests), memory usage is approximately 43x the input log line size due to:
    # - String reversal for backward scanning (~1x)
    # - Ruby string object overhead and capacity buffers (~40x)
    # - JSON parsing and object creation
    #
    # === Memory Requirements by Log Size (Benchmarked on Ruby 3.4.7)
    #
    #   Log Size | Memory Used | Processing Time | Notes
    #   ---------|-------------|-----------------|--------------------------------------
    #      5 MB  |    ~215 MB  |           ~3s   | Safe on all instance types
    #     10 MB  |    ~430 MB  |          ~11s   | Safe on e2-micro (1GB RAM)
    #     15 MB  |    ~645 MB  |          ~25s   | Tight on e2-micro, safe on larger
    #     20 MB  |    ~860 MB  |          ~45s   | Very tight on e2-micro
    #     25 MB  |  ~1,075 MB  |          ~60s   | Exceeds e2-micro capacity (OOM risk)
    #     30 MB  |  ~1,290 MB  |          ~90s   | Requires 2GB+ RAM
    #     50 MB  |  ~2,150 MB  |         ~95s    | Requires 4GB+ RAM
    #    100 MB  |  ~4,300 MB  |        ~330s    | Requires 8GB+ RAM
    #
    # === Deployment Guidance
    #
    # For e2-micro instances (1GB RAM) - default deployment:
    # - Safe log size: Up to 10MB (uses ~430MB, leaves headroom for other processes)
    # - Maximum recommended: 15MB (uses ~645MB, tight but functional)
    # - Will OOM: 25MB+ logs will exceed available RAM and crash the process
    #
    # For larger log lines, deploy on appropriately sized instances:
    # - e2-medium (4GB RAM): Safe up to ~80MB log lines
    # - e2-standard-2 (8GB RAM): Safe up to ~180MB log lines
    #
    # If the centralizer process crashes due to OOM:
    # - BPM (BOSH Process Manager) and Monit will automatically restart it (~30-60s downtime)
    # - The agent will buffer logs and retry when centralizer recovers
    # - No log loss under normal conditions
    #
    # === Performance Characteristics
    #
    # Processing time scales roughly linearly with log size, but with degradation at larger sizes
    # due to memory pressure. On e2-micro (shared CPU), times may be 2-3x longer than benchmarked.
    #
    # Malformed logs (missing closing quotes/braces) require full string scanning and take similar
    # time to valid logs, returning nil after scanning completes.
    #
    # === Testing
    #
    # To run performance benchmarks and see current behavior:
    #   bundle exec rspec spec/ --tag benchmark
    #
    # This will test various log sizes and report actual memory usage and processing times
    # on your system.
    #
    class FilterTelemetry < Filter
      Fluent::Plugin.register_filter('telemetry', self)

      # Filters a single log record, extracting telemetry messages if present
      #
      # @param _tag [String] The tag of the record (unused)
      # @param _time [Fluent::EventTime] The timestamp of the record (unused)
      # @param record [Hash] The log record to filter
      # @return [Hash, nil] The extracted telemetry message with agent version merged in, or nil if no valid message found
      def filter(_tag, _time, record)
        if (log_line = record['log'])
          version_info = {}
          version_info['telemetry-agent-version'] = record['agent-version'] if record['agent-version']
          begin
            msg = LogTelemetryMessageExtractor.new(log_line).extract_message.merge(version_info)
            validate_telemetry_time(msg['telemetry-time'], log_line)
            msg
          rescue StandardError => e
            log.info e
            nil
          end
        end
      end

      # Validates that a telemetry-time field conforms to RFC 3339 format
      #
      # @param time [String] The timestamp string to validate
      # @param log_line [String] The original log line (for error messages)
      # @raise [StandardError] If the timestamp is not valid RFC 3339
      # @return [DateTime] The parsed datetime if valid
      def validate_telemetry_time(time, log_line)
        DateTime.rfc3339(time)
      rescue StandardError => e
        raise StandardError,
              "telemetry-time field from event <#{log_line}> must be in date/time format RFC 3339. Cause: #{e.inspect}"
      end
    end

    # LogTelemetryMessageExtractor finds and extracts telemetry JSON messages from log lines
    #
    # This class implements a sophisticated JSON extraction algorithm that can find
    # telemetry messages embedded in various formats:
    # 1. Direct JSON objects: { "telemetry-source": "x", ... }
    # 2. Escaped JSON strings: "{ \"telemetry-source\": \"x\", ... }"
    # 3. JSON within arbitrary text: prefix {"telemetry-source": "x"} suffix
    #
    # The extraction works by:
    # 1. Finding the "telemetry-source" token (quoted or escaped)
    # 2. Scanning backwards to find the start of the JSON object
    # 3. Scanning forwards to find the end of the JSON object
    # 4. Extracting and parsing the JSON
    #
    # This approach handles nested objects, arrays, and escaped quotes correctly.
    #
    class LogTelemetryMessageExtractor
      QUOTED_TOKEN = '"telemetry-source"'
      ESCAPED_QUOTED_TOKEN = '\"telemetry-source\"'

      # @param log_line [String] The log line to extract telemetry message from
      def initialize(log_line)
        @log_line = log_line
      end

      # Extracts a telemetry message from the log line
      #
      # @return [Hash, nil] The parsed telemetry message, or nil if no valid message found
      # @raise [StandardError] If a potential message is found but fails to parse
      def extract_message
        return unless (match = match_telemetry_token)

        @scanner = JSONObjectBorderScanner.new(@log_line, start_pos: match[:index], forwards: false)
        return unless (object_start_index = @scanner.find_end_of_json_obj(match[:escaped]))

        @scanner = JSONObjectBorderScanner.new(@log_line, start_pos: match[:index])
        return unless (object_end_index = @scanner.find_end_of_json_obj(match[:escaped]))

        begin
          potential_message = @log_line[object_start_index, object_end_index - object_start_index]
          potential_message = JSON.parse("\"#{potential_message}\"") if match[:escaped]
          JSON.parse(potential_message)
        rescue StandardError => e
          raise StandardError,
                "Failed parsing potential message <#{potential_message}> from event <#{@log_line}>. Cause: #{e.inspect}"
        end
      end

      # Finds the location of the telemetry-source token in the log line
      #
      # @return [Hash, nil] Hash with :index and :escaped keys, or nil if not found
      def match_telemetry_token
        if (index = @log_line.index(QUOTED_TOKEN))
          { index: index, escaped: false }
        elsif (index = @log_line.index(ESCAPED_QUOTED_TOKEN))
          { index: index, escaped: true }
        end
      end
    end

    # JSONObjectBorderScanner scans through a string to find JSON object boundaries
    #
    # This class extends StringScanner to provide specialized functionality for finding
    # the start and end of JSON objects. It correctly handles:
    # - Nested objects and arrays
    # - Quoted strings (escaped and unescaped)
    # - Escaped characters within strings
    # - Bidirectional scanning (forwards and backwards)
    #
    # The scanner maintains an object nesting level and returns when it reaches
    # a matching closing brace for the starting object.
    #
    class JSONObjectBorderScanner < StringScanner
      # @param string [String] The string to scan
      # @param start_pos [Integer] Starting position in the string (character position, not byte position)
      # @param forwards [Boolean] If true, scan forwards; if false, scan backwards
      # @param object_level [Integer] Initial nesting level (1 = looking for matching brace)
      def initialize(string, start_pos: 0, forwards: true, object_level: 1)
        @original_string = string
        super(forwards ? string : string.reverse)
        
        # StringScanner uses byte positions, but start_pos is a character position
        # Convert character position to byte position
        if forwards
          # start_pos is a char position in the original string
          self.pos = @original_string[0, start_pos].bytesize
        else
          # start_pos is a char position in the original string
          # Calculate corresponding char position in reversed string, then convert to bytes
          char_pos_in_reversed = @original_string.length - start_pos
          self.pos = self.string[0, char_pos_in_reversed].bytesize
        end
        
        @object_level = object_level
        @forwards = forwards

        @start_obj_token, @end_obj_token = forwards ? %w[{ }] : %w[} {]
      end

      # Finds the end boundary of a JSON object
      #
      # Scans through the string character by character, tracking JSON object nesting
      # and properly handling quoted strings. Returns the position where the object
      # ends (when nesting level reaches zero).
      #
      # @param escaped [Boolean] If true, expects quotes escaped with 3 backslashes; if false, 1 backslash
      # @return [Integer, nil] The character position (not byte position) where the JSON object ends, or nil if not found
      def find_end_of_json_obj(escaped)
        # If we're in an escaped string, then quotes will be escaped with 3 backslashes instead of 1
        escape_lookahead_size = escaped ? 3 : 1

        loop do
          return unless (current_char = scan(/./))

          case current_char
          when @start_obj_token
            @object_level += 1
          when @end_obj_token
            @object_level -= 1
            if @object_level.zero?
              # Convert byte position back to character position
              if @forwards
                # pos is a byte position in the original string
                return self.string[0, pos].length
              else
                # pos is a byte position in the reversed string
                # Convert to character position in reversed string, then to original string position
                char_pos_in_reversed = self.string[0, pos].length
                return @original_string.length - char_pos_in_reversed
              end
            end
          when '"'
            next if escaped && adjacent_n_chars(1) != '\\'

            loop do
              return unless (current_char = scan(/./))
              if current_char == '"'
                # For normal JSON (escape_lookahead_size = 1), count consecutive backslashes
                # to properly handle cases like C:\\Windows\\ where the final quote is not escaped
                if escape_lookahead_size == 1
                  backslash_count = count_preceding_backslashes(escape_lookahead_size)
                  break if backslash_count.even?
                else
                  # For escaped JSON (escape_lookahead_size = 3), use simpler pattern matching
                  # Check if previous escape_lookahead_size characters are exactly that many backslashes
                  break if adjacent_n_chars(escape_lookahead_size) !~ /^\\{#{escape_lookahead_size}}$/
                end
              end
            end
          # else: For any other character, continue scanning (no action needed)
          end
        end
        nil
      end

      # Returns n characters adjacent to the current position
      #
      # @param n [Integer] Number of characters to retrieve
      # @return [String] The adjacent characters
      def adjacent_n_chars(n)
        @forwards ? string[pos - n - 1, n] : peek(n)
      end

      # Counts the number of consecutive backslashes before the current position
      #
      # For normal JSON (escape_lookahead_size = 1):
      #   Count individual backslashes. Odd = quote is escaped.
      #
      # For escaped JSON (escape_lookahead_size = 3):
      #   In escaped JSON, a single backslash before a quote means the quote is a delimiter (not escaped).
      #   Three backslashes before a quote means the quote is escaped.
      #   We count groups of backslashes: 1 backslash = not escaped (count 0), 3 backslashes = escaped (count 1).
      #
      # @param escape_lookahead_size [Integer] For escaped strings (3), otherwise 1
      # @return [Integer] Number of escape sequences before current position
      def count_preceding_backslashes(escape_lookahead_size)
        # pos points to after the character we just scanned
        # pos - 1 is the character we just scanned (the quote)
        # pos - 2 is the character before the quote
        check_pos = pos - 2
        
        # First, count total consecutive backslashes
        total_backslashes = 0
        temp_pos = check_pos
        while temp_pos >= 0 && string.byteslice(temp_pos, 1) == '\\'
          total_backslashes += 1
          temp_pos -= 1
        end
        
        # For normal JSON (escape_lookahead_size = 1):
        #   Return the total count. Odd = escaped, even = not escaped.
        return total_backslashes if escape_lookahead_size == 1
        
        # For escaped JSON (escape_lookahead_size = 3):
        #   1 backslash means the quote is a delimiter (return 0 = not escaped)
        #   3 backslashes means the quote is escaped (return 1 = escaped)
        #   Other counts are malformed, but we'll handle them conservatively
        case total_backslashes
        when 0 then 0   # No backslash before quote - quote is delimiter
        when 1 then 0   # One backslash before quote - in escaped JSON, quote is delimiter  
        when 2 then 2   # Two backslashes - conservative: treat as escaped
        else
          # 3 or more: count in groups of 3, plus any remainder
          (total_backslashes / 3) + (total_backslashes % 3)
        end
      end
    end
  end
end
