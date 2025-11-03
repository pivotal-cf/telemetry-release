require 'spec_helper'
require 'tmpdir'
require 'fileutils'

describe 'Telemetry Collector krb5/SPNEGO Integration' do
  let(:collect_send_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end

  let(:spnego_curl_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-centralizer/templates/spnego-curl.sh.erb'))
  end

  describe 'krb5 PATH conditional logic in telemetry-collector' do
    it 'includes conditional check for krb5/bin directory' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('if [ -d /var/vcap/packages/krb5/bin ]')
      expect(compiled).to include('export PATH=/var/vcap/packages/krb5/bin:$PATH')
      expect(compiled).to include('fi')
    end

    it 'includes helpful comment explaining conditional check' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('Add krb5 binaries to PATH for SPNEGO support (if available)')
    end

    it 'does not unconditionally add krb5 to PATH' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Should NOT have an unconditional export before the conditional check
      lines = compiled.lines
      krb5_export_line = lines.find_index { |line| line.include?('export PATH=/var/vcap/packages/krb5/bin:$PATH') }
      
      expect(krb5_export_line).not_to be_nil
      
      # The line before it should be the if statement or within the if block
      preceding_lines = lines[0...krb5_export_line].reverse.take(5).map(&:strip)
      expect(preceding_lines).to include(match(/if \[ -d \/var\/vcap\/packages\/krb5\/bin \]/))
    end

    it 'places krb5 PATH addition early in script' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      lines = compiled.lines
      krb5_line = lines.find_index { |line| line.include?('if [ -d /var/vcap/packages/krb5/bin ]') }
      
      # Should be in first 20 lines of script (after shebang and set -e)
      expect(krb5_line).to be < 20
    end
  end

  describe 'krb5 PATH conditional logic in telemetry-centralizer' do
    it 'includes conditional check for krb5/bin directory' do
      properties = {}
      compiled = compile_erb_template(spnego_curl_template, properties)
      
      expect(compiled).to include('if [ -d /var/vcap/packages/krb5/bin ]')
      expect(compiled).to include('export PATH=/var/vcap/packages/krb5/bin:$PATH')
      expect(compiled).to include('fi')
    end

    it 'includes helpful comment explaining conditional check' do
      properties = {}
      compiled = compile_erb_template(spnego_curl_template, properties)
      
      expect(compiled).to include('Add krb5 binaries to PATH for SPNEGO support (if available)')
    end
  end

  describe 'SPNEGO credential handling' do
    it 'only enables SPNEGO when all three credentials are provided' do
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
      
      # Should check that all three are non-empty
      expect(compiled).to include('[[ -n "$SPNEGO_USERNAME" && -n "$SPNEGO_PASSWORD" && -n "$SPNEGO_DOMAIN" ]]')
    end

    it 'does not enable SPNEGO with only username' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => 'http://proxy:8080',
            'https_proxy' => 'https://proxy:8080',
            'proxy_username' => 'testuser',
            'proxy_password' => '',
            'proxy_domain' => ''
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # The logic requires all three to be non-empty
      expect(compiled).to include('[[ -n "$SPNEGO_USERNAME" && -n "$SPNEGO_PASSWORD" && -n "$SPNEGO_DOMAIN" ]]')
    end

    it 'sets unique KRB5CCNAME to avoid race conditions' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Should include PID and timestamp in cache name
      expect(compiled).to include('export KRB5CCNAME="/tmp/krb5cc_collector_$$')
      expect(compiled).to match(/krb5cc_collector_\$\$_\$\(date \+%s%N\)/)
    end

    it 'exports SPNEGO credentials as environment variables' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('export PROXY_USERNAME="$SPNEGO_USERNAME"')
      expect(compiled).to include('export PROXY_PASSWORD="$SPNEGO_PASSWORD"')
      expect(compiled).to include('export PROXY_DOMAIN="$SPNEGO_DOMAIN"')
    end

    it 'cleans up credentials after send attempt' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('unset PROXY_USERNAME PROXY_PASSWORD PROXY_DOMAIN')
    end
  end

  describe 'kinit validation' do
    it 'validates kinit is available when SPNEGO is configured' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('if ! command -v kinit >/dev/null 2>&1')
      expect(compiled).to include('ERROR: SPNEGO configured but kinit not found in PATH')
    end

    it 'validates curl has GSS-API support when SPNEGO is configured' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('curl -V 2>&1 | grep -qi "gss\\|kerberos"')
      expect(compiled).to include('ERROR: SPNEGO configured but curl lacks GSS-API support')
    end

    it 'logs validation results' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('INFO: SPNEGO system requirements validated')
    end

    it 'does not fail deployment on validation warnings' do
      properties = spnego_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Should log errors but not exit
      expect(compiled).to include("# Don't fail deployment - log and continue")
    end
  end

  describe 'error classification for SPNEGO errors' do
    it 'includes SYSTEM_REQUIREMENTS_ERROR classification' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('SYSTEM_REQUIREMENTS_ERROR')
      expect(compiled).to include('kinit.*not found\\|curl.*not found\\|gss-api')
    end

    it 'includes PROXY_AUTH_ERROR classification' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      expect(compiled).to include('PROXY_AUTH_ERROR')
      expect(compiled).to include('proxy.*authentication\\|407\\|spnego\\|kerberos')
      expect(compiled).to include('Proxy authentication failed - check proxy credentials')
    end
  end

  describe 'backward compatibility' do
    it 'compiles successfully without SPNEGO properties' do
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

    it 'compiles successfully with empty SPNEGO properties' do
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

    it 'does not require krb5 package for basic functionality' do
      properties = minimal_properties
      compiled = compile_erb_template(collect_send_template, properties)
      
      # The script should work even if krb5 is not present
      # The conditional check ensures this
      expect(compiled).to include('if [ -d /var/vcap/packages/krb5/bin ]')
    end
  end

  describe 'telemetry-centralizer SPNEGO support' do
    it 'includes KRB5CCNAME for centralizer' do
      properties = {}
      compiled = compile_erb_template(spnego_curl_template, properties)
      
      expect(compiled).to include('export KRB5CCNAME="/tmp/krb5cc_centralizer_$$"')
    end

    it 'includes cleanup function for credential cache' do
      properties = {}
      compiled = compile_erb_template(spnego_curl_template, properties)
      
      expect(compiled).to include('cleanup()')
      expect(compiled).to include('rm -f "$KRB5CCNAME"')
    end

    it 'sets up trap for cleanup on exit' do
      properties = {}
      compiled = compile_erb_template(spnego_curl_template, properties)
      
      expect(compiled).to include('trap cleanup EXIT')
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

  def spnego_properties
    {
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
  end
end

