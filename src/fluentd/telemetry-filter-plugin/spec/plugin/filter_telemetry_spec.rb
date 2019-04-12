require_relative '../spec_helper'
require_relative '../../lib/fluent/plugin/filter_telemetry'


describe 'Filters telemetry messages' do
  include Fluent::Test::Helpers

  before do
    Fluent::Test.setup
    @time = event_time
  end

  def create_filter_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::FilterTelemetry).configure('')
  end

  def filter(message)
    driver = create_filter_driver
    driver.run {
      driver.feed("filter.test", @time, message)
    }
    expect(driver.error_events).to(be_empty)
    driver.filtered_records
  end

  it 'returns telemetry messages' do
    records = filter({"log" => '{ "telemetry-source": "my-origin", "data": {"app": "da\"ta", "counter": 42, "array": [ {"cool":"value"} ]}}'})

    expect(records).to(eq([{ "data" => {"app" => 'da"ta', "counter" => 42, "array" => [{"cool" => "value"}]}, "telemetry-source" => "my-origin"}]))
  end

  it 'returns telemetry messages when the telemetry message has object chars in the keys or values after the telemetry-source key' do
    records = filter({"log" => '{ "telemetry-source": "my-{origin", "data": {"}app": "d}ata"}} maybe some junk here'})
    expect(records).to(eq([{ "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin"}]))
  end

  it 'returns telemetry messages when the telemetry message has object chars in the keys or values before the telemetry-source key' do
    records = filter({"log" => '{ "data": {"}app": "d}ata"}, "telemetry-source": "my-{origin"} maybe some junk here'})
    expect(records).to(eq([{ "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin"}]))
  end

  context 'when telemetry messages appears as a JSON object embedded in other log lines' do
    it 'returns messages when nested in another JSON object' do
      records = filter({"log" => '{ "time": 12341234123412, "level": "info", "message": "whatever", "data": { "something": "else", "telemetry-thing": { "telemetry-source": "my-origin", "data": {"app": "da\"ta", "counter": 42, "array": [ {"cool":"value"} ]}}, "more": "otherthings"}'})
      expect(records).to(eq([{ "data" => {"app" => 'da"ta', "counter" => 42, "array" => [ { "cool" => "value" }]}, "telemetry-source" => "my-origin"}]))
    end

    it 'returns messages embedded in an arbitrary string' do
      records = filter({"log" => 'Tue 14-Mar-2019 [Thread-14] com.java.SillyClass myhostname { "telemetry-source": "my-origin", "data": {"app": "data"}} maybe some junk here'})
      expect(records).to(eq([{ "data" => {"app" => "data"}, "telemetry-source" => "my-origin"}]))
    end
  end

  context 'when telemetry messages are embedded as escaped json strings' do
    it 'returns messages' do
      records = filter({"log" => '{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\\\"ta\", \"counter\": 42}, \"telemetry-source\": \"my-origin\"}" }'})
      expect(records).to(eq([{ "data" => {"app" => 'da"ta', "counter" => 42}, "telemetry-source" => "my-origin"}]))
    end

    it 'returns messages that have object chars in the keys or values after the telemetry-source key' do
      records = filter({"log" => '{ \"telemetry-source\": \"my-{origin\", \"data\": {\"}app\": \"d}ata\"}} maybe some junk here'})
      expect(records).to(eq([{ "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin"}]))
    end

    it 'returns messages that have object chars in the keys or values after the telemetry-source key' do
      records = filter({"log" => '{ \"data\": {\"}app\": \"d}ata\"}, \"telemetry-source\": \"my-{origin\"} maybe some junk here'})
      expect(records).to(eq([{ "data" => {"}app" => "d}ata"}, "telemetry-source" => "my-{origin"}]))
    end
  end

  it 'reject messages with correct number of object closing braces that is not valid JSON' do
      records = filter({"log" => '{"telemetry-source": "somethign", {"invalid-object": "missing-close"}}'})
      expect(records).to(be_empty)
  end

  it 'rejects messages without a log key' do
    expect(filter({"other" => "key"})).to(be_empty)
  end

  it 'rejects messages with a log key that does not contain "telemetry-source"' do
    records = filter({"log" => "some log line"})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing "telemetry-source" that is not a json key' do
    records = filter({"log" => '"telemetry-source"'})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing an escaped "telemetry-source" that is not a json key' do
    records = filter({"log" => '\"telemetry-source\"'})
    expect(records).to(be_empty)
  end

  it 'rejects messages with a log key containing "telemetry-source" but contains invalid json' do
    records = filter({"log" => '{ "message": "{ "data": "invalid": "structure"}, "telemetry-source": "my-origin"}" }'})
    expect(records).to(be_empty)
  end
end
