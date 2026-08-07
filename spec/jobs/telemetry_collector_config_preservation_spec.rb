require 'spec_helper'
require 'fileutils'
require 'tmpdir'

describe 'telemetry-collector config file preservation' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collect-send.erb'))
  end

  let(:properties) do
    {
      'telemetry' => {
        'env_type' => 'production',
        'api_key' => 'test-api-key',
        'proxy_settings' => {
          'proxy_username' => '',
          'proxy_password' => '',
          'proxy_domain' => '',
          'no_proxy' => '',
          'http_proxy' => '',
          'https_proxy' => ''
        }
      },
      'audit_mode' => true,
      'opsmanager' => {
        'auth' => {
          'hostname' => 'opsman.example.com'
        }
      }
    }
  end

  it 'does not mutate collect.yml on disk when tas-installed-selector is Disabled' do
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, 'collect.yml')
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Disabled
        usage-service-url: usage.example.com
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML
      File.write(config_path, initial_content)

      data_dir = File.join(dir, 'data')
      FileUtils.mkdir_p(data_dir)

      # Create dummy collector binary
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      mock_bin = File.join(bin_dir, 'telemetry-cli-linux')
      File.write(mock_bin, "#!/bin/bash\nmkdir -p #{data_dir}\ntouch #{data_dir}/test.tar\nexit 0\n")
      FileUtils.chmod(0755, mock_bin)

      # Create dummy chown in PATH to avoid set -e failure when not running as root/vcap
      chown_bin = File.join(bin_dir, 'chown')
      File.write(chown_bin, "#!/bin/bash\nexit 0\n")
      FileUtils.chmod(0755, chown_bin)

      compiled_script = compile_erb_template(template_content, properties)

      # Create pre-start-collect.yml mock
      pre_start_path = File.join(dir, 'pre-start-collect.yml')
      File.write(pre_start_path, initial_content)

      # Mock data path and binary path for safety in test environment
      test_script_path = File.join(dir, 'test-collect-send.sh')
      script_with_mocks = compiled_script
        .gsub('COLLECTOR_BIN=/var/vcap/packages/telemetry-cli/telemetry-cli-linux', "COLLECTOR_BIN=#{mock_bin}")
        .gsub('/var/vcap/data/tmp/telemetry-collector', File.join(data_dir, 'run'))
      .gsub('/var/vcap/data/telemetry-collector', data_dir)
        .gsub('/var/vcap/jobs/telemetry-collector/config/pre-start-collect.yml', pre_start_path)
        .gsub('/var/vcap/jobs/telemetry-collector/config/collect.yml', config_path)

      # Ensure our mock bin_dir (with mock chown and mock collector) is first in PATH
      script_with_path = "export PATH=\"#{bin_dir}:${PATH}\"\n" + script_with_mocks

      File.write(test_script_path, script_with_path)
      FileUtils.chmod(0755, test_script_path)

      # Run script first time with tas-installed-selector: Disabled
      system("bash #{test_script_path} #{config_path} >/dev/null 2>&1")

      # Verify that original collect.yml on disk still contains usage-service-url
      content_after_run1 = File.read(config_path)
      expect(content_after_run1).to include('usage-service-url: usage.example.com')
      expect(content_after_run1).to include('usage-service-client-id: my-client-id')
    end
  end

  # Captures what create_or_update_options actually writes into the working
  # copy that gets passed to the collector, by having the mock collector dump
  # its --config argument to a file before the script's EXIT trap deletes it.
  def run_and_capture_working_config(dir, initial_content)
    config_path = File.join(dir, 'collect.yml')
    File.write(config_path, initial_content)

    data_dir = File.join(dir, 'data')
    FileUtils.mkdir_p(data_dir)

    captured_config_path = File.join(dir, 'captured-working-config.yml')

    bin_dir = File.join(dir, 'bin')
    FileUtils.mkdir_p(bin_dir)
    mock_bin = File.join(bin_dir, 'telemetry-cli-linux')
    File.write(mock_bin, <<~SH)
      #!/bin/bash
      for arg in "$@"; do
        if [ "$prev" = "--config" ]; then
          cp "$arg" "#{captured_config_path}" 2>/dev/null
        fi
        prev="$arg"
      done
      mkdir -p #{data_dir}
      touch #{data_dir}/test.tar
      exit 0
    SH
    FileUtils.chmod(0755, mock_bin)

    chown_bin = File.join(bin_dir, 'chown')
    File.write(chown_bin, "#!/bin/bash\nexit 0\n")
    FileUtils.chmod(0755, chown_bin)

    compiled_script = compile_erb_template(template_content, properties)
    pre_start_path = File.join(dir, 'pre-start-collect.yml')
    File.write(pre_start_path, initial_content)

    test_script_path = File.join(dir, 'test-collect-send.sh')
    script_with_mocks = compiled_script
      .gsub('COLLECTOR_BIN=/var/vcap/packages/telemetry-cli/telemetry-cli-linux', "COLLECTOR_BIN=#{mock_bin}")
      .gsub('/var/vcap/data/tmp/telemetry-collector', File.join(data_dir, 'run'))
      .gsub('/var/vcap/data/telemetry-collector', data_dir)
      .gsub('/var/vcap/jobs/telemetry-collector/config/pre-start-collect.yml', pre_start_path)
      .gsub('/var/vcap/jobs/telemetry-collector/config/collect.yml', config_path)

    script_with_path = "export PATH=\"#{bin_dir}:${PATH}\"\n" + script_with_mocks
    File.write(test_script_path, script_with_path)
    FileUtils.chmod(0755, test_script_path)

    exit_status = system("bash #{test_script_path} #{config_path} >/dev/null 2>&1")

    captured = File.exist?(captured_config_path) ? File.read(captured_config_path) : nil
    [exit_status, captured]
  end

  it 'applies the app-usage prefix to any usage_service_url without a scheme, matching historical behavior' do
    # We don't have evidence that a real customer or another tile built on
    # telemetry-release has ever overridden this value with something that
    # must NOT be prefixed (see conversation history), so this intentionally
    # keeps the old "always prefix unless it already has a scheme" behavior.
    # This is an open question, not a settled one -- if/when there's real
    # evidence of a customer-supplied, non-TAS-convention usage service host,
    # this test (and the script) will need to change.
    Dir.mktmpdir do |dir|
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Enabled
        usage-service-url: sys.some-foundation.example.com
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML

      _exit_status, captured = run_and_capture_working_config(dir, initial_content)

      expect(captured).not_to be_nil
      expect(captured).to include('usage-service-url: https://app-usage.sys.some-foundation.example.com')
    end
  end

  it 'leaves a usage_service_url that already has a scheme untouched' do
    Dir.mktmpdir do |dir|
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Enabled
        usage-service-url: https://usage.mycorp.internal
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML

      _exit_status, captured = run_and_capture_working_config(dir, initial_content)

      expect(captured).not_to be_nil
      expect(captured).to include('usage-service-url: https://usage.mycorp.internal')
      expect(captured).not_to include('app-usage')
    end
  end

  it 'applies the prefix to a host name that starts with "http" but has no scheme' do
    # The old check was `^http`, which also matched a host name beginning with
    # those four letters. Such a host looked like it already had a scheme and
    # was left alone, so the collector was given a URL with no scheme at all.
    # The check is now `^https?://`.
    Dir.mktmpdir do |dir|
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Enabled
        usage-service-url: http-usage.mycorp.internal
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML

      _exit_status, captured = run_and_capture_working_config(dir, initial_content)

      expect(captured).not_to be_nil
      expect(captured).to include('usage-service-url: https://app-usage.http-usage.mycorp.internal')
    end
  end

  it 'does not break the script (and still applies the prefix correctly) when usage_service_url contains a sed delimiter character' do
    # Previously: any value containing "~" broke the old sed s~~~ substitution
    # (embedded directly in the search pattern) and, with `set -e`, aborted
    # the whole script. The search pattern is now a fixed anchor instead of
    # embedding the value, so this succeeds and still applies the prefix.
    Dir.mktmpdir do |dir|
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Enabled
        usage-service-url: usage~mycorp.internal
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML

      exit_status, captured = run_and_capture_working_config(dir, initial_content)

      expect(exit_status).to be_truthy
      expect(captured).not_to be_nil
      expect(captured).to include('usage-service-url: https://app-usage.usage~mycorp.internal')
    end
  end

  it 'correctly escapes sed-special characters in the value when applying the app-usage prefix' do
    # The replacement text is escaped rather than embedded raw in the sed
    # pattern, so this must survive '&', '|', and '\' in the value without
    # corrupting the substitution.
    Dir.mktmpdir do |dir|
      weird_domain = 'sys.weird&domain|with\\backslash.example.com'
      initial_content = <<~YAML
        data-collection-multi-select-options: ["operational_data", "ceip_data"]
        tas-installed-selector: Enabled
        usage-service-url: #{weird_domain}
        usage-service-client-id: my-client-id
        usage-service-client-secret: my-secret
      YAML

      exit_status, captured = run_and_capture_working_config(dir, initial_content)

      expect(exit_status).to be_truthy
      expect(captured).not_to be_nil
      expect(captured).to include("usage-service-url: https://app-usage.#{weird_domain}")
    end
  end

  it 'keeps the working copy under /var/vcap/data and not in /tmp' do
    # The working copy is a verbatim copy of collect.yml, so it holds the Ops
    # Manager password and the usage service client secret. The EXIT trap does
    # not run on SIGKILL, so a leaked copy must not sit in a world-readable
    # directory.
    expect(template_content).to include('working_dir="/var/vcap/data/tmp/telemetry-collector"')
    expect(template_content).not_to match(%r{working_config="/tmp/})
  end

  it 'keeps the working copy OUT of the TAR output directory' do
    # /var/vcap/data/telemetry-collector is a handoff point between products: the
    # collector writes TARs there and the Platform Services tile has
    # hub-tas-agent collect them from it. A file full of credentials must not be
    # dropped into a directory another product scans.
    working_dir = template_content[/working_dir="([^"]+)"/, 1]
    expect(working_dir).not_to be_nil
    expect(working_dir).not_to start_with('/var/vcap/data/telemetry-collector')
  end

  it 'restricts the working copy itself, not just its directory' do
    # cp leaves an existing destination's mode alone, so creating the file 0600
    # first means the copy is never readable by anyone else, even briefly.
    expect(template_content).to match(/: > "\$\{working_config\}"\s*\n\s*chmod 600 "\$\{working_config\}"/)
  end

  it 'restricts the working directory to its owner' do
    expect(template_content).to include('chmod 700 "${working_dir}"')
  end

  it 'fails with a clear message when no config path is passed' do
    # Both callers always pass one: bin/pre-start passes pre-start-collect.yml
    # and the cron entry passes collect.yml. Defaulting to collect.yml would
    # let a caller that forgot silently collect against the wrong file.
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      chown_bin = File.join(bin_dir, 'chown')
      File.write(chown_bin, "#!/bin/bash\nexit 0\n")
      FileUtils.chmod(0755, chown_bin)

      data_dir = File.join(dir, 'data')
      FileUtils.mkdir_p(data_dir)

      compiled_script = compile_erb_template(template_content, properties)
      script_with_mocks = compiled_script
        .gsub('/var/vcap/data/tmp/telemetry-collector', File.join(data_dir, 'run'))
      .gsub('/var/vcap/data/telemetry-collector', data_dir)

      test_script_path = File.join(dir, 'test-collect-send.sh')
      File.write(test_script_path, "export PATH=\"#{bin_dir}:${PATH}\"\n" + script_with_mocks)
      FileUtils.chmod(0755, test_script_path)

      stdout_and_stderr = `bash #{test_script_path} 2>&1`
      exit_status = $?.exitstatus

      expect(exit_status).to eq(1)
      expect(stdout_and_stderr).to include('requires a config file path as its first argument')
    end
  end
end
