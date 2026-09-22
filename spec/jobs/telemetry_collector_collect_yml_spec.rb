require 'spec_helper'

# The job renders two config files and the collector is run once against each.
#
#   config/collect.yml            the hourly cron run, full config
#   config/pre-start-collect.yml  one run during pre-start, Ops Manager only
#
# The difference between them matters, so it is pinned here.
describe 'telemetry-collector rendered config files' do
  let(:collect_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/collect.yml.erb'))
  end

  let(:pre_start_template) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/pre-start-collect.yml.erb'))
  end

  let(:properties) do
    {
      'telemetry' => {
        'env_type' => 'production',
        'api_key' => 'test-api-key',
        'data_collection_multi_select_options' => '["ceip_data", "operational_data"]',
        'tas_installed_selector' => 'Enabled',
        'tile_name' => 'pivotal-telemetry-om',
        'tile_version' => '2.4.13'
      },
      'opsmanager' => {
        'auth' => { 'hostname' => 'opsman.example.com', 'username' => 'admin', 'password' => 'secret' },
        'timeout' => 30
      },
      'cf' => { 'api_url' => 'https://api.sys.example.com' },
      'usage_service' => {
        'url' => 'sys.example.com',
        'client_id' => 'usage-client',
        'client_secret' => 'usage-secret'
      },
      'audit_mode' => false
    }
  end

  let(:collect_yml) { compile_erb_template(collect_template, properties) }
  let(:pre_start_yml) { compile_erb_template(pre_start_template, properties) }

  describe 'collect.yml, the hourly run' do
    it 'carries the baseline opsmanager and telemetry configuration' do
      expect(collect_yml).to include('url: https://opsman.example.com')
      expect(collect_yml).to include('username: admin')
      expect(collect_yml).to include('password: secret')
      expect(collect_yml).to include('env-type: production')
      expect(collect_yml).to include('output-dir: /var/vcap/data/telemetry-collector/')
      expect(collect_yml).to include('tas-installed-selector: Enabled')
      expect(collect_yml).to include('ops-manager-timeout: 30')
    end

    it 'carries the four usage service keys' do
      expect(collect_yml).to include('cf-api-url: https://api.sys.example.com')
      expect(collect_yml).to include('usage-service-url: sys.example.com')
      expect(collect_yml).to include('usage-service-client-id: usage-client')
      expect(collect_yml).to include('usage-service-client-secret: usage-secret')
    end

    it 'carries data-collection-multi-select-options' do
      expect(collect_yml).to include('data-collection-multi-select-options: ["ceip_data", "operational_data"]')
    end

    it 'omits usage-service-timeout when usage_service.timeout is not provided' do
      expect(collect_yml).not_to include('usage-service-timeout')
    end

    context 'when usage_service.timeout is provided' do
      let(:properties) do
        super().tap do |props|
          props['usage_service']['timeout'] = 120
        end
      end

      it 'renders usage-service-timeout into collect.yml' do
        expect(collect_yml).to include('usage-service-timeout: 120')
      end
    end

    context 'when optional properties are provided' do
      let(:properties) do
        super().tap do |props|
          props['opsmanager']['auth']['uaa_client_name'] = 'client-id-val'
          props['opsmanager']['auth']['uaa_client_secret'] = 'client-secret-val'
          props['opsmanager']['insecure_skip_tls_verify'] = true
          props['opsmanager']['request_timeout'] = 90
          props['telemetry']['foundation_nickname'] = 'prod-nyc'
          props['telemetry']['operational_data_only'] = true
          props['telemetry']['split_tar_by_data_type'] = true
          props['usage_service']['insecure_skip_tls_verify'] = true
          props['credhub'] = { 'insecure_skip_tls_verify' => true }
        end
      end

      it 'renders all optional fields into collect.yml' do
        expect(collect_yml).to include('client-id: client-id-val')
        expect(collect_yml).to include('client-secret: client-secret-val')
        expect(collect_yml).to include('insecure-skip-tls-verify: true')
        expect(collect_yml).to include('ops-manager-request-timeout: 90')
        expect(collect_yml).to include('foundation-nickname: prod-nyc')
        expect(collect_yml).to include('operational-data-only: true')
        expect(collect_yml).to include('split-tar-by-data-type: true')
        expect(collect_yml).to include('usage-service-insecure-skip-tls-verify: true')
        expect(collect_yml).to include('credhub-insecure-skip-tls-verify: true')
      end
    end
  end

  describe 'pre-start-collect.yml, the run during pre-start' do
    it 'carries none of the four usage service keys' do
      # This is by design and is why the next test exists. This run can only
      # ever collect Ops Manager / CEIP data.
      expect(pre_start_yml).not_to include('cf-api-url')
      expect(pre_start_yml).not_to include('usage-service-url')
      expect(pre_start_yml).not_to include('usage-service-client-id')
      expect(pre_start_yml).not_to include('usage-service-client-secret')
      expect(pre_start_yml).not_to include('usage-service-timeout')
    end

    it 'does not carry data-collection-multi-select-options' do
      # Do not add this key back without reading the comment in
      # pre-start-collect.yml.erb first.
      #
      # The collector warns when operational data is selected, TAS is installed,
      # and no usage service config arrived. Those three are true on every
      # apply-changes on every TAS foundation if this key is present here,
      # because this file never carries usage service config. That warning is
      # real on the hourly run and a false alarm here.
      #
      # An earlier version of the collector returned an error in that state
      # rather than warning, which failed pre-start and so failed
      # apply-changes outright.
      expect(pre_start_yml).not_to include('data-collection-multi-select-options')
    end

    it 'still carries the Ops Manager config it needs' do
      expect(pre_start_yml).to include('url: https://opsman.example.com')
      expect(pre_start_yml).to include('username: admin')
      expect(pre_start_yml).to include('env-type: production')
      expect(pre_start_yml).to include('output-dir: /var/vcap/data/telemetry-collector/')
    end
  end
end
