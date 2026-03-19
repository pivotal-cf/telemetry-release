require 'spec_helper'

describe 'telemetry-centralizer config.erb' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-centralizer/templates/config.erb'))
  end

  let(:default_properties) do
    {
      'port' => 24_224,
      'flush_interval' => 3600,
      'audit_mode' => false,
      'telemetry' => {
        'env_type' => 'development',
        'foundation_nickname' => 'test-foundation',
        'iaas_type' => 'vsphere',
        'foundation_id' => 'p-bosh-abc123',
        'data_collection_multi_select_options' => [],
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

  describe 'ERB rendering' do
    it 'compiles successfully with default properties' do
      expect { compile_erb_template(template_content, default_properties) }.not_to raise_error
    end

    it 'renders the forward input source on the configured port' do
      output = compile_erb_template(template_content, default_properties)
      expect(output).to include('@type forward')
      expect(output).to include('port 24224')
    end

    it 'renders record_transformer fields correctly' do
      output = compile_erb_template(template_content, default_properties)
      expect(output).to include('telemetry-env-type development')
      expect(output).to include('telemetry-foundation-nickname test-foundation')
      expect(output).to include('telemetry-iaas-type vsphere')
      expect(output).to include('telemetry-foundation-id p-bosh-abc123')
    end

    it 'omits foundation-nickname when property is not set' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].dup
      props['telemetry'].delete('foundation_nickname')
      output = compile_erb_template(template_content, props)
      expect(output).not_to include('telemetry-foundation-nickname')
    end

    it 'uses curl command when SPNEGO is not configured' do
      output = compile_erb_template(template_content, default_properties)
      expect(output).to include('curl -s -K /var/vcap/jobs/telemetry-centralizer/config/curl_config')
      expect(output).not_to include('spnego-curl.sh')
    end

    it 'uses spnego-curl.sh when all SPNEGO credentials are provided' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].dup
      props['telemetry']['proxy_settings'] = {
        'no_proxy' => '',
        'http_proxy' => 'http://proxy:8080',
        'https_proxy' => 'https://proxy:8080',
        'proxy_username' => 'user',
        'proxy_password' => 'pass',
        'proxy_domain' => 'EXAMPLE.COM'
      }
      output = compile_erb_template(template_content, props)
      expect(output).to include('spnego-curl.sh')
      expect(output).not_to include('curl -s -K')
    end

    it 'uses tee /dev/null when only operational data is selected' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].dup
      props['telemetry']['data_collection_multi_select_options'] = ['operational_data']
      output = compile_erb_template(template_content, props)
      expect(output).to include('command tee /dev/null')
    end

    it 'uses audit log when audit_mode is enabled' do
      props = default_properties.dup
      props['audit_mode'] = true
      output = compile_erb_template(template_content, props)
      expect(output).to include('tee -a -p /var/vcap/sys/log/telemetry-centralizer/audit.log')
    end

    it 'renders the flush interval from properties' do
      props = default_properties.dup
      props['flush_interval'] = 1800
      output = compile_erb_template(template_content, props)
      expect(output).to include('flush_interval 1800s')
    end
  end

  describe 'TLS configuration' do
    let(:rendered_config) { compile_erb_template(template_content, default_properties) }

    let(:transport_block) do
      match = rendered_config.match(%r{<transport tls>(.+?)</transport>}m)
      expect(match).not_to be_nil, 'No <transport tls> block found in rendered config'
      match[1]
    end

    # Ordered low-to-high so index comparison gives us version ordering for free.
    tls_versions_ascending = %w[TLS1_1 TLS1_2 TLS1_3]

    it 'includes a transport tls block' do
      expect(rendered_config).to include('<transport tls>')
    end

    it 'sets min_version to TLS1_2' do
      expect(transport_block).to match(/min_version\s+TLS1_2/)
    end

    it 'sets max_version to TLS1_3' do
      expect(transport_block).to match(/max_version\s+TLS1_3/)
    end

    it 'always pairs min_version with max_version' do
      has_min = transport_block.match?(/min_version\s+\S+/)
      has_max = transport_block.match?(/max_version\s+\S+/)
      expect(has_min).to eq(has_max),
                         'min_version and max_version must both be present or both absent in ' \
                         '<transport tls>. Fluentd >= 1.19 raises ConfigError if only one is set.'
    end

    it 'sets max_version >= min_version' do
      min_str = transport_block[/min_version\s+(\S+)/, 1]
      max_str = transport_block[/max_version\s+(\S+)/, 1]
      next unless min_str && max_str

      min_idx = tls_versions_ascending.index(min_str)
      max_idx = tls_versions_ascending.index(max_str)

      expect(min_idx).not_to be_nil, "Unknown min_version '#{min_str}'"
      expect(max_idx).not_to be_nil, "Unknown max_version '#{max_str}'"
      expect(max_idx).to be >= min_idx,
                         "max_version (#{max_str}) must be >= min_version (#{min_str})"
    end

    it 'restricts ciphers to ECDHE+AESGCM' do
      expect(transport_block).to match(/ciphers\s+ECDHE\+AESGCM/)
    end

    it 'enables client certificate authentication' do
      expect(transport_block).to include('client_cert_auth true')
    end

    it 'references the correct certificate paths' do
      expect(transport_block).to include('cert_path /var/vcap/jobs/telemetry-centralizer/config/cert.pem')
      expect(transport_block).to include('private_key_path /var/vcap/jobs/telemetry-centralizer/config/private_key.pem')
      expect(transport_block).to include('ca_path /var/vcap/jobs/telemetry-centralizer/config/ca_cert.pem')
    end
  end

  describe 'Fluentd TLS runtime validation', if: fluentd_available? do
    it 'accepts the TLS version combination used in the template' do
      rendered = compile_erb_template(template_content, default_properties)
      min_str = rendered[/min_version\s+(\S+)/, 1]
      max_str = rendered[/max_version\s+(\S+)/, 1]

      expect(min_str).not_to be_nil, 'min_version not found in rendered config'
      expect(max_str).not_to be_nil, 'max_version not found in rendered config — ' \
                                     'Fluentd >= 1.19 requires max_version when min_version is set'

      min_sym = min_str.to_sym
      max_sym = max_str.to_sym

      expect(Fluent::TLS::SUPPORTED_VERSIONS).to include(min_sym),
                                                 "min_version '#{min_str}' is not a valid Fluentd TLS version"
      expect(Fluent::TLS::SUPPORTED_VERSIONS).to include(max_sym),
                                                 "max_version '#{max_str}' is not a valid Fluentd TLS version"

      ctx = OpenSSL::SSL::SSLContext.new
      expect do
        Fluent::TLS.set_version_to_context(ctx, nil, min_sym, max_sym)
      end.not_to raise_error
    end

    it 'would reject min_version without max_version' do
      ctx = OpenSSL::SSL::SSLContext.new
      expect do
        Fluent::TLS.set_version_to_context(ctx, nil, :TLSv1_2, nil)
      end.to raise_error(Fluent::ConfigError, /must set max_version together/)
    end
  end
end
