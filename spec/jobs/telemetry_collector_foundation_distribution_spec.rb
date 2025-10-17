require 'spec_helper'
require 'digest'

describe 'telemetry-collector-cron foundation distribution' do
  let(:template_content) do
    File.read(File.join(File.dirname(__FILE__), '../../jobs/telemetry-collector/templates/telemetry-collector-cron.erb'))
  end

  describe 'foundation-specific scheduling' do
    it 'produces same schedule for same foundation' do
      deployment_name = 'prod-pcf-01'
      spec_data = { deployment: deployment_name, index: 0 }
      properties = { 'schedule' => 'random' }

      # Compile template multiple times with same deployment
      schedule1 = compile_erb_template(template_content, properties, spec_data)
      schedule2 = compile_erb_template(template_content, properties, spec_data)
      schedule3 = compile_erb_template(template_content, properties, spec_data)

      # All should be identical
      expect(schedule1).to eq(schedule2)
      expect(schedule2).to eq(schedule3)
    end

    it 'produces different schedules for different foundations' do
      properties = { 'schedule' => 'random' }
      
      # Test with different deployment names
      foundation1_spec = { deployment: 'prod-pcf-01', index: 0 }
      foundation2_spec = { deployment: 'prod-pcf-02', index: 0 }
      foundation3_spec = { deployment: 'prod-pcf-03', index: 0 }

      schedule1 = compile_erb_template(template_content, properties, foundation1_spec)
      schedule2 = compile_erb_template(template_content, properties, foundation2_spec)
      schedule3 = compile_erb_template(template_content, properties, foundation3_spec)

      # All should be different
      expect(schedule1).to_not eq(schedule2)
      expect(schedule2).to_not eq(schedule3)
      expect(schedule1).to_not eq(schedule3)
    end

    it 'maintains 60-minute window within same foundation' do
      deployment_name = 'prod-pcf-01'
      properties = { 'schedule' => 'random' }

      # Test multiple VMs in same foundation
      schedules = (0..99).map do |vm_index|
        spec_data = { deployment: deployment_name, index: vm_index }
        compile_erb_template(template_content, properties, spec_data)
      end

      # Parse all schedules
      parsed_schedules = schedules.map { |s| parse_cron_schedule(s) }
      
      # Convert to minutes since midnight
      times_in_minutes = parsed_schedules.map { |s| time_in_minutes(s[:hour], s[:minute]) }
      
      # Find min and max times
      min_time = times_in_minutes.min
      max_time = times_in_minutes.max
      
      # Calculate span
      span = max_time - min_time
      
      # Should be within 60 minutes (accounting for day rollover)
      # If span > 12 hours, it means we rolled over midnight
      if span > 12 * 60
        span = (24 * 60) - span
      end
      
      expect(span).to be <= 60, "Foundation spans #{span} minutes, should be ≤ 60"
    end

    it 'handles hour rollover correctly' do
      deployment_name = 'rollover-test'
      properties = { 'schedule' => 'random' }

      # Test VMs that would cause hour rollover
      schedules = (55..65).map do |vm_index|
        spec_data = { deployment: deployment_name, index: vm_index }
        compile_erb_template(template_content, properties, spec_data)
      end

      parsed_schedules = schedules.map { |s| parse_cron_schedule(s) }
      
      # All schedules should be valid
      parsed_schedules.each do |schedule|
        expect(schedule[:hour]).to be_between(0, 23)
        expect(schedule[:minute]).to be_between(0, 59)
      end
    end
  end

  describe 'edge cases' do
    it 'handles nil deployment name' do
      properties = { 'schedule' => 'random' }
      spec_data = { deployment: nil, index: 0 }

      schedule = compile_erb_template(template_content, properties, spec_data)
      parsed = parse_cron_schedule(schedule)
      
      expect(parsed[:hour]).to be_between(0, 23)
      expect(parsed[:minute]).to be_between(0, 59)
    end

    it 'handles empty deployment name' do
      properties = { 'schedule' => 'random' }
      spec_data = { deployment: '', index: 0 }

      schedule = compile_erb_template(template_content, properties, spec_data)
      parsed = parse_cron_schedule(schedule)
      
      expect(parsed[:hour]).to be_between(0, 23)
      expect(parsed[:minute]).to be_between(0, 59)
    end

    it 'handles special characters in deployment name' do
      properties = { 'schedule' => 'random' }
      special_deployments = [
        'prod-pcf-01!@#$%^&*()',
        'foundation with spaces',
        'deployment-with-dashes',
        'deployment_with_underscores',
        'deployment.with.dots'
      ]

      special_deployments.each do |deployment_name|
        spec_data = { deployment: deployment_name, index: 0 }
        schedule = compile_erb_template(template_content, properties, spec_data)
        parsed = parse_cron_schedule(schedule)
        
        expect(parsed[:hour]).to be_between(0, 23)
        expect(parsed[:minute]).to be_between(0, 59)
      end
    end

    it 'handles unicode characters in deployment name' do
      properties = { 'schedule' => 'random' }
      unicode_deployments = [
        'foundation-测试',
        'deployment-日本語',
        'foundation-тест',
        'deployment-العربية'
      ]

      unicode_deployments.each do |deployment_name|
        spec_data = { deployment: deployment_name, index: 0 }
        schedule = compile_erb_template(template_content, properties, spec_data)
        parsed = parse_cron_schedule(schedule)
        
        expect(parsed[:hour]).to be_between(0, 23)
        expect(parsed[:minute]).to be_between(0, 59)
      end
    end

    it 'handles very long deployment names' do
      properties = { 'schedule' => 'random' }
      long_name = 'a' * 1000  # 1000 character deployment name
      spec_data = { deployment: long_name, index: 0 }

      schedule = compile_erb_template(template_content, properties, spec_data)
      parsed = parse_cron_schedule(schedule)
      
      expect(parsed[:hour]).to be_between(0, 23)
      expect(parsed[:minute]).to be_between(0, 59)
    end

    it 'handles numeric deployment names' do
      properties = { 'schedule' => 'random' }
      spec_data = { deployment: 12345, index: 0 }

      schedule = compile_erb_template(template_content, properties, spec_data)
      parsed = parse_cron_schedule(schedule)
      
      expect(parsed[:hour]).to be_between(0, 23)
      expect(parsed[:minute]).to be_between(0, 59)
    end

    it 'preserves non-random schedules' do
      properties = { 'schedule' => '0 12 * * *' }  # Fixed schedule
      spec_data = { deployment: 'any-deployment', index: 0 }

      schedule = compile_erb_template(template_content, properties, spec_data).strip
      
      expect(schedule).to eq('0 12 * * * vcap /var/vcap/jobs/telemetry-collector/bin/telemetry-collect-send /var/vcap/jobs/telemetry-collector/config/collect.yml >> /var/vcap/sys/log/telemetry-collector/telemetry-collect-send.log 2>> /var/vcap/sys/log/telemetry-collector/telemetry-collect-send.log')
    end
  end

  describe 'statistical distribution' do
    it 'distributes foundations across all 24 hours' do
      properties = { 'schedule' => 'random' }
      
      # Generate 1000 different foundations
      foundations = (1..1000).map { |i| "foundation-#{i}" }
      
      base_hours = foundations.map do |foundation|
        spec_data = { deployment: foundation, index: 0 }
        schedule = compile_erb_template(template_content, properties, spec_data)
        parsed = parse_cron_schedule(schedule)
        parsed[:hour]
      end
      
      # Count foundations per hour
      hour_counts = base_hours.group_by(&:itself).transform_values(&:count)
      
      # Verify each hour has foundations (within 2 sigma for uniform distribution)
      # Expected: ~42 foundations per hour (1000/24)
      # Allow variance: ≥20 per hour (conservative threshold)
      (0..23).each do |hour|
        count = hour_counts[hour] || 0
        expect(count).to be >= 20, "Hour #{hour} only has #{count} foundations (expected ~42 ± 22)"
      end
      
      # Verify no hour is completely empty
      expect(hour_counts.keys.length).to eq(24), "Not all 24 hours have foundations"
    end

    it 'produces uniform distribution across hours' do
      properties = { 'schedule' => 'random' }
      
      # Generate 2400 foundations for better statistical significance
      foundations = (1..2400).map { |i| "foundation-#{i}" }
      
      base_hours = foundations.map do |foundation|
        spec_data = { deployment: foundation, index: 0 }
        schedule = compile_erb_template(template_content, properties, spec_data)
        parsed = parse_cron_schedule(schedule)
        parsed[:hour]
      end
      
      # Count foundations per hour
      hour_counts = base_hours.group_by(&:itself).transform_values(&:count)
      
      # Calculate statistics
      expected_per_hour = 2400.0 / 24  # 100 per hour
      actual_counts = (0..23).map { |h| hour_counts[h] || 0 }
      
      # Calculate standard deviation
      variance = actual_counts.map { |count| (count - expected_per_hour) ** 2 }.sum / 24
      std_dev = Math.sqrt(variance)
      
      # Verify distribution is reasonably uniform
      # Allow 3 standard deviations from expected (more lenient for random distribution)
      max_deviation = 3 * std_dev
      
      actual_counts.each_with_index do |count, hour|
        deviation = (count - expected_per_hour).abs
        expect(deviation).to be <= max_deviation, 
          "Hour #{hour} has #{count} foundations, expected ~#{expected_per_hour.round(1)} ± #{max_deviation.round(1)}"
      end
    end
  end

  describe 'deterministic behavior' do
    it 'produces same result for same input' do
      properties = { 'schedule' => 'random' }
      spec_data = { deployment: 'test-foundation', index: 5 }
      
      # Compile multiple times
      results = 10.times.map do
        compile_erb_template(template_content, properties, spec_data)
      end
      
      # All results should be identical
      expect(results.uniq.length).to eq(1), "Non-deterministic behavior detected"
    end

    it 'produces different results for different inputs' do
      properties = { 'schedule' => 'random' }
      
      # Test different deployments
      results = (1..10).map do |i|
        spec_data = { deployment: "foundation-#{i}", index: 0 }
        compile_erb_template(template_content, properties, spec_data)
      end
      
      # All results should be different
      expect(results.uniq.length).to eq(10), "Different inputs produced same output"
    end
  end
end
