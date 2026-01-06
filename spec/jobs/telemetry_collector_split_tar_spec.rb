require 'spec_helper'
require 'json'
require 'fileutils'

describe 'Telemetry Collector Split TAR Handling' do
  describe 'multiple TAR file handling' do
    it 'simulates single TAR file scenario (default behavior)' do
      result = simulate_tar_handling(
        tar_files: ["/var/vcap/data/telemetry-collector/FoundationDetails_1234567890.tar"],
        send_exit_codes: [0],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:send_successes]).to eq(1)
      expect(result[:send_failures]).to eq(0)
      expect(result[:log_entries].length).to eq(1)
      expect(result[:log_entries].first['status']).to eq('success')
    end

    it 'simulates split TAR file scenario (both succeed)' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
        ],
        send_exit_codes: [0, 0],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:send_successes]).to eq(2)
      expect(result[:send_failures]).to eq(0)
      expect(result[:log_entries].length).to eq(2)
      expect(result[:log_entries].all? { |e| e['status'] == 'success' }).to be true
    end

    it 'simulates split TAR file scenario (one fails, one succeeds)' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
        ],
        send_exit_codes: [0, 1],
        send_outputs: ["", "503 Service Unavailable"],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)  # Should not fail installation
      expect(result[:send_successes]).to eq(1)
      expect(result[:send_failures]).to eq(1)
      expect(result[:log_entries].length).to eq(2)
      
      success_entries = result[:log_entries].select { |e| e['status'] == 'success' }
      failure_entries = result[:log_entries].select { |e| e['error_type'] }
      
      expect(success_entries.length).to eq(1)
      expect(failure_entries.length).to eq(1)
      expect(failure_entries.first['error_type']).to eq('MIDDLEWARE_PIPELINE_ERROR')
    end

    it 'simulates split TAR file scenario (both fail)' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
        ],
        send_exit_codes: [1, 1],
        send_outputs: ["401 Unauthorized", "401 Unauthorized"],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)  # Should not fail installation
      expect(result[:send_successes]).to eq(0)
      expect(result[:send_failures]).to eq(2)
      expect(result[:log_entries].length).to eq(2)
      expect(result[:log_entries].all? { |e| e['error_type'] == 'CUSTOMER_CONFIG_ERROR' }).to be true
    end

    it 'simulates no TAR files found scenario' do
      result = simulate_tar_handling(
        tar_files: [],
        send_exit_codes: [],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(1)
      expect(result[:stderr_output].join(' ')).to include('ERROR: No tarball found after collection')
    end

    it 'simulates audit mode with multiple TAR files' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
        ],
        send_exit_codes: [],  # Not used in audit mode
        audit_mode: true
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:send_successes]).to eq(0)
      expect(result[:send_failures]).to eq(0)
      expect(result[:log_entries]).to be_empty
      expect(result[:stderr_output].join(' ')).to include('INFO: Audit mode enabled')
    end
  end

  describe 'log entries include tar_file path' do
    it 'includes tar_file in failure log entry' do
      tar_file = "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar"
      log_entry = create_failure_log_entry(
        timestamp: "2024-01-15T10:30:00Z",
        error_type: "MIDDLEWARE_PIPELINE_ERROR",
        message: "Telemetry infrastructure is temporarily unavailable",
        exit_code: 1,
        tar_file: tar_file,
        output: "503 Service Unavailable"
      )
      
      parsed = JSON.parse(log_entry)
      expect(parsed['tar_file']).to eq(tar_file)
    end

    it 'includes tar_file in success log entry' do
      tar_file = "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
      log_entry = create_success_log_entry(
        timestamp: "2024-01-15T10:30:00Z",
        tar_file: tar_file
      )
      
      parsed = JSON.parse(log_entry)
      expect(parsed['tar_file']).to eq(tar_file)
    end
  end

  describe 'special character handling in filenames' do
    it 'handles filenames with spaces' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/Foundation Details_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/Foundation Details_1234567890_ceip.tar"
        ],
        send_exit_codes: [0, 0],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:send_successes]).to eq(2)
    end

    it 'handles filenames with special characters' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/Foundation_Details_[test]_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/Foundation_Details_$var_1234567890_ceip.tar"
        ],
        send_exit_codes: [0, 0],
        audit_mode: false
      )
      
      expect(result[:final_exit_code]).to eq(0)
      expect(result[:send_successes]).to eq(2)
    end

    it 'properly escapes special characters in JSON log entries' do
      tar_file = '/var/vcap/data/telemetry-collector/Foundation"Details_1234567890.tar'
      log_entry = create_success_log_entry(
        timestamp: "2024-01-15T10:30:00Z",
        tar_file: tar_file
      )
      
      # Should be valid JSON even with quotes in filename
      expect { JSON.parse(log_entry) }.not_to raise_error
    end

    it 'escapes backslashes in filenames for JSON' do
      tar_file = '/var/vcap/data/telemetry-collector/Foundation\\Details_1234567890.tar'
      log_entry = create_success_log_entry(
        timestamp: "2024-01-15T10:30:00Z",
        tar_file: tar_file
      )
      
      expect { JSON.parse(log_entry) }.not_to raise_error
    end

    it 'handles error output with special characters' do
      output_with_special_chars = "Error: file \"test.tar\" not found\nDetails: path=/var/vcap/data"
      log_entry = create_failure_log_entry(
        timestamp: "2024-01-15T10:30:00Z",
        error_type: "UNKNOWN_ERROR",
        message: "Telemetry send failed",
        exit_code: 1,
        tar_file: "/var/vcap/data/test.tar",
        output: output_with_special_chars
      )
      
      expect { JSON.parse(log_entry) }.not_to raise_error
    end
  end

  describe 'summary logging for multiple TAR files' do
    it 'logs summary when multiple TAR files are processed' do
      result = simulate_tar_handling(
        tar_files: [
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_operational.tar",
          "/var/vcap/data/telemetry-collector/FoundationDetails_1234567890_ceip.tar"
        ],
        send_exit_codes: [0, 1],
        send_outputs: ["", "503 Service Unavailable"],
        audit_mode: false
      )
      
      expect(result[:stderr_output].join(' ')).to include('Sent 1 of 2 TAR file(s) successfully')
      expect(result[:stderr_output].join(' ')).to include('1 of 2 TAR file(s) failed to send')
    end

    it 'does not log summary for single TAR file' do
      result = simulate_tar_handling(
        tar_files: ["/var/vcap/data/telemetry-collector/FoundationDetails_1234567890.tar"],
        send_exit_codes: [0],
        audit_mode: false
      )
      
      expect(result[:stderr_output].join(' ')).not_to include('TAR file(s)')
    end
  end

  private

  def classify_error_type(output)
    if output.downcase.match?(/unauthorized|not authorized|401/)
      'CUSTOMER_CONFIG_ERROR'
    elsif output.downcase.match?(/kinit.*not found|curl.*not found|gss-api/)
      'SYSTEM_REQUIREMENTS_ERROR'
    elsif output.downcase.match?(/connection refused|timeout|503|502|504/)
      'MIDDLEWARE_PIPELINE_ERROR'
    elsif output.downcase.match?(/proxy.*authentication|407|spnego|kerberos/)
      'PROXY_AUTH_ERROR'
    else
      'UNKNOWN_ERROR'
    end
  end

  def error_message_for_type(error_type)
    case error_type
    when 'CUSTOMER_CONFIG_ERROR'
      'API key is invalid or expired'
    when 'SYSTEM_REQUIREMENTS_ERROR'
      'SPNEGO system requirements not met - kinit or curl with GSS-API missing'
    when 'MIDDLEWARE_PIPELINE_ERROR'
      'Telemetry infrastructure is temporarily unavailable'
    when 'PROXY_AUTH_ERROR'
      'Proxy authentication failed - check proxy credentials'
    else
      'Telemetry send failed'
    end
  end

  def create_failure_log_entry(timestamp:, error_type:, message:, exit_code:, tar_file:, output:)
    # Ruby's to_json properly escapes special characters
    {
      timestamp: timestamp,
      error_type: error_type,
      message: message,
      exit_code: exit_code,
      tar_file: tar_file,
      output: output
    }.to_json
  end

  def create_success_log_entry(timestamp:, tar_file:)
    # Ruby's to_json properly escapes special characters
    {
      timestamp: timestamp,
      status: 'success',
      message: 'Telemetry sent successfully during startup',
      tar_file: tar_file
    }.to_json
  end

  def simulate_tar_handling(tar_files:, send_exit_codes:, send_outputs: nil, audit_mode: false)
    log_entries = []
    stderr_output = []
    send_successes = 0
    send_failures = 0
    
    # Handle empty tar_files case
    if tar_files.empty?
      stderr_output << "ERROR: No tarball found after collection"
      return {
        final_exit_code: 1,
        send_successes: 0,
        send_failures: 0,
        log_entries: log_entries,
        stderr_output: stderr_output
      }
    end
    
    tar_count = tar_files.length
    stderr_output << "DEBUG: Found #{tar_count} tarball(s): #{tar_files.join(' ')}"
    stderr_output << "DEBUG: Audit mode: #{audit_mode}"
    
    # Handle audit mode
    if audit_mode
      stderr_output << "INFO: Audit mode enabled - data collected but not sent"
      return {
        final_exit_code: 0,
        send_successes: 0,
        send_failures: 0,
        log_entries: log_entries,
        stderr_output: stderr_output
      }
    end
    
    # Process each TAR file
    send_outputs ||= Array.new(tar_files.length, "")
    
    tar_files.each_with_index do |tar_file, index|
      stderr_output << "DEBUG: Sending tarball: #{tar_file}"
      
      exit_code = send_exit_codes[index]
      output = send_outputs[index]
      timestamp = generate_timestamp
      
      if exit_code != 0
        send_failures += 1
        error_type = classify_error_type(output)
        error_msg = error_message_for_type(error_type)
        
        log_entry = {
          'timestamp' => timestamp,
          'error_type' => error_type,
          'message' => error_msg,
          'exit_code' => exit_code,
          'tar_file' => tar_file,
          'output' => output
        }
        log_entries << log_entry
        
        stderr_output << "WARNING: Telemetry send failed for #{tar_file} - data collected successfully and will be retried by cron job"
        stderr_output << "  Error type: #{error_type}"
        stderr_output << "  Details: #{error_msg}"
      else
        send_successes += 1
        
        log_entry = {
          'timestamp' => timestamp,
          'status' => 'success',
          'message' => 'Telemetry sent successfully during startup',
          'tar_file' => tar_file
        }
        log_entries << log_entry
      end
    end
    
    # Log summary for multiple TAR files
    if tar_count > 1
      stderr_output << "INFO: Sent #{send_successes} of #{tar_count} TAR file(s) successfully"
      if send_failures > 0
        stderr_output << "WARNING: #{send_failures} of #{tar_count} TAR file(s) failed to send"
      end
    end
    
    {
      final_exit_code: 0,
      send_successes: send_successes,
      send_failures: send_failures,
      log_entries: log_entries,
      stderr_output: stderr_output
    }
  end

  def generate_timestamp
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end

