require 'rspec'
require 'erb'
require 'time'
require 'ostruct'

# Helper methods for testing ERB templates
module ERBTestHelper
  def compile_erb_template(template_content, properties = {}, spec_data = {})
    # Create a binding with the properties and spec data
    binding_context = Object.new
    
    # Add properties method
    binding_context.define_singleton_method(:p) do |key|
      properties[key]
    end
    
    # Add spec method
    binding_context.define_singleton_method(:spec) do
      OpenStruct.new(spec_data)
    end
    
    # Compile and evaluate the ERB template
    erb = ERB.new(template_content)
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
end

RSpec.configure do |config|
  config.include ERBTestHelper
end
