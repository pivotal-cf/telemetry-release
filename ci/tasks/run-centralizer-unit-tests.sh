#!/usr/bin/env bash

set -euo pipefail

cd telemetry-release/src/fluentd/telemetry-filter-plugin
gem install bundler:2.3.20
bundle && rspec .
