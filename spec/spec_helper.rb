require 'rspec'
require 'erb'
require 'time'
require 'ostruct'
require 'base64'

# Helper methods for testing ERB templates
module ERBTestHelper
  def compile_erb_template(template_content, properties = {}, spec_data = {})
    # Create a binding with the properties and spec data
    binding_context = Object.new
    
    # Add properties method
    binding_context.define_singleton_method(:p) do |key|
      # Handle nested properties like 'telemetry.proxy_settings.proxy_username'
      if key.include?('.')
        parts = key.split('.')
        value = properties
        parts.each do |part|
          if value.is_a?(Hash) && value.key?(part)
            value = value[part]
          elsif value.is_a?(Hash) && value.key?(part.to_sym)
            value = value[part.to_sym]
          else
            return ''  # Return empty string for missing properties (BOSH default)
          end
        end
        value
      else
        properties[key] || properties[key.to_sym] || ''
      end
    end
    
    # Add spec method
    binding_context.define_singleton_method(:spec) do
      spec_obj = OpenStruct.new(spec_data)
      # Ensure deployment is available
      spec_obj.deployment ||= spec_data[:deployment] || 'test-deployment'
      spec_obj
    end
    
    # Add if_p method for ERB templates
    binding_context.define_singleton_method(:if_p) do |key, &block|
      # Handle nested properties like 'telemetry.endpoint_override'
      if key.include?('.')
        parts = key.split('.')
        value = properties
        parts.each do |part|
          if value.is_a?(Hash) && value.key?(part)
            value = value[part]
          else
            value = nil
            break
          end
        end
        if !value.nil?
          block.call(value)
        end
      else
        if properties.key?(key) && !properties[key].nil?
          block.call(properties[key])
        end
      end
    end
    
    # Compile and evaluate the ERB template
    erb = ERB.new(template_content)
    # Make Base64 and other constants available in the binding
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
    parts = schedule_string.split(' ')
    minute = parts[0].to_i
    hour = parts[1].to_i
    { minute: minute, hour: hour }
  end
  
  def time_in_minutes(hour, minute)
    hour * 60 + minute
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
  
  def mock_telemetry_cli_behavior(collect_exit_code: 0, send_exit_code: 0, send_output: "")
    # This would be used in integration tests to mock the telemetry-cli behavior
    # For now, we'll implement this in the actual test files
    { collect_exit_code: collect_exit_code, send_exit_code: send_exit_code, send_output: send_output }
  end
  
  def create_temp_log_directory
    require 'tmpdir'
    temp_dir = Dir.mktmpdir("telemetry_test_logs")
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
    if @temp_log_dir
      cleanup_temp_directory(@temp_log_dir)
    end
  end
end
