require 'rspec'
require 'json'

describe 'Agent to centralizer communication' do
  def insert_agent_log(message)
    `#{ENV["BOSH_CLI"]} -d telemetry-components-acceptance ssh telemetry-agent -c 'echo '"'"'#{message}'"'"' | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log'`
    expect($?).to(be_success)
  end

  def get_centralizer_logs
    logs = `#{ENV["BOSH_CLI"]} -d telemetry-components-acceptance ssh telemetry-centralizer -c 'sudo tail -20 /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log'`
    expect($?).to(be_success)
    return logs.split("\n")
  end

  def extract_json_from_log_line_matching(messages, regex)
    message = messages.find { |message| message =~ regex }
    json_extract_regex = /({.*})\s*$/
    json_part = json_extract_regex.match(message)[1]
    JSON.parse(json_part)
  end

  before do
    fail("Need BOSH_CLI set to execute BOSH commands") unless ENV["BOSH_CLI"]
  end

  it "sends logs matching 'telemetry-source' to the centralizer, adding agent and centralizer versions to the message" do
    time_value = Time.now.tv_sec
    message_format = <<-'EOF'
{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\"ta\", \"counter\": \"%s\"}, \"telemetry-source\": \"my-origin\"}
EOF
    insert_agent_log(sprintf(message_format, time_value))

    sleep 5

    logged_messages = get_centralizer_logs

    line_match_regex = /#{time_value}/
    expect(logged_messages).to include(an_object_satisfying { |message| message =~ line_match_regex })

    expect(extract_json_from_log_line_matching(logged_messages, line_match_regex)).to eq({
      "data" => {
        "app" => 'da"ta',
        "counter" => time_value.to_s
      },
      "telemetry-source" => "my-origin",
      "telemetry-agent-version" => "0.0.1",
      "telemetry-centralizer-version" => "0.0.1"
    })
  end

  it "tests that logs not matching the expected structure are filtered out by the centralizer" do
    time_value = Time.now.tv_sec
    message_format = <<-'EOF'
NOT a telemetry-source msg
EOF
    insert_agent_log(sprintf(message_format, time_value))

    sleep 5

    logged_messages = get_centralizer_logs
    line_match_regex = /#{time_value}/
    expect(logged_messages).not_to include(an_object_satisfying { |message| message =~ line_match_regex })
  end
end
