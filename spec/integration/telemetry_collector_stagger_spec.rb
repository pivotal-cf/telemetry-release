require 'spec_helper'

describe 'Telemetry Collector Stagger Integration' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collector-cron.erb'))
  end

  describe 'ERB template compilation' do
    it 'compiles successfully with valid spec.index values' do
      valid_indices = [0, 1, 10, 100, 1000, nil, -5, 3.7]
      
      valid_indices.each do |index|
        expect {
          compile_erb_template(template_content, { 'schedule' => 'random' }, { index: index })
        }.not_to raise_error, "Failed to compile ERB template with spec.index = #{index}"
      end
    end

    it 'generates valid cron schedules for realistic foundation sizes' do
      foundation_sizes = [1, 5, 10, 50, 100, 500]
      
      foundation_sizes.each do |vm_count|
        schedules = generate_schedules_for_foundation(vm_count)
        
        # All schedules should be valid time format
        schedules.each do |schedule|
          expect(schedule).to match(/^\d+ \d+$/), 
            "Invalid time format: #{schedule}"
        end
        
        # All schedules should be within 60-minute window
        time_windows = schedules.map { |s| parse_cron_schedule(s) }
        time_minutes = time_windows.map { |t| time_in_minutes(t[:hour], t[:minute]) }
        min_time = time_minutes.min
        max_time = time_minutes.max
        
        expect(max_time - min_time).to be <= 60,
          "Foundation with #{vm_count} VMs exceeded 60-minute window: #{max_time - min_time} minutes"
      end
    end

    it 'handles edge cases in ERB compilation' do
      edge_cases = [
        { index: nil },
        { index: 0 },
        { index: -1 },
        { index: 3.14159 },
        { index: 999999 },
        { index: 'string' }
      ]
      
      edge_cases.each do |spec_data|
        expect {
          result = compile_erb_template(template_content, { 'schedule' => 'random' }, spec_data)
          expect(result).to match(/^\d+ \d+ \* \* \*/)
        }.not_to raise_error, "Failed to handle edge case: #{spec_data}"
      end
    end
  end

  describe 'cron schedule parsing' do
    it 'parses generated schedules correctly' do
      vm_count = 50
      schedules = generate_schedules_for_foundation(vm_count)
      
      schedules.each do |schedule|
        parsed = parse_cron_schedule(schedule)
        
        expect(parsed[:minute]).to be_between(0, 59)
        expect(parsed[:hour]).to be_between(0, 23)
      end
    end

    it 'handles hour rollover in parsing' do
      # Test schedules that cross hour boundaries
      test_schedules = [
        "59 23 * * *",  # 23:59
        "0 0 * * *",    # 00:00 (next day)
        "1 0 * * *",    # 00:01 (next day)
      ]
      
      test_schedules.each do |schedule|
        parsed = parse_cron_schedule(schedule)
        expect(parsed[:minute]).to be_between(0, 59)
        expect(parsed[:hour]).to be_between(0, 23)
      end
    end
  end

  describe 'time window validation' do
    it 'validates 60-minute window for small foundations' do
      foundation_sizes = [1, 2, 5, 10]
      
      foundation_sizes.each do |vm_count|
        schedules = generate_schedules_for_foundation(vm_count)
        validate_time_window(schedules, vm_count)
      end
    end

    it 'validates 60-minute window for medium foundations' do
      foundation_sizes = [25, 50, 100]
      
      foundation_sizes.each do |vm_count|
        schedules = generate_schedules_for_foundation(vm_count)
        validate_time_window(schedules, vm_count)
      end
    end

    it 'validates 60-minute window for large foundations' do
      foundation_sizes = [200, 500, 1000]
      
      foundation_sizes.each do |vm_count|
        schedules = generate_schedules_for_foundation(vm_count)
        validate_time_window(schedules, vm_count)
      end
    end

    it 'handles hour rollover scenarios' do
      # Test with base time that would cause hour rollover
      vm_count = 50
      schedules = generate_schedules_for_foundation(vm_count)
      
      # Convert all times to minutes since midnight
      time_minutes = schedules.map do |schedule|
        parsed = parse_cron_schedule(schedule)
        time_in_minutes(parsed[:hour], parsed[:minute])
      end
      
      # Find the time span
      min_time = time_minutes.min
      max_time = time_minutes.max
      
      # Handle day rollover (times that cross midnight)
      if max_time - min_time > 720 # More than 12 hours, likely crossed midnight
        # Adjust for day rollover
        adjusted_times = time_minutes.map do |t|
          t < 720 ? t + 1440 : t  # Add 24 hours to times before noon
        end
        min_time = adjusted_times.min
        max_time = adjusted_times.max
      end
      
      expect(max_time - min_time).to be <= 60,
        "Time window exceeded 60 minutes: #{max_time - min_time} minutes"
    end
  end

  describe 'realistic deployment scenarios' do
    it 'simulates typical PCF deployment (10-50 VMs)' do
      vm_count = 30
      schedules = generate_schedules_for_foundation(vm_count)
      
      # Should have good distribution across the hour
      time_minutes = schedules.map do |schedule|
        parsed = parse_cron_schedule(schedule)
        time_in_minutes(parsed[:hour], parsed[:minute])
      end
      
      # Check that we have reasonable distribution
      unique_times = time_minutes.uniq.count
      expect(unique_times).to be >= [vm_count, 60].min,
        "Expected good time distribution, got #{unique_times} unique times for #{vm_count} VMs"
    end

    it 'simulates large enterprise deployment (100-500 VMs)' do
      vm_count = 200
      schedules = generate_schedules_for_foundation(vm_count)
      
      # Should still fit within 60-minute window
      validate_time_window(schedules, vm_count)
      
      # Should have some collisions (expected with >60 VMs)
      time_minutes = schedules.map do |schedule|
        parsed = parse_cron_schedule(schedule)
        time_in_minutes(parsed[:hour], parsed[:minute])
      end
      
      unique_times = time_minutes.uniq.count
      expect(unique_times).to be <= 60,
        "Expected some collisions with #{vm_count} VMs, but got #{unique_times} unique times"
    end
  end

  private

  def generate_schedules_for_foundation(vm_count)
    schedules = []
    
    vm_count.times do |vm_index|
      spec_data = { index: vm_index }
      properties = { 'schedule' => 'random' }
      
      result = compile_erb_template(template_content, properties, spec_data)
      schedule = result.strip.split(' ')[0..1].join(' ')
      schedules << schedule
    end
    
    schedules
  end

  def validate_time_window(schedules, vm_count)
    time_windows = schedules.map { |s| parse_cron_schedule(s) }
    time_minutes = time_windows.map { |t| time_in_minutes(t[:hour], t[:minute]) }
    
    min_time = time_minutes.min
    max_time = time_minutes.max
    
    # Handle day rollover
    if max_time - min_time > 720 # More than 12 hours
      adjusted_times = time_minutes.map do |t|
        t < 720 ? t + 1440 : t
      end
      min_time = adjusted_times.min
      max_time = adjusted_times.max
    end
    
    expect(max_time - min_time).to be <= 60,
      "Foundation with #{vm_count} VMs exceeded 60-minute window: #{max_time - min_time} minutes"
  end
end
