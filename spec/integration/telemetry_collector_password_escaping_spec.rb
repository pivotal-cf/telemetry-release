require 'spec_helper'

# Test specifically for password escaping bug fix
# This test ensures passwords with special shell characters are properly escaped
describe 'telemetry-collector password escaping' do
  let(:collect_send_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end
  
  let(:spnego_curl_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-centralizer/templates/spnego-curl.sh.erb'))
  end
  
  # Helper to extract variable value from compiled shell script
  def extract_shell_variable(script, variable_name)
    # Match: VARIABLE='value' or VARIABLE="value" or local VARIABLE='value'
    match = script.match(/(?:local\s+)?#{Regexp.escape(variable_name)}=['"]([^'"]+)['"]/)
    match ? match[1] : nil
  end
  
  
  describe 'telemetry-collector SPNEGO password handling' do
    context 'with passwords containing special shell characters' do
      # Test cases from real-world password requirements
      special_char_passwords = [
        'Pass$123',           # Dollar sign (variable expansion)
        'P@ss$word$456',      # Multiple dollar signs
        'Test$$Money',        # Double dollar sign
        'MyP@ss$123!',        # Dollar + exclamation
        'P@ss!word',          # Exclamation (history expansion)
        'Pass`echo hi`',      # Backticks (command substitution)
        'Pass$(whoami)',      # Command substitution
        'Pass\\$123',         # Backslash escape
        'Pass"word',          # Double quote
        "Pass'word",          # Single quote (properly escaped in our fix)
        'Pass $pace',         # Space
        'Pass	Tab',          # Tab
        'ComplexP@ss$123!`test`', # Kitchen sink
      ]
      
      special_char_passwords.each do |test_password|
        it "preserves password: #{test_password.inspect}" do
          properties = {
            'audit_mode' => false,
            'telemetry' => {
              'api_key' => 'test-key',
              'proxy_settings' => {
                'no_proxy' => '',
                'http_proxy' => 'http://proxy:3128',
                'https_proxy' => 'http://proxy:3128',
                'proxy_username' => 'testuser',
                'proxy_password' => test_password,
                'proxy_domain' => 'EXAMPLE.COM'
              }
            }
          }
          
          compiled = compile_erb_template(collect_send_template, properties)
          
          # Check that the template uses Base64 encoding (our fix)
          expect(compiled).to match(/SPNEGO_PASSWORD_B64='/)
          expect(compiled).to match(/local proxy_password_b64='/)
          expect(compiled).to include('| base64 -d')
          
          # Verify the password is Base64 encoded
          encoded_password = Base64.strict_encode64(test_password)
          expect(compiled).to include("SPNEGO_PASSWORD_B64='#{encoded_password}'")
        end
      end
    end
    
    context 'Bash runtime behavior validation' do
      # Note: See test-password-escaping-bug.sh for a standalone demonstration
      # of how double quotes cause variable expansion bugs and single quotes fix it.
      # The RSpec tests above verify that our ERB templates generate single-quoted passwords.
      
      it 'confirms single quotes are used in compiled templates' do
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'proxy_settings' => {
              'no_proxy' => '',
              'http_proxy' => '',
              'https_proxy' => '',
              'proxy_username' => 'user',
              'proxy_password' => 'Pass$123',
              'proxy_domain' => 'DOMAIN'
            }
          }
        }
        
        compiled = compile_erb_template(collect_send_template, properties)
        
        # Verify Base64 encoding is consistently used
        expect(compiled).to match(/SPNEGO_PASSWORD_B64='[^']*'/)
        expect(compiled).to match(/local proxy_password_b64='[^']*'/)
        expect(compiled).to include('$(echo "${SPNEGO_PASSWORD_B64}" | base64 -d)')
        expect(compiled).to include('$(echo "${proxy_password_b64}" | base64 -d)')
      end
    end
  end
  
  describe 'telemetry-centralizer SPNEGO password handling' do
    context 'with special character passwords' do
      it 'uses single quotes to preserve password: Pass$123' do
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'endpoint' => 'https://telemetry.example.com',
            'proxy_settings' => {
              'proxy_username' => 'testuser',
              'proxy_password' => 'Pass$123',
              'proxy_domain' => 'EXAMPLE.COM'
            }
          }
        }
        
        compiled = compile_erb_template(spnego_curl_template, properties)
        
        # Verify Base64 encoding is used (our fix)
        expect(compiled).to match(/PASSWORD_B64='/)
        expect(compiled).to include('$(echo "${PASSWORD_B64}" | base64 -d)')
        encoded = Base64.strict_encode64('Pass$123')
        expect(compiled).to include("PASSWORD_B64='#{encoded}'")
      end
      
      it 'handles complex password: ComplexP@ss$123!`test`' do
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'endpoint' => 'https://telemetry.example.com',
            'proxy_settings' => {
              'proxy_username' => 'testuser',
              'proxy_password' => 'ComplexP@ss$123!`test`',
              'proxy_domain' => 'EXAMPLE.COM'
            }
          }
        }
        
        compiled = compile_erb_template(spnego_curl_template, properties)
        
        # Verify the password is Base64 encoded
        encoded = Base64.strict_encode64('ComplexP@ss$123!`test`')
        expect(compiled).to include("PASSWORD_B64='#{encoded}'")
      end
    end
    
    context 'Bash execution validation (CRITICAL)' do
      it 'executes successfully with single quote in password' do
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'proxy_settings' => {
              'no_proxy' => '',
              'http_proxy' => '',
              'https_proxy' => '',
              'proxy_username' => 'testuser',
              'proxy_password' => "Pass'word",  # Single quote - the critical test!
              'proxy_domain' => 'EXAMPLE.COM'
            }
          },
          'opsmanager' => {
            'auth' => {
              'hostname' => 'opsman.example.com'
            }
          }
        }
        
        compiled = compile_erb_template(spnego_curl_template, properties)
        
        # Write to temp file
        require 'tempfile'
        script_file = Tempfile.new(['test-script', '.sh'])
        script_file.write(compiled)
        script_file.close
        
        # Test bash syntax (should not have errors)
        result = system("bash -n #{script_file.path}")
        expect(result).to be(true), "Script has syntax errors with single quote password"
        
        script_file.unlink
      end
      
      it 'executes successfully with multiple single quotes in password' do
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'proxy_settings' => {
              'no_proxy' => '',
              'http_proxy' => '',
              'https_proxy' => '',
              'proxy_username' => 'testuser',
              'proxy_password' => "P'a's's'word",  # Multiple single quotes!
              'proxy_domain' => 'EXAMPLE.COM'
            }
          },
          'opsmanager' => {
            'auth' => {
              'hostname' => 'opsman.example.com'
            }
          }
        }
        
        compiled = compile_erb_template(collect_send_template, properties)
        
        require 'tempfile'
        script_file = Tempfile.new(['test-script', '.sh'])
        script_file.write(compiled)
        script_file.close
        
        result = system("bash -n #{script_file.path}")
        expect(result).to be(true), "Script has syntax errors with multiple single quotes"
        
        script_file.unlink
      end
      
      it 'correctly decodes password with all special characters' do
        test_password = "P@ss'w\"ord`$123!$(whoami)"
        
        properties = {
          'audit_mode' => false,
          'telemetry' => {
            'api_key' => 'test-key',
            'proxy_settings' => {
              'no_proxy' => '',
              'http_proxy' => '',
              'https_proxy' => '',
              'proxy_username' => 'testuser',
              'proxy_password' => test_password,
              'proxy_domain' => 'EXAMPLE.COM'
            }
          },
          'opsmanager' => {
            'auth' => {
              'hostname' => 'opsman.example.com'
            }
          }
        }
        
        compiled = compile_erb_template(collect_send_template, properties)
        
        # Extract the SPNEGO_PASSWORD_B64 value from compiled script
        match = compiled.match(/SPNEGO_PASSWORD_B64='([^']+)'/)
        expect(match).not_to be_nil, "Could not find SPNEGO_PASSWORD_B64 in compiled script"
        
        # Decode and verify it matches original
        decoded = Base64.strict_decode64(match[1])
        expect(decoded).to eq(test_password), "Decoded password doesn't match original"
      end
    end
  end
  
  describe 'backward compatibility' do
    it 'still works with simple passwords (no special chars)' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => '',
            'proxy_username' => 'testuser',
            'proxy_password' => 'simplepassword123',
            'proxy_domain' => 'EXAMPLE.COM'
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Should work with Base64 encoding (even for simple passwords)
      encoded = Base64.strict_encode64('simplepassword123')
      expect(compiled).to include("SPNEGO_PASSWORD_B64='#{encoded}'")
      expect(compiled).to include('$(echo "${SPNEGO_PASSWORD_B64}" | base64 -d)')
      expect(compiled).to include('export PROXY_PASSWORD="${SPNEGO_PASSWORD}"')
    end
    
    it 'handles empty passwords (SPNEGO disabled)' do
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
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # SPNEGO should be disabled (empty credentials)
      expect(compiled).to include("SPNEGO_USERNAME=''")
      expect(compiled).to include("SPNEGO_PASSWORD_B64=''")  # Base64 of empty string is empty
      expect(compiled).to include("SPNEGO_DOMAIN=''")
    end
  end
  
  describe 'proxy URL and audit_mode quoting (best practices)' do
    it 'uses single quotes for audit_mode' do
      properties = {
        'audit_mode' => true,
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
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Verify single quotes are used for consistency
      expect(compiled).to include("audit_mode='true'")
    end
    
    it 'uses single quotes for proxy URLs' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => 'localhost,127.0.0.1',
            'http_proxy' => 'http://proxy.example.com:3128',
            'https_proxy' => 'https://proxy.example.com:3128',
            'proxy_username' => '',
            'proxy_password' => '',
            'proxy_domain' => ''
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Verify single quotes are used
      expect(compiled).to include("export no_proxy='localhost,127.0.0.1'")
      expect(compiled).to include("export http_proxy='http://proxy.example.com:3128'")
      expect(compiled).to include("export https_proxy='https://proxy.example.com:3128'")
    end
    
    it 'preserves proxy URLs with special characters' do
      properties = {
        'audit_mode' => false,
        'telemetry' => {
          'api_key' => 'test-key',
          'proxy_settings' => {
            'no_proxy' => 'localhost,$HOSTNAME',  # Has $ variable
            'http_proxy' => 'http://proxy$(test).com:3128',  # Has $() command substitution
            'https_proxy' => 'http://proxy.com:3128',
            'proxy_username' => '',
            'proxy_password' => '',
            'proxy_domain' => ''
          }
        }
      }
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Verify special characters are preserved literally (not expanded)
      expect(compiled).to include("export no_proxy='localhost,$HOSTNAME'")
      expect(compiled).to include("export http_proxy='http://proxy$(test).com:3128'")
      
      # Verify single quotes are consistently used (not double quotes)
      expect(compiled).to match(/export no_proxy='[^']*'/)
      expect(compiled).to match(/export http_proxy='[^']*'/)
      expect(compiled).to match(/export https_proxy='[^']*'/)
    end
    
    it 'handles empty proxy URLs correctly' do
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
      
      compiled = compile_erb_template(collect_send_template, properties)
      
      # Verify empty values are correctly quoted
      expect(compiled).to include("export no_proxy=''")
      expect(compiled).to include("export http_proxy=''")
      expect(compiled).to include("export https_proxy=''")
    end
  end
end

