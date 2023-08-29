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
end
