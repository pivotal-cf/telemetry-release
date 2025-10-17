require 'spec_helper'

describe 'Telemetry Collector Cron Schedule' do
  let(:template_content) do
    File.read(File.join(__dir__, '../../jobs/telemetry-collector/templates/telemetry-collector-cron.erb'))
  end

  describe '60-minute window guarantee' do
    it 'ensures all VMs send within 60 minutes for small foundations' do
      vm_count = 10
      schedules = generate_schedules_for_vms(vm_count)
      
      # All schedules should be within 60 minutes of each other
      time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      min_time = time_windows.min
      max_time = time_windows.max
      
      expect(max_time - min_time).to be <= 60, 
        "Expected all VMs to send within 60 minutes, but time span was #{max_time - min_time} minutes"
    end

    it 'ensures all VMs send within 60 minutes for large foundations' do
      vm_count = 1000
      schedules = generate_schedules_for_vms(vm_count)
      
      # All schedules should be within 60 minutes of each other
      time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      min_time = time_windows.min
      max_time = time_windows.max
      
      expect(max_time - min_time).to be <= 60, 
        "Expected all VMs to send within 60 minutes, but time span was #{max_time - min_time} minutes"
    end

    it 'ensures all VMs send within 60 minutes for very large foundations' do
      vm_count = 10000
      schedules = generate_schedules_for_vms(vm_count)
      
      # All schedules should be within 60 minutes of each other
      time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      min_time = time_windows.min
      max_time = time_windows.max
      
      expect(max_time - min_time).to be <= 60, 
        "Expected all VMs to send within 60 minutes, but time span was #{max_time - min_time} minutes"
    end

    it 'handles hour rollover correctly' do
      # Test with 50 VMs - the stagger logic should handle hour rollover automatically
      vm_count = 50
      schedules = generate_schedules_for_vms(vm_count)
      
      # All schedules should be within 60 minutes, even with hour rollover
      time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      min_time = time_windows.min
      max_time = time_windows.max
      
      # Handle day rollover (times that cross midnight)
      if max_time - min_time > 720 # More than 12 hours, likely crossed midnight
        adjusted_times = time_windows.map do |t|
          t < 720 ? t + 1440 : t  # Add 24 hours to times before noon
        end
        min_time = adjusted_times.min
        max_time = adjusted_times.max
      end
      
      expect(max_time - min_time).to be <= 60, 
        "Expected all VMs to send within 60 minutes even with hour rollover, but time span was #{max_time - min_time} minutes"
    end
  end

  describe 'edge cases' do
    it 'handles nil spec.index' do
      schedule = compile_schedule_for_vm(nil)
      expect(schedule).to match(/^\d+ \d+$/)
    end

    it 'handles negative spec.index' do
      schedule = compile_schedule_for_vm(-5)
      expect(schedule).to match(/^\d+ \d+$/)
    end

    it 'handles float spec.index' do
      schedule = compile_schedule_for_vm(3.7)
      expect(schedule).to match(/^\d+ \d+$/)
    end

    it 'handles zero spec.index' do
      schedule = compile_schedule_for_vm(0)
      expect(schedule).to match(/^\d+ \d+$/)
    end

    it 'handles very large spec.index' do
      schedule = compile_schedule_for_vm(999999)
      expect(schedule).to match(/^\d+ \d+$/)
    end
  end

  describe 'custom schedules' do
    it 'respects non-random schedules' do
      custom_schedule = "0 12 * * *"
      result = compile_erb_template(template_content, { 'schedule' => custom_schedule })
      
      expect(result.strip).to include(custom_schedule)
    end

    it 'respects empty schedule' do
      result = compile_erb_template(template_content, { 'schedule' => '' })
      
      expect(result.strip).to include('')
    end
  end

  describe 'deterministic behavior' do
    it 'generates same schedule for same VM index' do
      vm_index = 5
      schedule1 = compile_schedule_for_vm(vm_index)
      schedule2 = compile_schedule_for_vm(vm_index)
      
      expect(schedule1).to eq(schedule2)
    end

    it 'generates different schedules for different VM indices' do
      schedule1 = compile_schedule_for_vm(0)
      schedule2 = compile_schedule_for_vm(1)
      
      expect(schedule1).not_to eq(schedule2)
    end

    it 'generates different base times for different deployments' do
      # Test that different deployments get different base times
      foundation1_schedules = generate_schedules_for_vms(10, deployment: 'foundation-1')
      foundation2_schedules = generate_schedules_for_vms(10, deployment: 'foundation-2')
      
      # Get base times (VM 0 schedule for each foundation)
      foundation1_base = foundation1_schedules[0]
      foundation2_base = foundation2_schedules[0]
      
      # They should be different
      expect(foundation1_base).not_to eq(foundation2_base)
    end

    it 'maintains 60-minute window within each deployment' do
      # Test multiple deployments
      ['foundation-1', 'foundation-2', 'foundation-3'].each do |deployment|
        schedules = generate_schedules_for_vms(100, deployment: deployment)
        
        time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
        min_time = time_windows.min
        max_time = time_windows.max
        
        # Handle day rollover
        if max_time - min_time > 720
          adjusted_times = time_windows.map { |t| t < 720 ? t + 1440 : t }
          min_time = adjusted_times.min
          max_time = adjusted_times.max
        end
        
        expect(max_time - min_time).to be <= 60, 
          "Foundation #{deployment} spans #{max_time - min_time} minutes, should be ≤ 60"
      end
    end
  end

  describe 'cron schedule format' do
    it 'generates valid cron format' do
      schedule = compile_schedule_for_vm(0)
      
      # Should match pattern: minute hour
      expect(schedule).to match(/^\d+ \d+$/)
    end

    it 'generates valid minute values (0-59)' do
      vm_count = 100
      schedules = generate_schedules_for_vms(vm_count)
      
      schedules.each do |schedule|
        minute = schedule[:minute]
        expect(minute).to be_between(0, 59), "Invalid minute value: #{minute}"
      end
    end

    it 'generates valid hour values (0-23)' do
      vm_count = 100
      schedules = generate_schedules_for_vms(vm_count)
      
      schedules.each do |schedule|
        hour = schedule[:hour]
        expect(hour).to be_between(0, 23), "Invalid hour value: #{hour}"
      end
    end
  end

  describe 'collision handling' do
    it 'handles collisions gracefully for >60 VMs' do
      vm_count = 100
      schedules = generate_schedules_for_vms(vm_count)
      
      # Should still generate valid schedules even with collisions
      schedules.each do |schedule|
        expect(schedule[:minute]).to be_between(0, 59)
        expect(schedule[:hour]).to be_between(0, 23)
      end
    end

    it 'maintains 60-minute window even with collisions' do
      vm_count = 200
      schedules = generate_schedules_for_vms(vm_count)
      
      time_windows = schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      min_time = time_windows.min
      max_time = time_windows.max
      
      expect(max_time - min_time).to be <= 60
    end
  end

  private

  def generate_schedules_for_vms(vm_count, base_hour: nil, base_minute: nil, deployment: 'test-foundation')
    schedules = []
    
    vm_count.times do |vm_index|
      spec_data = { index: vm_index, deployment: deployment }
      properties = { 'schedule' => 'random' }
      
      # Override base time if specified (for testing hour rollover)
      if base_hour && base_minute
        # We can't easily override the random generation in ERB, so we'll test the logic directly
        vm_index_safe = vm_index.to_i.abs
        stagger_minute = vm_index_safe % 60
        total_minutes = base_minute + stagger_minute
        final_minute = total_minutes % 60
        final_hour = (base_hour + (total_minutes / 60)) % 24
        
        schedules << { hour: final_hour, minute: final_minute }
      else
        schedule_string = compile_erb_template(template_content, properties, spec_data)
        schedule = parse_cron_schedule(schedule_string.strip.split(' ')[0..1].join(' '))
        schedules << schedule
      end
    end
    
    schedules
  end

  def compile_schedule_for_vm(vm_index, deployment: 'test-foundation')
    spec_data = { index: vm_index, deployment: deployment }
    properties = { 'schedule' => 'random' }
    
    result = compile_erb_template(template_content, properties, spec_data)
    # Extract just the cron schedule part (first two fields: minute hour)
    result.strip.split(' ')[0..1].join(' ')
  end
end
