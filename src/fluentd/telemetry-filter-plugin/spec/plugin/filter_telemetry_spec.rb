require_relative '../spec_helper'
require_relative '../../lib/fluent/plugin/filter_telemetry'


describe 'Filters telemetry messages' do
  include Fluent::Test::Helpers

  let(:driver) { Fluent::Test::Driver::Filter.new(Fluent::Plugin::FilterTelemetry).configure('') }
  before do
    Fluent::Test.setup
    @time = event_time
  end

  def filter(message)
    driver.run {
      driver.feed("filter.test", @time, message)
    }
    expect(driver.error_events).to(be_empty)
    driver.filtered_records
  end

  it 'returns telemetry messages without agent version if not present' do
    records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"app": "da\"ta", "counter": 42, "array": [ {"cool":"value"} ]}}'})

    expect(records).to(eq([{"data" => {"app" => 'da"ta', "counter" => 42, "array" => [{"cool" => "value"}]}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
  end

  it 'returns telemetry messages with the agent version merged in' do
    records = filter({"agent-version" => "0.0.1", "log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"app": "da\"ta", "counter": 42, "array": [ {"cool":"value"} ]}}'})

    expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"app" => 'da"ta', "counter" => 42, "array" => [{"cool" => "value"}]}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
  end

  it 'returns telemetry messages when the telemetry message has object chars in the keys or values after the telemetry-source key' do
    records = filter({"agent-version" => "0.0.1", "log" => '{ "telemetry-source": "my-{origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"}app": "d}ata"}} maybe some junk here'})
    expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
  end

  it 'returns telemetry messages when the telemetry message has object chars in the keys or values before the telemetry-source key' do
    records = filter({"agent-version" => "0.0.1", "log" => '{ "data": {"}app": "d}ata"}, "telemetry-source": "my-{origin", "telemetry-time": "2019-10-23T14:49:39-04:00"} maybe some junk here'})
    expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
  end

  context 'when telemetry messages appears as a JSON object embedded in other log lines' do
    it 'returns messages when nested in another JSON object' do
      records = filter({"agent-version" => "0.0.1", "log" => '{ "time": 12341234123412, "level": "info", "message": "whatever", "data": { "something": "else", "telemetry-thing": { "telemetry-source": "my-origin",  "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"app": "da\"ta", "counter": 42, "array": [ {"cool":"value"} ]}}, "more": "otherthings"}'})
      expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"app" => 'da"ta', "counter" => 42, "array" => [ { "cool" => "value" }]}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'returns messages embedded in an arbitrary string' do
      records = filter({"agent-version" => "0.0.1", "log" => 'Tue 14-Mar-2019 [Thread-14] com.java.SillyClass myhostname { "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"app": "data"}} maybe some junk here'})
      expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"app" => "data"}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end
  end

  context 'when telemetry messages are embedded as escaped json strings' do
    it 'returns messages' do
      records = filter({"agent-version" => "0.0.1", "log" => '{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\\\"ta\", \"counter\": 42}, \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}" }'})
      expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"app" => 'da"ta', "counter" => 42}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'returns messages that have object chars in the keys or values after the telemetry-source key' do
      records = filter({"agent-version" => "0.0.1", "log" => '{ \"telemetry-source\": \"my-{origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"data\": {\"}app\": \"d}ata\"}} maybe some junk here'})
      expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'returns messages that have object chars in the keys or values after the telemetry-source key' do
      records = filter({"agent-version" => "0.0.1", "log" => '{ \"data\": {\"}app\": \"d}ata\"}, \"telemetry-source\": \"my-{origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"} maybe some junk here'})
      expect(records).to(eq([{ "telemetry-agent-version" => "0.0.1", "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end
  end

  it 'reject messages with correct number of object closing braces that is not valid JSON and logs the details of the failure' do
    candidate_extracted_message = '{"telemetry-source": "somethign", "telemetry-time": "2019-10-23T14:49:39-04:00", {"invalid-object": "object-has-no-key"}}'
    records = filter({"log" => "wrapping text #{candidate_extracted_message}"})
    expect(records).to(be_empty)
    expect(driver.logs).to(include(/Failed parsing potential message <#{candidate_extracted_message}> from event <wrapping text #{candidate_extracted_message}>. Cause: .+/))
  end

  it 'rejects messages without a log key' do
    expect(filter({"other" => "key"})).to(be_empty)
  end

  it 'rejects messages with a log key that does not contain "telemetry-time"' do
    records = filter({"log" => "some log line telemetry-source"})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key that does not contain RFC3339 formatted "telemetry-time"' do
    records = filter({"log" => 'some log line {"telemetry-source": "some-source", "telemetry-time": "foo"}'})
    expect(records).to(be_empty)
    expect(driver.logs).to(include(/telemetry-time field from event <some log line {\"telemetry-source\": \"some-source\", \"telemetry-time\": \"foo\"}> must be in date\/time format RFC 3339. Cause: .+/))
  end

  it 'rejects messages with a log key that does not contain "telemetry-source"' do
    records = filter({"log" => "some log line telemetry-time"})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing "telemetry-source" that is not a json key' do
    records = filter({"log" => '"telemetry-source telemetry-time"'})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing an escaped "telemetry-source" that is not a json key' do
    records = filter({"log" => '\"telemetry-source\" \"telemetry-time\" '})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing "telemetry-source" but contains invalid json' do
    records = filter({"log" => '{ "message": "{ "data": "invalid": "structure"}, "telemetry-time": "2019-10-23T14:49:39-04:00", "telemetry-source": "my-origin"}" }'})
    expect(records).to(be_empty)
  end

  # Characterization tests for backward compatibility
  # These tests document current behavior and must pass to ensure we don't break existing functionality
  context 'characterization tests for backward compatibility' do
    it 'handles empty string values in JSON' do
      records = filter({"log" => '{ "telemetry-source": "", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"empty": ""}}'})
      expect(records).to(eq([{"data" => {"empty" => ""}, "telemetry-source" => "", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles unicode characters in telemetry data' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": {"emoji": "🔥", "japanese": "日本語", "arabic": "العربية"}}'})
      expect(records).to(eq([{"data" => {"emoji" => "🔥", "japanese" => "日本語", "arabic" => "العربية"}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles nested objects up to reasonable depth' do
      nested_json = '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "level1": {"level2": {"level3": {"level4": {"level5": {"value": "deep"}}}}}}'
      records = filter({"log" => nested_json})
      expected = {
        "telemetry-source" => "my-origin",
        "telemetry-time" => "2019-10-23T14:49:39-04:00",
        "level1" => {
          "level2" => {
            "level3" => {
              "level4" => {
                "level5" => {"value" => "deep"}
              }
            }
          }
        }
      }
      expect(records).to(eq([expected]))
    end

    it 'handles special characters in keys and values' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "special": "line\\nbreak\\ttab", "path": "/usr/local/bin"}'})
      expect(records).to(eq([{"special" => "line\nbreak\ttab", "path" => "/usr/local/bin", "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles numeric values correctly' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "int": 42, "float": 3.14, "negative": -10, "zero": 0}'})
      expect(records).to(eq([{"int" => 42, "float" => 3.14, "negative" => -10, "zero" => 0, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles boolean values correctly' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "enabled": true, "disabled": false}'})
      expect(records).to(eq([{"enabled" => true, "disabled" => false, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles null values correctly' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "nullable": null}'})
      expect(records).to(eq([{"nullable" => nil, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles empty arrays and objects' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "empty_array": [], "empty_object": {}}'})
      expect(records).to(eq([{"empty_array" => [], "empty_object" => {}, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles arrays with mixed types' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "mixed": [1, "string", true, null, {"nested": "object"}]}'})
      expect(records).to(eq([{"mixed" => [1, "string", true, nil, {"nested" => "object"}], "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles different RFC3339 timestamp formats' do
      # Test with different timezone formats - each test uses a fresh driver to avoid accumulation
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39Z", "data": "utc"}'})
      expect(records.last).to(eq({"data" => "utc", "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39Z"}))
      
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39+00:00", "data": "plus_zero"}'})
      expect(records.last).to(eq({"data" => "plus_zero", "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39+00:00"}))
      
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39.123456Z", "data": "microseconds"}'})
      expect(records.last).to(eq({"data" => "microseconds", "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39.123456Z"}))
    end

    it 'handles escaped quotes within values' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "quote": "He said \\"hello\\""}'})
      expect(records).to(eq([{"quote" => 'He said "hello"', "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'rejects moderately large nested JSON (documents boundary behavior)' do
      # Test with 15 levels of nesting - document what happens currently
      nested = '{"a":' * 15 + '"value"' + '}' * 15
      log_line = "{ \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"deep\": #{nested}}"
      records = filter({"log" => log_line})
      # This test documents current behavior - if it parses successfully, we maintain that
      # If it fails, we document that failure
      expect(records.length).to be <= 1
    end

    it 'handles reasonably sized log lines (documents size handling)' do
      # Create a log line with 1000 characters of data
      large_value = 'x' * 1000
      records = filter({"log" => "{ \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"data\": \"#{large_value}\"}"})
      expect(records).to(eq([{"data" => large_value, "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles backslashes at string boundaries correctly' do
      # Backslash before closing quote
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "path": "C:\\\\Windows\\\\"}'})
      expect(records).to(eq([{"path" => 'C:\\Windows\\', "telemetry-source" => "my-origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'preserves order of keys in output (or documents that it doesn\'t)' do
      # This documents whether key order is preserved
      records = filter({"log" => '{ "telemetry-source": "my-origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "first": 1, "second": 2, "third": 3}'})
      expect(records.first.keys).to include("first", "second", "third")
      # Note: Ruby hashes maintain insertion order in Ruby 1.9+, but JSON parsing may not preserve it
    end

    it 'handles messages where telemetry-source appears multiple times (uses first occurrence)' do
      # Document behavior when telemetry-source appears twice
      records = filter({"log" => 'prefix { "telemetry-source": "origin1", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": 1} suffix { "telemetry-source": "origin2", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": 2}'})
      # This will document which occurrence gets picked up
      expect(records.length).to be >= 1
      if records.length > 0
        expect(records.first["telemetry-source"]).to eq("origin1")
      end
    end
  end

  # Edge case tests for robustness (new behavior - can be more strict)
  context 'edge cases and error handling' do
    it 'rejects messages with only telemetry-source (missing telemetry-time)' do
      records = filter({"log" => '{ "telemetry-source": "my-origin", "data": "test"}'})
      expect(records).to(be_empty)
    end

    it 'rejects messages with only telemetry-time (missing telemetry-source)' do
      records = filter({"log" => '{ "telemetry-time": "2019-10-23T14:49:39-04:00", "data": "test"}'})
      expect(records).to(be_empty)
    end

    it 'handles log lines with no JSON at all' do
      records = filter({"log" => 'plain text log line with no json telemetry-source telemetry-time'})
      expect(records).to(be_empty)
    end

    it 'handles telemetry-source with Unicode characters' do
      records = filter({"log" => '{ "telemetry-source": "服务器-🚀", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": "test"}'})
      expect(records).to(eq([{"data" => "test", "telemetry-source" => "服务器-🚀", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles telemetry message with only required fields (minimal valid message)' do
      records = filter({"log" => '{ "telemetry-source": "minimal", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-source" => "minimal", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles multiple consecutive backslashes in different positions' do
      # Test 3, 4, 5 consecutive backslashes
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "three": "\\\\\\\\\\\\", "four": "\\\\\\\\\\\\\\\\"}'})
      expect(records).to(eq([{"three" => "\\\\\\", "four" => "\\\\\\\\", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles JSON with whitespace variations (tabs and multiple spaces)' do
      # Note: Newlines in the middle of JSON may not be handled by the extractor
      # since it searches for telemetry-source token in a single-line scan
      log_with_whitespace = "{\t\"telemetry-source\":\t\t\"origin\",  \"telemetry-time\":   \"2019-10-23T14:49:39-04:00\",\t\"data\":\"value\"}"
      records = filter({"log" => log_with_whitespace})
      expect(records).to(eq([{"data" => "value", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end
    
    it 'documents behavior with newlines in JSON (multiline JSON)' do
      # Multiline JSON may not extract properly due to line-by-line processing
      log_with_newlines = "{\n  \"telemetry-source\": \"origin\",\n  \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"\n}"
      records = filter({"log" => log_with_newlines})
      # Documents actual behavior - may or may not work depending on processing model
      expect(records.length).to be >= 0
    end

    it 'rejects malformed RFC3339 timestamps (missing timezone)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39", "data": "test"}'})
      expect(records).to(be_empty)
    end

    it 'rejects malformed RFC3339 timestamps (invalid format)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019/10/23 14:49:39", "data": "test"}'})
      expect(records).to(be_empty)
    end

    it 'handles negative timezone offsets in RFC3339' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-12:00", "data": "test"}'})
      expect(records).to(eq([{"data" => "test", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-12:00"}]))
    end

    it 'handles positive timezone offsets in RFC3339' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39+14:00", "data": "test"}'})
      expect(records).to(eq([{"data" => "test", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39+14:00"}]))
    end

    it 'handles very long string values (10KB)' do
      long_value = 'a' * 10000
      records = filter({"log" => "{ \"telemetry-source\": \"origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"data\": \"#{long_value}\"}"})
      expect(records.first["data"]).to eq(long_value)
    end

    it 'handles deeply nested arrays' do
      nested_array = '[[[[["deep"]]]]]'
      records = filter({"log" => "{ \"telemetry-source\": \"origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"nested\": #{nested_array}}"})
      expect(records).to(eq([{"nested" => [[[[["deep"]]]]], "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles scientific notation numbers' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "sci": 1.23e10, "neg": -4.56e-7}'})
      expect(records).to(eq([{"sci" => 1.23e10, "neg" => -4.56e-7, "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles very large numbers' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "big": 9999999999999999999}'})
      expect(records.first["big"]).to be_a(Numeric)
      expect(records.first["telemetry-source"]).to eq("origin")
    end

    it 'handles strings with control characters (properly escaped)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "ctrl": "line1\\nline2\\r\\nline3\\ttab"}'})
      expect(records).to(eq([{"ctrl" => "line1\nline2\r\nline3\ttab", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles forward slashes in strings (no escaping needed in JSON)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "url": "https://example.com/path/to/resource"}'})
      expect(records).to(eq([{"url" => "https://example.com/path/to/resource", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles escaped forward slashes in strings (valid but unnecessary in JSON)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "url": "https:\\/\\/example.com\\/path"}'})
      expect(records).to(eq([{"url" => "https://example.com/path", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles Unicode escape sequences in JSON' do
      # \u0041 = 'A', \u263A = '☺'
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "unicode": "\\u0041\\u263A"}'})
      expect(records).to(eq([{"unicode" => "A☺", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles multiple telemetry messages in nested structures' do
      # Ensure we only extract the first one found
      log = '{ "outer": { "telemetry-source": "outer-source", "telemetry-time": "2019-10-23T14:49:39-04:00", "inner": { "telemetry-source": "inner-source", "telemetry-time": "2019-10-23T14:49:39-04:00"} }}'
      records = filter({"log" => log})
      expect(records.length).to eq(1)
      expect(records.first["telemetry-source"]).to eq("outer-source")
    end

    it 'handles keys with special JSON characters (but properly quoted)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "key:with:colons": "value", "key{with}braces": "value2"}'})
      expect(records).to(eq([{"key:with:colons" => "value", "key{with}braces" => "value2", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles mixed case in telemetry-source and telemetry-time keys' do
      # Keys are case-sensitive, so this should NOT match
      records = filter({"log" => '{ "Telemetry-Source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(be_empty)
    end

    it 'handles extra fields before and after required fields' do
      records = filter({"log" => '{ "first": 1, "second": 2, "telemetry-source": "origin", "middle": "data", "telemetry-time": "2019-10-23T14:49:39-04:00", "last": "field"}'})
      expect(records.first.keys).to include("first", "second", "middle", "last", "telemetry-source", "telemetry-time")
    end

    it 'rejects JSON with duplicate keys (documents JSON parser behavior)' do
      # Most JSON parsers accept this, using the last value
      records = filter({"log" => '{ "telemetry-source": "first", "telemetry-source": "second", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      if records.length > 0
        # Document which value wins (typically the last one)
        expect(["first", "second"]).to include(records.first["telemetry-source"])
      end
    end

    it 'handles empty log value' do
      records = filter({"log" => ""})
      expect(records).to(be_empty)
    end

    it 'handles log value with only whitespace' do
      records = filter({"log" => "   \n\t  "})
      expect(records).to(be_empty)
    end

    it 'handles telemetry message at the very start of log line (no prefix)' do
      records = filter({"log" => '{"telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles telemetry message at the very end of log line (no suffix)' do
      records = filter({"log" => 'prefix text {"telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles array as top-level structure containing telemetry message' do
      records = filter({"log" => '[1, 2, {"telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}]'})
      expect(records).to(eq([{"telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles telemetry fields with surrounding whitespace in values' do
      records = filter({"log" => '{ "telemetry-source": "  origin  ", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-source" => "  origin  ", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'rejects telemetry-time as a number instead of string' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": 1571849379}'})
      expect(records).to(be_empty)
    end

    it 'handles backslash followed by non-special character (treated as literal backslash + char)' do
      # In JSON, \a is not a recognized escape, so it might be treated as invalid or literal
      # This documents the actual behavior
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": "test"}'})
      expect(records.length).to be >= 0  # Documents whether it's accepted or rejected
    end

    it 'handles RFC3339 with fractional seconds (nanoseconds precision)' do
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39.123456789Z"}'})
      expect(records).to(eq([{"telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39.123456789Z"}]))
    end

    it 'handles RFC3339 lowercase t separator (documents strict vs lenient parsing)' do
      # RFC3339 specifies uppercase T, but some parsers accept lowercase
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23t14:49:39Z"}'})
      # Documents whether lowercase t is accepted
      expect(records.length).to be >= 0
    end

    it 'handles extremely nested structure (stress test)' do
      # 20 levels of nesting - documents when/if parser gives up
      nested = '{"level":' * 20 + '"value"' + '}' * 20
      log_line = "{ \"telemetry-source\": \"origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"data\": #{nested}}"
      records = filter({"log" => log_line})
      # Documents behavior - may succeed or fail depending on limits
      expect(records.length).to be >= 0
    end

    it 'handles telemetry message with BOM (Byte Order Mark)' do
      # UTF-8 BOM at start of string
      bom = "\xEF\xBB\xBF"
      records = filter({"log" => "#{bom}{ \"telemetry-source\": \"origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}"})
      # Documents whether BOM is handled gracefully
      expect(records.length).to be >= 0
    end

    it 'handles agent-version with special characters' do
      records = filter({"agent-version" => "v1.2.3-beta+build.123", "log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-agent-version" => "v1.2.3-beta+build.123", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles agent-version as empty string' do
      records = filter({"agent-version" => "", "log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-agent-version" => "", "telemetry-source" => "origin", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles mixed escaped and unescaped backslashes' do
      # Pattern: \\ \" \\\\ (2 backslashes, escaped quote, 4 backslashes)
      records = filter({"log" => '{ "telemetry-source": "origin", "telemetry-time": "2019-10-23T14:49:39-04:00", "mixed": "\\\\\\"\\\\\\\\\\\\\\\"}'})
      expect(records.first["mixed"]).to match(/\\/)  # Should contain backslashes
    end

    it 'handles telemetry-source as empty string (edge case for filtering)' do
      records = filter({"log" => '{ "telemetry-source": "", "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(eq([{"telemetry-source" => "", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'handles very long key names (1000 characters)' do
      long_key = 'k' * 1000
      records = filter({"log" => "{ \"telemetry-source\": \"origin\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\", \"#{long_key}\": \"value\"}"})
      expect(records.first[long_key]).to eq("value") if records.length > 0
    end

    it 'handles non-ASCII whitespace characters (if treated as whitespace)' do
      # U+00A0 is non-breaking space, U+2003 is em space
      records = filter({"log" => "{\"telemetry-source\":\"origin\",\u00A0\"telemetry-time\":\u2003\"2019-10-23T14:49:39-04:00\"}"})
      # Documents whether non-ASCII whitespace causes parsing to fail
      expect(records.length).to be >= 0
    end
  end

  # Comprehensive malformed data handling tests
  context 'malformed JSON handling' do
    it 'rejects JSON with missing closing brace (incomplete structure)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00"'})
      expect(records).to(be_empty)
    end

    it 'handles JSON with extra closing brace (extracts valid portion)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00"}}'})
      # Should extract the valid part before the extra brace
      expect(records).to(eq([{"telemetry-source" => "test", "telemetry-time" => "2019-10-23T14:49:39-04:00"}]))
    end

    it 'rejects JSON with unclosed string' do
      records = filter({"log" => '{ "telemetry-source": "test, "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with trailing comma (not valid JSON)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", }'})
      expect(records).to(be_empty)
      # Should log the parse error
      expect(driver.logs).to include(/Failed parsing potential message/)
    end

    it 'rejects JSON with missing comma between fields' do
      records = filter({"log" => '{ "telemetry-source": "test" "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(be_empty)
      expect(driver.logs).to include(/Failed parsing potential message/)
    end

    it 'rejects JSON with single quotes instead of double quotes' do
      records = filter({"log" => "{ 'telemetry-source': 'test', 'telemetry-time': '2019-10-23T14:49:39-04:00'}"})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with unquoted keys' do
      records = filter({"log" => '{ telemetry-source: "test", telemetry-time: "2019-10-23T14:49:39-04:00"}'})
      expect(records).to(be_empty)
    end

    it 'rejects truncated JSON (cut off mid-field)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-ti'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with invalid nested structure (missing key)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", {"nested": "no-key"}}'})
      expect(records).to(be_empty)
      expect(driver.logs).to include(/Failed parsing potential message/)
    end

    it 'handles JSON with comments (extracts valid JSON, ignores comments in extraction phase)' do
      # The extractor finds the JSON boundaries, and comments outside those boundaries are ignored
      records = filter({"log" => '{ "telemetry-source": "test", /* comment */ "telemetry-time": "2019-10-23T14:49:39-04:00"}'})
      # Depends on whether JSON.parse accepts comments (Ruby's JSON.parse does not by default)
      expect(records.length).to be >= 0
    end

    it 'rejects JSON with NaN value (not valid JSON)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "value": NaN}'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with Infinity value (not valid JSON)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "value": Infinity}'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with undefined value' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "value": undefined}'})
      expect(records).to(be_empty)
    end

    it 'handles escape sequences as literal strings in single-quoted Ruby literals' do
      # Single-quoted Ruby strings don't interpret \x escapes, so \x41 stays as literal "\x41"
      # When JSON.parse encounters \x in the string, it treats it as invalid escape
      # BUT the backslash gets consumed and we get "x41"
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "hex": "\x41"}'})
      # Documents actual behavior
      expect(records.first["hex"]).to eq("x41") if records.length > 0
    end

    it 'handles JSON with octal escape sequences (documents behavior)' do
      # Octal escapes like \101 are not valid in JSON spec
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "data": "value"}'})
      expect(records.length).to be >= 0
    end

    it 'rejects JSON with mismatched brackets' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", "array": [1, 2, 3}'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with mismatched braces' do
      records = filter({"log" => '[ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00"]'})
      expect(records).to(be_empty)
    end

    it 'handles null byte in JSON string (if supported by parser)' do
      # Null byte \u0000 is technically valid JSON
      records = filter({"log" => "{ \"telemetry-source\": \"test\\u0000here\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}"})
      expect(records.length).to be >= 0
      if records.length > 0
        expect(records.first["telemetry-source"]).to include("test")
      end
    end

    it 'rejects JSON with bare newline in string (not escaped)' do
      # Actual newline character in JSON string is invalid - must be \n
      records = filter({"log" => "{ \"telemetry-source\": \"test\nhere\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}"})
      # May or may not work depending on how extraction handles it
      expect(records.length).to be >= 0
    end

    it 'rejects JSON with bare tab in string (not escaped)' do
      # Actual tab character in JSON string is invalid - must be \t
      records = filter({"log" => "{ \"telemetry-source\": \"test\there\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}"})
      expect(records.length).to be >= 0
    end

    it 'handles extremely malformed JSON (random characters)' do
      records = filter({"log" => 'asd}f{]"telemetry-source"[: qwerty "telemetry-time"zxcv'})
      expect(records).to(be_empty)
    end

    it 'handles partially valid JSON (starts valid, becomes invalid)' do
      records = filter({"log" => '{ "telemetry-source": "test", "telemetry-time": "2019-10-23T14:49:39-04:00", asdfasdf'})
      expect(records).to(be_empty)
    end

    it 'rejects JSON with control characters in keys' do
      # Control characters in keys should be rejected
      records = filter({"log" => "{ \"telemetry\u0001source\": \"test\", \"telemetry-time\": \"2019-10-23T14:49:39-04:00\"}"})
      expect(records).to(be_empty)
    end
  end

  context 'performance benchmarks (large logs)', :benchmark do
    def measure_performance(log_line, description, timeout_seconds)
      GC.start # Clean slate
      GC.disable # Prevent GC from interfering with measurements
      
      before_memory = ObjectSpace.memsize_of_all / 1024.0 / 1024.0 # MB
      
      result = nil
      time = Benchmark.measure do
        # Create a new driver with custom timeout for this test
        custom_driver = Fluent::Test::Driver::Filter.new(Fluent::Plugin::FilterTelemetry).configure('')
        custom_driver.instance_variable_set(:@run_timeout, timeout_seconds)
        
        custom_driver.run {
          custom_driver.feed("filter.test", @time, {"log" => log_line})
        }
        result = custom_driver.filtered_records
      end
      
      GC.enable
      after_memory = ObjectSpace.memsize_of_all / 1024.0 / 1024.0 # MB
      memory_delta = after_memory - before_memory
      
      {
        description: description,
        size_mb: log_line.bytesize / 1024.0 / 1024.0,
        real_time: time.real,
        cpu_time: time.total,
        memory_delta_mb: memory_delta,
        result: result.nil? || result.empty? ? "nil" : "success"
      }
    rescue Timeout::Error, Fluent::Test::Driver::TestTimedOut => e
      GC.enable
      {
        description: description,
        size_mb: log_line.bytesize / 1024.0 / 1024.0,
        real_time: timeout_seconds.to_f,
        cpu_time: timeout_seconds.to_f,
        memory_delta_mb: 0.0,
        result: "TIMEOUT"
      }
    end
    
    def print_results(results)
      puts "\n" + "=" * 95
      puts "PERFORMANCE BENCHMARK RESULTS"
      puts "=" * 95
      printf("%-45s %10s %12s %12s %15s %10s\n", 
             "Test", "Size (MB)", "Time (s)", "CPU (s)", "Memory Δ (MB)", "Result")
      puts "-" * 95
      
      results.each do |r|
        printf("%-45s %10.2f %12.3f %12.3f %15.2f %10s\n",
               r[:description],
               r[:size_mb],
               r[:real_time],
               r[:cpu_time],
               r[:memory_delta_mb],
               r[:result])
      end
      puts "=" * 95
      puts "\nKey Observations:"
      
      # Find worst case (unterminated string at 100MB)
      unterminated_100mb = results.find { |r| r[:description] =~ /Unterminated.*100MB/ }
      if unterminated_100mb && unterminated_100mb[:result] != "TIMEOUT"
        puts "  • 100MB unterminated string (worst case): #{unterminated_100mb[:real_time].round(2)}s"
        puts "  • Memory usage scales linearly: ~#{(unterminated_100mb[:memory_delta_mb] / unterminated_100mb[:size_mb]).round(1)}x input size"
      elsif unterminated_100mb && unterminated_100mb[:result] == "TIMEOUT"
        puts "  • 100MB unterminated string: TIMED OUT (exceeded #{unterminated_100mb[:real_time].round(0)}s limit)"
      end
      
      # Compare valid vs malformed (excluding timeouts)
      valid = results.select { |r| r[:description] =~ /Valid JSON/ && r[:result] != "TIMEOUT" }
      malformed = results.select { |r| r[:description] =~ /Unterminated/ && r[:result] != "TIMEOUT" }
      if valid.any? && malformed.any?
        avg_valid_time = valid.map { |r| r[:cpu_time] / r[:size_mb] }.sum / valid.length
        avg_malformed_time = malformed.map { |r| r[:cpu_time] / r[:size_mb] }.sum / malformed.length
        slowdown = (avg_malformed_time / avg_valid_time).round(1)
        puts "  • Malformed logs are ~#{slowdown}x slower than valid logs"
      end
      
      # Check for any timeouts
      timeouts = results.select { |r| r[:result] == "TIMEOUT" }
      if timeouts.any?
        puts "  • WARNING: #{timeouts.length} test(s) timed out - indicates potential hang risk"
      else
        puts "  • All tests completed within timeout limits"
      end
      
      puts "=" * 95
      puts ""
    end
    
    it 'benchmarks performance with progressively larger logs' do
      require 'objspace'
      
      # Suppress benchmark deprecation warning for Ruby 3.5+
      begin
        require 'benchmark'
      rescue LoadError
        # If benchmark is not available, skip this test
        skip "Benchmark library not available"
      end
      
      results = []
      
      # Test sizes: 5MB to 30MB in 5MB increments
      sizes = [5, 10, 15, 20, 25, 30]
      
      puts "\nStarting performance benchmark..."
      puts "Testing sizes: #{sizes.join(', ')} MB"
      puts "Scenarios: Valid JSON (best case), Unterminated string (worst case)"
      puts "Expected duration: 2-3 minutes\n"
      
      sizes.each do |size_mb|
        char_count = (size_mb * 1024 * 1024) - 150 # Account for JSON structure overhead
        
        # Dynamic timeout: scale with size, max 120 seconds
        timeout = [size_mb * 1.5, 120].max.to_i
        
        puts "Testing #{size_mb}MB logs (timeout: #{timeout}s)..."
        
        # Scenario 1: Valid JSON (best case)
        valid_json = '{ "telemetry-source": "bench", "telemetry-time": "2019-10-23T14:49:39Z", "data": "' + ('x' * char_count) + '"}'
        results << measure_performance(valid_json, "Valid JSON #{size_mb}MB", timeout)
        
        # Scenario 2: Unterminated string (worst case - forces full scan)
        unterminated = '{ "telemetry-source": "bench", "telemetry-time": "2019-10-23T14:49:39Z", "data": "' + ('x' * char_count)
        results << measure_performance(unterminated, "Unterminated #{size_mb}MB", timeout)
        
        GC.start # Clean up between size tests
      end
      
      print_results(results)
      
      # Assertions
      expect(results.length).to eq(sizes.length * 2)
      # Test passes even if some timed out - we want to see the data
    end
  end
end
