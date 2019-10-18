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
    client
  }

  def insert_telemetry_msg_log(message)
    `#{ENV["BOSH_CLI"]} -d #{ENV["AGENT_BOSH_DEPLOYMENT"]} ssh #{ENV["AGENT_BOSH_INSTANCE"]} -c 'echo '"'"'#{message}'"'"' | sudo tee -a /var/vcap/sys/log/bpm/telemetry-messages.stdout.log'`
    expect($?).to(be_success)
  end

  def get_centralizer_logs
    logs = `#{ENV["BOSH_CLI"]} -d #{ENV["CENTRALIZER_BOSH_DEPLOYMENT"]} ssh telemetry-centralizer -c 'sudo tail -20 /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log'`
    expect($?).to(be_success)
    return logs.split("\n")
  end

  def get_agent_logs
    logs = `#{ENV["BOSH_CLI"]} -d #{ENV["AGENT_BOSH_DEPLOYMENT"]} ssh telemetry-agent -c 'sudo tail -20 /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log'`
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

  it "sends logs matching 'telemetry-source' to the centralizer which sends to a loader, adding agent and centralizer versions to the message" do
    time_value = Time.now.tv_sec
    message_format = <<-'EOF'
{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\"ta\", \"counter\": \"%s\"}, \"telemetry-source\": \"my-origin\"}"
    EOF
    insert_telemetry_msg_log(sprintf(message_format, time_value))

    sleep 15 # wait for flush from centralizer to loader

    expected_telemetry_message = {
      "data" => {
        "app" => 'da"ta',
        "counter" => time_value.to_s
      },
      "telemetry-source" => "my-origin",
      "telemetry-agent-version" => "0.0.1",
      "telemetry-centralizer-version" => "0.0.1",
      "telemetry-env-type" => ENV["EXPECTED_ENV_TYPE"],
      "telemetry-iaas-type" => ENV["EXPECTED_IAAS_TYPE"],
      "telemetry-foundation-id" => ENV["EXPECTED_FOUNDATION_ID"],
    }

    received_messages = fetch_messages
    expect(received_messages).to include(expected_telemetry_message)

    logged_agent_messages = get_agent_logs
    line_match_regex = /Message forwarded:.*#{time_value}/
    expect(logged_agent_messages).to include(an_object_satisfying {|message| message =~ line_match_regex})
  end


  it "tests that logs not matching the expected structure are filtered out by the centralizer" do
    time_value = Time.now.tv_sec
    message_format = <<-'EOF'
NOT a telemetry-source msg
    EOF
    insert_telemetry_msg_log(sprintf(message_format, time_value))

    sleep 5

    logged_messages = get_centralizer_logs
    line_match_regex = /#{time_value}/
    expect(logged_messages).not_to include(an_object_satisfying {|message| message =~ line_match_regex})
  end

  it "can collect and send ops manager telemetry data via the telemetry-collector job" do
    sleep 120
    received_messages = fetch_batch_messages

    messagesForFoundation = received_messages.select do |message|
      collected_at = DateTime.parse(message["CollectedAt"]).to_time.utc
      received_within_the_last_three_minutes = Time.now.utc - collected_at <= 180
      true if message["FoundationId"] == ENV["EXPECTED_FOUNDATION_ID"] && received_within_the_last_three_minutes
    end

    expect(messagesForFoundation).to include(an_object_satisfying {|message| message["Dataset"] == "opsmanager" })
    expect(messagesForFoundation).to include(an_object_satisfying {|message| message["Dataset"] == "usage_service" })
  end
end
