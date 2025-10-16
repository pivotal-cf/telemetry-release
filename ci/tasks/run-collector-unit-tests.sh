#!/usr/bin/env bash

set -euo pipefail

cd telemetry-release-source

echo "Installing Ruby dependencies..."
gem install bundler:2.6.8
bundle _2.6.8_ install

echo "Running telemetry collector unit tests..."
bundle _2.6.8_ exec rspec spec/jobs/telemetry_collector_cron_spec.rb --format documentation

echo "Running telemetry collector integration tests..."
bundle _2.6.8_ exec rspec spec/integration/telemetry_collector_stagger_spec.rb --format documentation

echo "All tests passed successfully!"
