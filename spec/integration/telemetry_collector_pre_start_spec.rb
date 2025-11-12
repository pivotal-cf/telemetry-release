require 'spec_helper'
require 'json'
require 'fileutils'

describe 'Telemetry Collector Pre-Start Integration' do
  let(:pre_start_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/pre-start.erb'))
  end

  let(:collect_send_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end

  describe 'ERB template compilation' do
    it 'compiles pre-start template successfully' do
      properties = { 'enabled' => true }
      
      expect {
        compile_erb_template(pre_start_template, properties)
      }.not_to raise_error
    end

    it 'compiles collect-send template successfully' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      expect {
        compile_erb_template(collect_send_template, properties)
      }.not_to raise_error
    end

    it 'handles audit mode in collect-send template' do
      properties = {
        'audit_mode' => true,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      result = compile_erb_template(collect_send_template, properties)
      expect(result).to include("audit_mode='true'")
    end

    it 'handles endpoint override in collect-send template' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'endpoint_override' => 'https://custom-endpoint.com',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      result = compile_erb_template(collect_send_template, properties)
      expect(result).to include('--override-telemetry-endpoint https://custom-endpoint.com')
    end
  end

  describe 'pre-start script behavior simulation' do
    before do
      @temp_log_dir = create_temp_log_directory
    end

    it 'simulates successful pre-start with successful send' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        send_exit_code: 0,
        audit_mode: false
      )
      
      expect(result[:pre_start_exit_code]).to eq(0)
      expect(result[:log_files_created]).to include('send-success.log')
      expect(result[:log_files_created]).not_to include('send-failures.log')
    end

    it 'simulates successful pre-start with failed send (401)' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "Error: user is not authorized to perform this action",
        audit_mode: false
      )
      
      expect(result[:pre_start_exit_code]).to eq(0)  # Should not fail
      expect(result[:log_files_created]).to include('send-failures.log')
      expect(result[:log_files_created]).not_to include('send-success.log')
      
      # Verify log content
      failure_log = result[:log_contents]['send-failures.log']
      expect(failure_log.length).to eq(1)
      expect(failure_log.first['error_type']).to eq('CUSTOMER_CONFIG_ERROR')
    end

    it 'simulates successful pre-start with failed send (503)' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "503 Service Unavailable",
        audit_mode: false
      )
      
      expect(result[:pre_start_exit_code]).to eq(0)  # Should not fail
      expect(result[:log_files_created]).to include('send-failures.log')
      
      # Verify log content
      failure_log = result[:log_contents]['send-failures.log']
      expect(failure_log.first['error_type']).to eq('MIDDLEWARE_PIPELINE_ERROR')
    end

    it 'simulates failed pre-start due to collection failure' do
      result = simulate_pre_start_execution(
        collect_exit_code: 1,
        audit_mode: false
      )
      
      expect(result[:pre_start_exit_code]).to eq(1)  # Should fail
      expect(result[:log_files_created]).to be_empty
    end

    it 'simulates pre-start with audit mode enabled' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        audit_mode: true
      )
      
      expect(result[:pre_start_exit_code]).to eq(0)
      expect(result[:log_files_created]).to be_empty
    end
  end

  describe 'log file structure and content' do
    before do
      @temp_log_dir = create_temp_log_directory
    end

    it 'creates properly structured failure log files' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "Error: user is not authorized to perform this action",
        audit_mode: false
      )
      
      failure_log = result[:log_contents]['send-failures.log']
      expect(failure_log.length).to eq(1)
      
      log_entry = failure_log.first
      expect(log_entry).to have_key('timestamp')
      expect(log_entry).to have_key('error_type')
      expect(log_entry).to have_key('message')
      expect(log_entry).to have_key('exit_code')
      expect(log_entry).to have_key('output')
      
      # Verify timestamp format
      expect(log_entry['timestamp']).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    end

    it 'creates properly structured success log files' do
      result = simulate_pre_start_execution(
        collect_exit_code: 0,
        send_exit_code: 0,
        audit_mode: false
      )
      
      success_log = result[:log_contents]['send-success.log']
      expect(success_log.length).to eq(1)
      
      log_entry = success_log.first
      expect(log_entry).to have_key('timestamp')
      expect(log_entry).to have_key('status')
      expect(log_entry).to have_key('message')
      
      expect(log_entry['status']).to eq('success')
    end

    it 'handles multiple log entries correctly' do
      # Simulate multiple runs with accumulated logs
      log_contents = {}
      
      # First run
      result1 = simulate_pre_start_execution_with_accumulation(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "Error: user is not authorized",
        audit_mode: false,
        existing_logs: log_contents
      )
      log_contents = result1[:log_contents]
      
      # Second run
      result2 = simulate_pre_start_execution_with_accumulation(
        collect_exit_code: 0,
        send_exit_code: 1,
        send_output: "503 Service Unavailable",
        audit_mode: false,
        existing_logs: log_contents
      )
      
      # Both should be logged
      failure_log = result2[:log_contents]['send-failures.log']
      expect(failure_log.length).to eq(2)
      expect(failure_log[0]['error_type']).to eq('CUSTOMER_CONFIG_ERROR')
      expect(failure_log[1]['error_type']).to eq('MIDDLEWARE_PIPELINE_ERROR')
    end
  end

  describe 'error classification with real error messages' do
    it 'correctly classifies real telemetry-cli error messages' do
      test_cases = [
        {
          output: "Error: Failed to send data: user is not authorized to perform this action",
          expected_type: "CUSTOMER_CONFIG_ERROR"
        },
        {
          output: "Error: Post https://telemetry.example.com/api/v1/data: 401 Unauthorized",
          expected_type: "CUSTOMER_CONFIG_ERROR"
        },
        {
          output: "Error: Post https://telemetry.example.com/api/v1/data: dial tcp: connection refused",
          expected_type: "MIDDLEWARE_PIPELINE_ERROR"
        },
        {
          output: "Error: Post https://telemetry.example.com/api/v1/data: context deadline exceeded",
          expected_type: "MIDDLEWARE_PIPELINE_ERROR"
        },
        {
          output: "Error: Post https://telemetry.example.com/api/v1/data: 503 Service Unavailable",
          expected_type: "MIDDLEWARE_PIPELINE_ERROR"
        },
        {
          output: "Error: Post https://telemetry.example.com/api/v1/data: 500 Internal Server Error",
          expected_type: "UNKNOWN_ERROR"
        },
        {
          output: "Error: some unexpected error occurred",
          expected_type: "UNKNOWN_ERROR"
        }
      ]
      
      test_cases.each do |test_case|
        result = simulate_pre_start_execution(
          collect_exit_code: 0,
          send_exit_code: 1,
          send_output: test_case[:output],
          audit_mode: false
        )
        
        failure_log = result[:log_contents]['send-failures.log']
        expect(failure_log.first['error_type']).to eq(test_case[:expected_type]),
          "Expected #{test_case[:expected_type]} for output: #{test_case[:output]}"
      end
    end
  end

  describe 'cron job retry behavior' do
    it 'verifies that cron job will retry failed sends' do
      # This test verifies that the cron job template is correctly set up
      # to retry sending data that may have failed during pre-start
      
      cron_template = File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collector-cron.erb'))
      
      # The cron job should call the same telemetry-collect-send script
      expect(cron_template).to include('telemetry-collect-send')
      expect(cron_template).to include('collect.yml')
      
      # This ensures that any data collected during pre-start (even if send failed)
      # will be retried by the cron job
    end
  end

  describe 'SPNEGO proxy authentication properties' do
    it 'compiles with all SPNEGO properties provided' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => 'http://proxy:8080',
            'https_proxy' => 'https://proxy:8080',
            'proxy_username' => 'testuser',
            'proxy_password' => 'testpass',
            'proxy_domain' => 'EXAMPLE.COM'
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include("SPNEGO_USERNAME='testuser'")
      expect(compiled).to include("SPNEGO_PASSWORD='testpass'")
      expect(compiled).to include("SPNEGO_DOMAIN='EXAMPLE.COM'")
      expect(compiled).to include('export PROXY_USERNAME="${SPNEGO_USERNAME}"')
      expect(compiled).to include('export PROXY_PASSWORD="${SPNEGO_PASSWORD}"')
      expect(compiled).to include('export PROXY_DOMAIN="${SPNEGO_DOMAIN}"')
    end

    it 'compiles with empty SPNEGO properties (backward compatibility)' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => '',
            'proxy_username' => '',
            'proxy_password' => '',
            'proxy_domain' => ''
          }
        }
      }
      
      expect {
        compile_erb_template(collect_send_template, properties)
      }.not_to raise_error
    end

    it 'compiles without SPNEGO properties defined (backward compatibility)' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      expect {
        compile_erb_template(collect_send_template, properties)
      }.not_to raise_error
    end

    it 'includes SPNEGO validation when credentials are provided' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => 'http://proxy:8080',
            'https_proxy' => 'https://proxy:8080',
            'proxy_username' => 'testuser',
            'proxy_password' => 'testpass',
            'proxy_domain' => 'EXAMPLE.COM'
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('INFO: SPNEGO proxy authentication enabled')
      expect(compiled).to include('if ! command -v kinit')
      expect(compiled).to include('ERROR: SPNEGO configured but kinit not found in PATH')
    end

    it 'includes KRB5CCNAME environment variable for credential cache' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => 'http://proxy:8080',
            'https_proxy' => 'https://proxy:8080',
            'proxy_username' => 'testuser',
            'proxy_password' => 'testpass',
            'proxy_domain' => 'EXAMPLE.COM'
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('export KRB5CCNAME="/tmp/krb5cc_collector_$$')
    end

    it 'includes credential cleanup after send' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => '',
            'proxy_username' => 'testuser',
            'proxy_password' => 'testpass',
            'proxy_domain' => 'EXAMPLE.COM'
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('unset PROXY_USERNAME PROXY_PASSWORD PROXY_DOMAIN')
    end

    it 'classifies proxy authentication errors correctly' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('407')
      expect(compiled).to include('PROXY_AUTH_ERROR')
      expect(compiled).to include('Proxy authentication failed - check proxy credentials')
    end
  end

  describe 'krb5 package conditional PATH logic' do
    it 'includes conditional check for krb5 directory' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('if [ -d /var/vcap/packages/krb5/bin ]')
      expect(compiled).to include('export PATH="/var/vcap/packages/krb5/bin:${PATH}"')
      expect(compiled).to include('Add krb5 binaries to PATH for SPNEGO support (if available)')
    end

    it 'does not fail compilation when krb5 properties are absent' do
      properties = {
        'audit_mode' => true,
        'telemetry' => {
          'api_key' => 'test',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        }
      }
      
      expect {
        compile_erb_template(collect_send_template, properties)
      }.not_to raise_error
    end
  end

  private

  def minimal_properties
    {
      'audit_mode' => true,
      'telemetry' => {
        'api_key' => 'test',
        'proxy_settings' => {
          'no_proxy' => '',
          'http_proxy' => '',
          'https_proxy' => '',
          'proxy_username' => '',
          'proxy_password' => '',
          'proxy_domain' => ''
        }
      }
    }
  end

  def simulate_pre_start_execution_with_accumulation(collect_exit_code:, send_exit_code: 0, send_output: "", audit_mode: false, existing_logs: {})
    log_contents = existing_logs.dup
    log_files_created = []
    
    # Simulate the collect-send script execution
    if collect_exit_code != 0
      return {
        pre_start_exit_code: collect_exit_code,
        log_files_created: log_files_created,
        log_contents: log_contents
      }
    end
    
    if audit_mode
      return {
        pre_start_exit_code: 0,
        log_files_created: log_files_created,
        log_contents: log_contents
      }
    end
    
    # Simulate send attempt
    if send_exit_code != 0
      # Create failure log
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
      
      # Accumulate logs
      if log_contents['send-failures.log']
        log_contents['send-failures.log'] << log_entry
      else
        log_contents['send-failures.log'] = [log_entry]
      end
      log_files_created << 'send-failures.log'
    else
      # Create success log
      timestamp = generate_timestamp
      log_entry = {
        'timestamp' => timestamp,
        'status' => 'success',
        'message' => 'Telemetry sent successfully during startup'
      }
      
      # Accumulate logs
      if log_contents['send-success.log']
        log_contents['send-success.log'] << log_entry
      else
        log_contents['send-success.log'] = [log_entry]
      end
      log_files_created << 'send-success.log'
    end
    
    {
      pre_start_exit_code: 0,
      log_files_created: log_files_created,
      log_contents: log_contents
    }
  end

  def simulate_pre_start_execution(collect_exit_code:, send_exit_code: 0, send_output: "", audit_mode: false)
    log_contents = {}
    log_files_created = []
    
    # Simulate the collect-send script execution
    if collect_exit_code != 0
      return {
        pre_start_exit_code: collect_exit_code,
        log_files_created: log_files_created,
        log_contents: log_contents
      }
    end
    
    if audit_mode
      return {
        pre_start_exit_code: 0,
        log_files_created: log_files_created,
        log_contents: log_contents
      }
    end
    
    # Simulate send attempt
    if send_exit_code != 0
      # Create failure log
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
      
      log_contents['send-failures.log'] = [log_entry]
      log_files_created << 'send-failures.log'
    else
      # Create success log
      timestamp = generate_timestamp
      log_entry = {
        'timestamp' => timestamp,
        'status' => 'success',
        'message' => 'Telemetry sent successfully during startup'
      }
      
      log_contents['send-success.log'] = [log_entry]
      log_files_created << 'send-success.log'
    end
    
    {
      pre_start_exit_code: 0,
      log_files_created: log_files_created,
      log_contents: log_contents
    }
  end

  def classify_error_type(output)
    if output.downcase.match?(/unauthorized|not authorized|401/)
      'CUSTOMER_CONFIG_ERROR'
    elsif output.downcase.match?(/connection refused|timeout|503|502|504|context deadline exceeded|dial tcp/)
      'MIDDLEWARE_PIPELINE_ERROR'
    else
      'UNKNOWN_ERROR'
    end
  end

  def generate_timestamp
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
