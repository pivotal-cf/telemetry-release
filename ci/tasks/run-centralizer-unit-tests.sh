#!/usr/bin/env bash

set -euo pipefail

cd telemetry-release/src/fluentd/telemetry-filter-plugin
gem install bundler:1.16.2
bundle && rspec .
