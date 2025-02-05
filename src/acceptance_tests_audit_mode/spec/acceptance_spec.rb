require 'rspec'
require 'json'
require 'net/http'
require 'date'
require 'time'

describe 'Agent to centralizer communication' do
  let(:client) {
    uri = URI(ENV["LOADER_URL"])
    client = Net::HTTP.new(uri.hostname, uri.port)
    client.use_ssl = true
    client.verify_mode = OpenSSL::SSL::VERIFY_NONE
    client
  }

  def insert_telemetry_msg_log(message)
    # telemetry-agent-acceptance-audit
    # telemetry-agent
    `#{ENV["BOSH_CLI"]} -d #{ENV["AGENT_BOSH_DEPLOYMENT"]} ssh #{ENV["AGENT_BOSH_INSTANCE"]} -c 'echo '"'"'#{message}'"'"' | sudo tee -a /var/vcap/sys/log/bpm/telemetry-messages.stdout.log'`
    expect($?).to(be_success)
  end

  def get_centralizer_logs
    # telemetry-centralizer-acceptance-audit
    logs = `#{ENV["BOSH_CLI"]} -d #{ENV["CENTRALIZER_BOSH_DEPLOYMENT"]} ssh telemetry-centralizer -c 'sudo grep my-origin /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log | tail -20'`
    expect($?).to(be_success)
    return logs.split("\n")
  end

  def get_centralizer_audit_logs
    # telemetry-centralizer-acceptance-audit
    logs = `#{ENV["BOSH_CLI"]} -d #{ENV["CENTRALIZER_BOSH_DEPLOYMENT"]} ssh telemetry-centralizer -c 'sudo grep my-origin /var/vcap/sys/log/telemetry-centralizer/audit.log | tail -20'`
    expect($?).to(be_success)
    logs.split("\n").collect do |log|
      log = log.split("|").last
      begin
        JSON.parse(log)
      rescue
        nil
      end
    end.compact
  end

  def get_agent_logs
    # messages get sent here
    logs = `#{ENV["BOSH_CLI"]} -d #{ENV["AGENT_BOSH_DEPLOYMENT"]} ssh #{ENV["AGENT_BOSH_INSTANCE"]} -c 'sudo grep my-origin /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log | tail -20'`
    expect($?).to(be_success)
    return logs.split("\n")
  end

  def fetch_messages
    res = client.get("/received_messages", {'Authorization' => "Bearer #{ENV["LOADER_API_KEY"]}"})
    expect(res.code).to eq("200")
    JSON.parse(res.body)
  end

  def fetch_batch_messages
    res = client.get("/received_batch_messages", {'Authorization' => "Bearer #{ENV["LOADER_API_KEY"]}"})
    expect(res.code).to eq("200")
    JSON.parse(res.body)
  end

  def extract_json_from_message_line_matching(messages, regex)
    message = messages.find {|message| message =~ regex}
    json_extract_regex = /({.*})\s*$/
    json_part = json_extract_regex.match(message)[1]
    JSON.parse(json_part)
  end

  def wait_for(timeout, message)
    start = Time.now
    x = yield
    until x
      if Time.now - start > timeout
        raise "Timeout #{timeout} sec: #{message}"
      end
      sleep(1)
      x = yield
    end
  end

  before do
    fail("Need BOSH_CLI set to execute BOSH commands") unless ENV["BOSH_CLI"]
    fail("Missing LOADER_URL") unless ENV["LOADER_URL"]
    fail("Missing LOADER_API_KEY") unless ENV["LOADER_API_KEY"]
    fail("Missing EXPECTED_ENV_TYPE") unless ENV["EXPECTED_ENV_TYPE"]
    fail("Missing EXPECTED_IAAS_TYPE") unless ENV["EXPECTED_IAAS_TYPE"]
    fail("Missing EXPECTED_FOUNDATION_ID") unless ENV["EXPECTED_FOUNDATION_ID"]
    fail("Missing CENTRALIZER_BOSH_DEPLOYMENT") unless ENV["CENTRALIZER_BOSH_DEPLOYMENT"]
    fail("Missing AGENT_BOSH_DEPLOYMENT") unless ENV["AGENT_BOSH_DEPLOYMENT"]
    fail("Missing AGENT_BOSH_INSTANCE") unless ENV["AGENT_BOSH_INSTANCE"]

    res = client.post("/clear_messages", nil, {'Authorization' => "Bearer #{ENV["LOADER_API_KEY"]}"})
    expect(res.code).to eq("200")
  end

  it "sends logs matching 'telemetry-source' and containing an RFC 3339 formatted 'telemetry-time' to the centralizer, which does not send to a loader" do
    counter_value = Time.now.tv_sec
    telemetry_time_value = Time.now.to_datetime.rfc3339

    message_format = <<-'EOF'
{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\"ta\", \"counter\": \"%s\"}, \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"%s\"}"
    EOF
    insert_telemetry_msg_log(sprintf(message_format, counter_value, telemetry_time_value))

    wait_for(120, "Messages were received by the loader") do
      messages = fetch_messages
      messages.empty?
    end

    agent_line_match_regex = /Message received:.*#{counter_value}/
    logged_agent_messages = get_agent_logs
    expect(logged_agent_messages).to include(an_object_satisfying {|message| message =~ agent_line_match_regex})
  end

  it "when audit mode is set, sends logs matching 'telemetry-source' to audit.log, along with centralizer_logs" do
    counter_value = Time.now.tv_sec
    telemetry_time_value = Time.now.to_datetime.rfc3339

    message_format = <<-'EOF'
{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\"ta\", \"counter\": \"%s\"}, \"telemetry-source\": \"my-origin\", \"telemetry-time\": \"%s\"}"
  EOF
    insert_telemetry_msg_log(sprintf(message_format, counter_value, telemetry_time_value))

    sleep 10

    expected_telemetry_message = {
      "data" => {
        "app" => 'da"ta',
        "counter" => counter_value.to_s
      },
      "telemetry-source" => "my-origin",
      "telemetry-time" => telemetry_time_value,
      "telemetry-agent-version" => "0.0.1",
      "telemetry-centralizer-version" => "0.0.2",
      "telemetry-env-type" => ENV["EXPECTED_ENV_TYPE"],
      "telemetry-iaas-type" => ENV["EXPECTED_IAAS_TYPE"],
      "telemetry-foundation-id" => ENV["EXPECTED_FOUNDATION_ID"],
      "telemetry-foundation-nickname" => ENV["EXPECTED_FOUNDATION_NICKNAME"],
    }

    audit_messages = get_centralizer_audit_logs
    expect(audit_messages).to include(expected_telemetry_message)
  end

  it "does not send ops manager telemetry data via the telemetry-collector job" do
    sleep 120
    received_messages = fetch_batch_messages
    expect(received_messages).to be_empty
  end
end
