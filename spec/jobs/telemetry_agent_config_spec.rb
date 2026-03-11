require 'spec_helper'

describe 'telemetry-agent config.erb' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-agent/templates/config.erb'))
  end

  let(:centralizer_link) do
    {
      address: '10.0.0.5',
      properties: {
        'port' => 24224
      }
    }
  end

  let(:default_links) do
    { 'telemetry-centralizer' => centralizer_link }
  end

  let(:default_properties) do
    {
      'telemetry' => {
        'data_collection_multi_select_options' => []
      }
    }
  end

  describe 'ERB rendering' do
    it 'compiles successfully with link-provided address and port' do
      expect {
        compile_erb_template(template_content, default_properties, {}, default_links)
      }.not_to raise_error
    end

    it 'compiles successfully with explicit address and port properties' do
      props = default_properties.merge(
        'centralizer_address' => '192.168.1.100',
        'centralizer_port' => 5514
      )
      expect {
        compile_erb_template(template_content, props, {}, default_links)
      }.not_to raise_error
    end
  end

  describe 'static Fluent Bit configuration' do
    let(:output) { compile_erb_template(template_content, default_properties, {}, default_links) }

    it 'sets Daemon to Off (BOSH manages the process)' do
      expect(output).to match(/Daemon\s+Off/)
    end

    it 'tails all logs except its own' do
      expect(output).to include('Path /var/vcap/sys/log/**/*')
      expect(output).to include('Exclude_Path  /var/vcap/sys/log/telemetry-agent/*')
    end

    it 'reads from the head of each file' do
      expect(output).to match(/Read_from_Head\s+true/)
    end

    it 'persists tail position state to a db file' do
      expect(output).to include('DB /var/vcap/data/telemetry-agent/db-state/tail-input-state.db')
    end

    it 'filters for telemetry-source and telemetry-time markers' do
      expect(output).to include('Regex  log telemetry-source')
      expect(output).to include('Regex  log telemetry-time')
    end

    it 'sets agent-version via modify filter' do
      expect(output).to match(/Set\s+agent-version\s+0\.0\.1/)
    end

    it 'writes matched messages to a local file output' do
      expect(output).to include('Name file')
      expect(output).to include('File telemetry-agent.stdout.log')
    end
  end

  describe 'centralizer address resolution (if_p / link)' do
    context 'when centralizer_address property is provided' do
      it 'uses the explicit property instead of the link' do
        props = default_properties.merge('centralizer_address' => '192.168.1.100')
        output = compile_erb_template(template_content, props, {}, default_links)
        expect(output).to include('Host 192.168.1.100')
        expect(output).not_to include('Host 10.0.0.5')
      end
    end

    context 'when centralizer_address property is absent' do
      it 'resolves address from the BOSH link' do
        output = compile_erb_template(template_content, default_properties, {}, default_links)
        expect(output).to include('Host 10.0.0.5')
      end
    end

    context 'when centralizer_port property is provided' do
      it 'uses the explicit port instead of the link' do
        props = default_properties.merge('centralizer_port' => 5514)
        output = compile_erb_template(template_content, props, {}, default_links)
        expect(output).to include('Port 5514')
        expect(output).not_to include('Port 24224')
      end
    end

    context 'when centralizer_port property is absent' do
      it 'resolves port from the BOSH link' do
        output = compile_erb_template(template_content, default_properties, {}, default_links)
        expect(output).to include('Port 24224')
      end
    end
  end

  describe 'forward output and TLS' do
    context 'when data collection includes non-operational data' do
      let(:output) { compile_erb_template(template_content, default_properties, {}, default_links) }

      it 'includes the forward output section' do
        expect(output).to include('Name forward')
      end

      it 'enables TLS' do
        expect(output).to match(/tls\s+on/)
      end

      it 'verifies the server certificate' do
        expect(output).to match(/tls\.verify\s+on/)
      end

      it 'sets minimum TLS version to 1.2' do
        expect(output).to match(/tls\.min_version\s+TLSv1\.2/)
      end

      it 'restricts ciphers to ECDHE+AESGCM' do
        expect(output).to match(/tls\.ciphers\s+ECDHE\+AESGCM/)
      end

      it 'references the correct mTLS certificate paths' do
        expect(output).to include('tls.ca_file      /var/vcap/jobs/telemetry-agent/config/ca_cert.pem')
        expect(output).to include('tls.crt_file     /var/vcap/jobs/telemetry-agent/config/cert.pem')
        expect(output).to include('tls.key_file     /var/vcap/jobs/telemetry-agent/config/private_key.pem')
      end
    end

    context 'when only operational_data is selected' do
      it 'omits the forward output section entirely' do
        props = default_properties.dup
        props['telemetry'] = props['telemetry'].merge(
          'data_collection_multi_select_options' => ['operational_data']
        )
        output = compile_erb_template(template_content, props, {}, default_links)
        expect(output).not_to include('Name forward')
        expect(output).not_to include('tls')
      end
    end
  end

  describe 'TLS configuration consistency with centralizer' do
    let(:agent_output) { compile_erb_template(template_content, default_properties, {}, default_links) }

    let(:centralizer_template) do
      File.read(File.join(__dir__, '../../jobs/telemetry-centralizer/templates/config.erb'))
    end

    let(:centralizer_properties) do
      {
        'port' => 24224,
        'flush_interval' => 3600,
        'audit_mode' => false,
        'telemetry' => {
          'env_type' => 'development',
          'foundation_nickname' => 'test-foundation',
          'iaas_type' => 'vsphere',
          'foundation_id' => 'p-bosh-abc123',
          'data_collection_multi_select_options' => [],
          'proxy_settings' => {
            'no_proxy' => '', 'http_proxy' => '', 'https_proxy' => '',
            'proxy_username' => '', 'proxy_password' => '', 'proxy_domain' => ''
          }
        }
      }
    end

    let(:centralizer_output) { compile_erb_template(centralizer_template, centralizer_properties) }

    it 'both sides use the exact same cipher suite' do
      agent_ciphers = agent_output[/tls\.ciphers\s+(\S+)/, 1]
      centralizer_ciphers = centralizer_output[/ciphers\s+(\S+)/, 1]

      expect(agent_ciphers).to eq('ECDHE+AESGCM'),
        "Agent ciphers should be ECDHE+AESGCM, got: #{agent_ciphers}"
      expect(centralizer_ciphers).to eq(agent_ciphers),
        "Centralizer ciphers (#{centralizer_ciphers}) must match agent ciphers (#{agent_ciphers})"
    end

    it 'agent minimum TLS version is compatible with centralizer range' do
      agent_min = agent_output[/tls\.min_version\s+(\S+)/, 1]
      centralizer_min = centralizer_output[/min_version\s+(\S+)/, 1]
      centralizer_max = centralizer_output[/max_version\s+(\S+)/, 1]

      tls_order = { 'TLSv1.1' => 1, 'TLSv1.2' => 2, 'TLSv1.3' => 3,
                    'TLS1_1' => 1, 'TLS1_2' => 2, 'TLS1_3' => 3 }

      agent_level = tls_order[agent_min]
      centralizer_min_level = tls_order[centralizer_min]
      centralizer_max_level = tls_order[centralizer_max]

      expect(agent_level).not_to be_nil, "Unknown agent TLS version: #{agent_min}"
      expect(centralizer_min_level).not_to be_nil, "Unknown centralizer min TLS: #{centralizer_min}"
      expect(centralizer_max_level).not_to be_nil, "Unknown centralizer max TLS: #{centralizer_max}"

      expect(agent_level).to be >= centralizer_min_level,
        "Agent min TLS (#{agent_min}) is below centralizer's minimum (#{centralizer_min})"
      expect(agent_level).to be <= centralizer_max_level,
        "Agent min TLS (#{agent_min}) is above centralizer's maximum (#{centralizer_max})"
    end
  end
end
