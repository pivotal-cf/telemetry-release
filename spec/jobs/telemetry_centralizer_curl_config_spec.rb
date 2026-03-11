require 'spec_helper'

describe 'telemetry-centralizer curl_config.erb' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-centralizer/templates/curl_config.erb'))
  end

  let(:default_properties) do
    {
      'telemetry' => {
        'api_key' => 'test-api-key-abc123',
        'endpoint' => 'https://telemetry.example.com/v1/batch'
      }
    }
  end

  describe 'ERB rendering' do
    it 'compiles successfully with default properties' do
      expect { compile_erb_template(template_content, default_properties) }.not_to raise_error
    end

    it 'renders the API key in the Authorization header' do
      output = compile_erb_template(template_content, default_properties)
      expect(output).to include('header = "Authorization: Bearer test-api-key-abc123"')
    end

    it 'renders the endpoint as the URL' do
      output = compile_erb_template(template_content, default_properties)
      expect(output).to include('url = "https://telemetry.example.com/v1/batch"')
    end
  end

  describe 'curl configuration correctness' do
    let(:output) { compile_erb_template(template_content, default_properties) }

    it 'sets Content-Type to application/x-telemetry-json-batch' do
      expect(output).to include('header = "Content-Type: application/x-telemetry-json-batch"')
    end

    it 'sets the user-agent to TelemetryCentralizer with version' do
      expect(output).to match(/user-agent\s*=\s*"TelemetryCentralizer\/\d+\.\d+\.\d+"/)
    end

    it 'uses POST method' do
      expect(output).to include('request = "POST"')
    end

    it 'reads data from stdin' do
      expect(output).to include('data = "@-"')
    end

    it 'forces HTTP/1.1' do
      expect(output).to include('http1.1')
    end
  end

  describe 'security properties' do
    it 'does not leak the api_key outside the Authorization header' do
      output = compile_erb_template(template_content, default_properties)
      lines_with_key = output.lines.select { |l| l.include?('test-api-key-abc123') }
      expect(lines_with_key.length).to eq(1),
        "API key should only appear once (in the Authorization header), found #{lines_with_key.length} times"
      expect(lines_with_key.first).to include('Authorization: Bearer')
    end

    it 'handles api keys with special characters' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].merge('api_key' => 'key-with-$pecial&chars=foo')
      output = compile_erb_template(template_content, props)
      expect(output).to include('Authorization: Bearer key-with-$pecial&chars=foo')
    end
  end

  describe 'endpoint variations' do
    it 'handles endpoints with paths and query params' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].merge(
        'endpoint' => 'https://api.example.com/v2/telemetry?source=tile'
      )
      output = compile_erb_template(template_content, props)
      expect(output).to include('url = "https://api.example.com/v2/telemetry?source=tile"')
    end

    it 'handles endpoints with non-standard ports' do
      props = default_properties.dup
      props['telemetry'] = props['telemetry'].merge(
        'endpoint' => 'https://telemetry.internal:8443/batch'
      )
      output = compile_erb_template(template_content, props)
      expect(output).to include('url = "https://telemetry.internal:8443/batch"')
    end
  end
end
