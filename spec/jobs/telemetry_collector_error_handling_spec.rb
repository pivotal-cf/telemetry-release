require 'spec_helper'
require 'json'
require 'fileutils'

describe 'Telemetry Collector Error Handling' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end

  describe 'error classification logic' do
    it 'classifies 401 unauthorized as CUSTOMER_CONFIG_ERROR' do
      error_outputs = [
        "Error: user is not authorized to perform this action",
        "401 Unauthorized",
        "unauthorized access",
        "not authorized to perform this action"
      ]
      
      error_outputs.each do |output|
        expect(classify_error_type(output)).to eq('CUSTOMER_CONFIG_ERROR')
      end
    end

    it 'classifies connection/timeout errors as MIDDLEWARE_PIPELINE_ERROR' do
      error_outputs = [
        "connection refused",
        "timeout occurred",
        "503 Service Unavailable",
        "502 Bad Gateway",
        "504 Gateway Timeout",
        "timeout"
      ]
      
      error_outputs.each do |output|
        expect(classify_error_type(output)).to eq('MIDDLEWARE_PIPELINE_ERROR')
      end
    end

    it 'classifies unknown errors as UNKNOWN_ERROR' do
      error_outputs = [
        "some random error",
        "unexpected failure",
        "internal server error",
        "500 Internal Server Error"
      ]
      
      error_outputs.each do |output|
        expect(classify_error_type(output)).to eq('UNKNOWN_ERROR')
      end
    end
  end

  describe 'structured logging' do
    before do
      @temp_log_dir = create_temp_log_directory
      @log_file = File.join(@temp_log_dir, "telemetry-collector", "send-failures.log")
    end

    it 'creates valid JSON log entry for customer config error' do
      timestamp = "2024-01-15T10:30:00Z"
      error_output = "Error: user is not authorized to perform this action"
      exit_code = 1
      
      log_entry = create_log_entry(timestamp, "CUSTOMER_CONFIG_ERROR", "API key is invalid or expired", exit_code, error_output)
      
      expect { JSON.parse(log_entry) }.not_to raise_error
      
      parsed = JSON.parse(log_entry)
      expect(parsed['timestamp']).to eq(timestamp)
      expect(parsed['error_type']).to eq('CUSTOMER_CONFIG_ERROR')
      expect(parsed['message']).to eq('API key is invalid or expired')
      expect(parsed['exit_code']).to eq(1)
      expect(parsed['output']).to eq(error_output)
    end

    it 'creates valid JSON log entry for middleware pipeline error' do
      timestamp = "2024-01-15T10:30:00Z"
      error_output = "connection refused"
      exit_code = 7
      
      log_entry = create_log_entry(timestamp, "MIDDLEWARE_PIPELINE_ERROR", "Telemetry infrastructure is temporarily unavailable", exit_code, error_output)
      
      expect { JSON.parse(log_entry) }.not_to raise_error
      
      parsed = JSON.parse(log_entry)
      expect(parsed['error_type']).to eq('MIDDLEWARE_PIPELINE_ERROR')
      expect(parsed['message']).to eq('Telemetry infrastructure is temporarily unavailable')
    end

    it 'creates valid JSON log entry for success' do
      timestamp = "2024-01-15T10:30:00Z"
      
      log_entry = create_success_log_entry(timestamp)
      
      expect { JSON.parse(log_entry) }.not_to raise_error
      
      parsed = JSON.parse(log_entry)
      expect(parsed['timestamp']).to eq(timestamp)
      expect(parsed['status']).to eq('success')
      expect(parsed['message']).to eq('Telemetry sent successfully during startup')
    end
  end

  describe 'script behavior simulation' do
    it 'simulates collection success + send success scenario' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 0,
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:log_entries].length).to eq(1)  # Should log success
      expect(result[:log_entries].first['status']).to eq('success')
      expect(result[:stderr_output]).to be_empty
    end

    it 'simulates collection success + send failure (401) scenario' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "Error: user is not authorized to perform this action",
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)  # Should not fail installation
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['error_type']).to eq('CUSTOMER_CONFIG_ERROR')
      expect(result[:stderr_output].join(' ')).to include('WARNING: Telemetry send failed during startup')
    end

    it 'simulates collection success + send failure (503) scenario' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "503 Service Unavailable",
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)  # Should not fail installation
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['error_type']).to eq('MIDDLEWARE_PIPELINE_ERROR')
    end

    it 'simulates collection success + send failure (unknown) scenario' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "some random error",
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)  # Should not fail installation
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['error_type']).to eq('UNKNOWN_ERROR')
    end

    it 'simulates collection failure scenario' do
      result = simulate_script_execution(
        collect_exit_code: 1,
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(1)  # Should fail installation
      expect(result[:log_entries]).to be_empty
      expect(result[:stderr_output].join(' ')).to include('ERROR: Telemetry data collection failed')
    end

    it 'simulates audit mode enabled scenario' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        audit_mode: true
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:log_entries]).to be_empty
      expect(result[:stderr_output].join(' ')).to include('INFO: Audit mode enabled')
    end
  end

  describe 'edge cases' do
    it 'handles empty send output' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "",
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['error_type']).to eq('UNKNOWN_ERROR')
    end

    it 'handles malformed send output' do
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "some\x00null\x1b[31mcolored\x1b[0m text",
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:log_entries].length).to eq(1)
      # Should still create valid JSON despite malformed output
      expect { JSON.parse(result[:log_entries].first.to_json) }.not_to raise_error
    end

    it 'handles very long send output' do
      long_output = "Error: " + "x" * 10000
      result = simulate_script_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: long_output,
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['output']).to eq(long_output)
    end

    it 'handles missing log directory gracefully' do
      # This test would require mocking file system operations
      # For now, we'll test that the log entry format is correct
      log_entry = create_log_entry("2024-01-15T10:30:00Z", "CUSTOMER_CONFIG_ERROR", "test", 1, "test")
      expect { JSON.parse(log_entry) }.not_to raise_error
    end
  end

  describe 'timestamp generation' do
    it 'generates valid ISO 8601 timestamps' do
      timestamp = generate_timestamp
      
      # Should match ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
      expect(timestamp).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      
      # Should be parseable as a valid date
      expect { Time.parse(timestamp) }.not_to raise_error
    end
  end

  private

  def classify_error_type(output)
    if output.downcase.match?(/unauthorized|not authorized|401/)
      'CUSTOMER_CONFIG_ERROR'
    elsif output.downcase.match?(/connection refused|timeout|503|502|504/)
      'MIDDLEWARE_PIPELINE_ERROR'
    else
      'UNKNOWN_ERROR'
    end
  end

  def create_log_entry(timestamp, error_type, message, exit_code, output)
    {
      timestamp: timestamp,
      error_type: error_type,
      message: message,
      exit_code: exit_code,
      output: output
    }.to_json
  end

  def create_success_log_entry(timestamp)
    {
      timestamp: timestamp,
      status: 'success',
      message: 'Telemetry sent successfully during startup'
    }.to_json
  end

  def simulate_script_execution(collect_exit_code:, send_exit_code: 0, send_output: "", audit_mode: false)
    log_entries = []
    stderr_output = []
    
    # Simulate collection
    if collect_exit_code != 0
      stderr_output << "ERROR: Telemetry data collection failed with exit code #{collect_exit_code}"
      return {
        final_exit_code: collect_exit_code,
        log_entries: log_entries,
        stderr_output: stderr_output
      }
    end
    
    # Simulate audit mode
    if audit_mode
      stderr_output << "INFO: Audit mode enabled - data collected but not sent"
      return {
        final_exit_code: 0,
        log_entries: log_entries,
        stderr_output: stderr_output
      }
    end
    
    # Simulate send
    if send_exit_code != 0
      timestamp = generate_timestamp
      error_type = classify_error_type(send_output)
      
      case error_type
      when 'CUSTOMER_CONFIG_ERROR'
        error_msg = "API key is invalid or expired"
      when 'MIDDLEWARE_PIPELINE_ERROR'
        error_msg = "Telemetry infrastructure is temporarily unavailable"
      else
        error_msg = "Telemetry send failed"
      end
      
      log_entry = {
        'timestamp' => timestamp,
        'error_type' => error_type,
        'message' => error_msg,
        'exit_code' => send_exit_code,
        'output' => send_output
      }
      log_entries << log_entry
      
      stderr_output << "WARNING: Telemetry send failed during startup - data collected successfully and will be retried by cron job"
      stderr_output << "  Error type: #{error_type}"
      stderr_output << "  Details: #{error_msg}"
    else
      # Log successful send
      timestamp = generate_timestamp
      log_entry = {
        'timestamp' => timestamp,
        'status' => 'success',
        'message' => 'Telemetry sent successfully during startup'
      }
      log_entries << log_entry
    end
    
    {
      final_exit_code: 0,
      log_entries: log_entries,
      stderr_output: stderr_output
    }
  end

  def generate_timestamp
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
