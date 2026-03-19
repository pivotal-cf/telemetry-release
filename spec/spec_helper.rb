require 'rspec'
require 'erb'
require 'time'
require 'ostruct'
require 'base64'

def fluentd_available?
  require 'fluent/tls'
  true
rescue LoadError
  false
end

# Chainable return value for if_p().else {} -- mirrors BOSH ERB behavior
class IfPResult
  def initialize(matched)
    @matched = matched
  end

  def else(&block)
    block.call unless @matched
  end
end

# Helper methods for testing ERB templates
module ERBTestHelper
  def compile_erb_template(template_content, properties = {}, spec_data = {}, links = {})
    binding_context = Object.new

    binding_context.define_singleton_method(:p) do |key|
      if key.include?('.')
        parts = key.split('.')
        value = properties
        parts.each do |part|
          if value.is_a?(Hash) && value.key?(part)
            value = value[part]
          elsif value.is_a?(Hash) && value.key?(part.to_sym)
            value = value[part.to_sym]
          else
            return ''
          end
        end
        value
      elsif properties.key?(key)
        properties[key]
      elsif properties.key?(key.to_sym)
        properties[key.to_sym]
      else
        ''
      end
    end

    binding_context.define_singleton_method(:spec) do
      spec_defaults = {
        deployment: 'test-deployment',
        release: OpenStruct.new(version: spec_data.dig(:release, :version) || '0.0.0')
      }
      OpenStruct.new(spec_defaults.merge(spec_data))
    end

    binding_context.define_singleton_method(:if_p) do |key, &block|
      value = nil
      found = false

      if key.include?('.')
        parts = key.split('.')
        v = properties
        parts.each do |part|
          if v.is_a?(Hash) && v.key?(part)
            v = v[part]
          else
            v = nil
            break
          end
        end
        unless v.nil?
          found = true
          value = v
        end
      elsif properties.key?(key) && !properties[key].nil?
        found = true
        value = properties[key]
      end

      block.call(value) if found
      IfPResult.new(found)
    end

    binding_context.define_singleton_method(:link) do |name|
      link_data = links[name]
      raise "Link '#{name}' not provided in test data" unless link_data

      link_obj = Object.new
      link_props = link_data[:properties] || {}

      link_obj.define_singleton_method(:address) do
        link_data[:address] || raise("Link '#{name}' has no address defined")
      end

      link_obj.define_singleton_method(:p) do |prop_key|
        if link_props.key?(prop_key)
          link_props[prop_key]
        elsif link_props.key?(prop_key.to_sym)
          link_props[prop_key.to_sym]
        else
          raise "Link '#{name}' has no property '#{prop_key}'"
        end
      end

      link_obj
    end

    erb = ERB.new(template_content)
    binding_context.instance_variable_set(:@__base64__, ::Base64)
    binding_context.define_singleton_method(:const_missing) do |name|
      if name == :Base64
        @__base64__
      else
        super(name)
      end
    end
    erb.result(binding_context.instance_eval { binding })
  end

  def parse_cron_schedule(schedule_string)
    # Parse cron schedule and return hour and minute
    parts = schedule_string.split
    minute = parts[0].to_i
    hour = parts[1].to_i
    { minute: minute, hour: hour }
  end

  def time_in_minutes(hour, minute)
    (hour * 60) + minute
  end

  def minutes_to_time(minutes)
    hour = (minutes / 60) % 24
    minute = minutes % 60
    { hour: hour, minute: minute }
  end

  def parse_json_log_line(log_line)
    JSON.parse(log_line.strip)
  rescue JSON::ParserError
    nil
  end

  def mock_telemetry_cli_behavior(collect_exit_code: 0, send_exit_code: 0, send_output: '')
    # This would be used in integration tests to mock the telemetry-cli behavior
    # For now, we'll implement this in the actual test files
    { collect_exit_code: collect_exit_code, send_exit_code: send_exit_code, send_output: send_output }
  end

  def create_temp_log_directory
    require 'tmpdir'
    temp_dir = Dir.mktmpdir('telemetry_test_logs')
    FileUtils.mkdir_p("#{temp_dir}/telemetry-collector")
    temp_dir
  end

  def cleanup_temp_directory(temp_dir)
    FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
  end
end

RSpec.configure do |config|
  config.include ERBTestHelper

  # Cleanup temp directories after each test
  config.after(:each) do
    cleanup_temp_directory(@temp_log_dir) if @temp_log_dir
  end
end
