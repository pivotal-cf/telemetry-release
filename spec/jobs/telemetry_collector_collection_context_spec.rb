require 'spec_helper'
require 'yaml'

describe 'telemetry-collector collection context' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/collect.yml.erb'))
  end
  
  describe 'with empty collection context properties (default)' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => '',
          'tile_version' => ''
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com'
          }
        }
      }
    end
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties) }.not_to raise_error
    end
    
    it 'does not include collection-source when tile_name is empty' do
      output = compile_erb_template(template_content, properties)
      expect(output).not_to include('collection-source:')
    end
    
    it 'does not include tile-name when empty' do
      output = compile_erb_template(template_content, properties)
      expect(output).not_to include('tile-name:')
    end
    
    it 'includes tile-version even when empty (if_p includes all defined properties)' do
      output = compile_erb_template(template_content, properties)
      # if_p will output the property even if empty, as long as it's defined
      expect(output).to include('tile-version:')
    end
    
    it 'includes bosh-release-version from spec.release.version' do
      output = compile_erb_template(template_content, properties)
      # bosh-release-version is always present via spec.release.version
      expect(output).to include('bosh-release-version:')
    end
    
    it 'includes tile-audit-mode even when context is empty' do
      output = compile_erb_template(template_content, properties)
      expect(output).to include('tile-audit-mode: false')
    end
    
    it 'produces valid YAML' do
      output = compile_erb_template(template_content, properties)
      expect { YAML.safe_load(output) }.not_to raise_error
    end
  end
  
  describe 'with populated collection context properties' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => 'pivotal-telemetry-om',
          'tile_version' => '2.3.1'
        },
        'audit_mode' => true,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com'
          }
        }
      }
    end
    let(:spec_data) { { release: OpenStruct.new(version: '2.3.0') } }
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties, spec_data) }.not_to raise_error
    end
    
    it 'includes collection-source: tile when tile_name is provided' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('collection-source: tile')
    end
    
    it 'includes tile-name with correct value' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('tile-name: pivotal-telemetry-om')
    end
    
    it 'includes tile-version with correct value' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('tile-version: 2.3.1')
    end
    
    it 'includes bosh-release-version from spec.release.version' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('bosh-release-version: 2.3.0')
    end
    
    it 'includes tile-audit-mode with correct boolean value' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('tile-audit-mode: true')
    end
    
    it 'produces valid YAML' do
      output = compile_erb_template(template_content, properties, spec_data)
      parsed = YAML.safe_load(output)
      expect(parsed['collection-source']).to eq('tile')
      expect(parsed['tile-name']).to eq('pivotal-telemetry-om')
      expect(parsed['tile-version']).to eq('2.3.1')
      expect(parsed['bosh-release-version']).to eq('2.3.0')
      expect(parsed['tile-audit-mode']).to eq(true)
    end
  end
  
  describe 'with whitespace-only tile_name' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => '   ',  # Spaces only
          'tile_version' => '2.3.1'
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com'
          }
        }
      }
    end
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties) }.not_to raise_error
    end
    
    it 'includes collection context (whitespace is not empty string)' do
      output = compile_erb_template(template_content, properties)
      # Current behavior: whitespace != "" so context IS included
      expect(output).to include('collection-source: tile')
      expect(output).to include('tile-name:')
    end
  end
  
  describe 'with mixed populated and empty properties' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => 'pivotal-telemetry-om',
          'tile_version' => ''  # Empty
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com'
          }
        }
      }
    end
    let(:spec_data) { { release: OpenStruct.new(version: '2.3.0') } }
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties, spec_data) }.not_to raise_error
    end
    
    it 'includes collection-source when tile_name is provided' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('collection-source: tile')
    end
    
    it 'includes tile-name' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('tile-name: pivotal-telemetry-om')
    end
    
    it 'includes tile-version even when empty' do
      output = compile_erb_template(template_content, properties, spec_data)
      # Current ERB: if_p always includes the line if property exists
      expect(output).to include('tile-version:')
    end
    
    it 'includes bosh-release-version from spec.release.version' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('bosh-release-version: 2.3.0')
    end
  end
  
  describe 'with version strings containing special characters' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => 'pivotal-telemetry-om',
          'tile_version' => '2.3.0-build.1+sha.abc123'
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com'
          }
        }
      }
    end
    let(:spec_data) { { release: OpenStruct.new(version: '2.3.0-rc.1') } }
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties, spec_data) }.not_to raise_error
    end
    
    it 'includes version with special characters correctly' do
      output = compile_erb_template(template_content, properties, spec_data)
      expect(output).to include('tile-version: 2.3.0-build.1+sha.abc123')
      expect(output).to include('bosh-release-version: 2.3.0-rc.1')
    end
    
    it 'produces valid YAML with special character versions' do
      output = compile_erb_template(template_content, properties, spec_data)
      parsed = YAML.safe_load(output)
      expect(parsed['tile-version']).to eq('2.3.0-build.1+sha.abc123')
      expect(parsed['bosh-release-version']).to eq('2.3.0-rc.1')
    end
  end
end

describe 'telemetry-collector collect-send script' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end
  
  describe 'with SPNEGO credentials provided' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => 'pivotal-telemetry-om',
          'tile_version' => '2.3.1',
          'proxy_settings' => {
            'proxy_username' => 'proxy-user',
            'proxy_password' => 'proxy-pass',
            'proxy_domain' => 'DOMAIN',
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com',
            'username' => 'admin',
            'password' => 'password'
          }
        }
      }
    end
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties) }.not_to raise_error
    end
    
    it 'passes --tile-spnego-enabled=true when all credentials are provided' do
      output = compile_erb_template(template_content, properties)
      expect(output).to include('--tile-spnego-enabled="${SPNEGO_ENABLED}"')
      expect(output).to include('SPNEGO_ENABLED="true"')
    end
  end
  
  describe 'without SPNEGO credentials' do
    let(:properties) do
      {
        'telemetry' => {
          'env_type' => 'production',
          'tile_name' => 'pivotal-telemetry-om',
          'tile_version' => '2.3.1',
          'proxy_settings' => {
            'proxy_username' => '',
            'proxy_password' => '',
            'proxy_domain' => '',
            'no_proxy' => '',
            'http_proxy' => '',
            'https_proxy' => ''
          }
        },
        'audit_mode' => false,
        'opsmanager' => {
          'auth' => {
            'hostname' => 'opsman.example.com',
            'username' => 'admin',
            'password' => 'password'
          }
        }
      }
    end
    
    it 'compiles successfully' do
      expect { compile_erb_template(template_content, properties) }.not_to raise_error
    end
    
    it 'passes --tile-spnego-enabled=false when credentials are not provided' do
      output = compile_erb_template(template_content, properties)
      expect(output).to include('--tile-spnego-enabled="${SPNEGO_ENABLED}"')
      expect(output).to include('SPNEGO_ENABLED="false"')
    end
  end
end

