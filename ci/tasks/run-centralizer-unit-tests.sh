#!/usr/bin/env bash

set -euo pipefail

cd telemetry-release/src/fluentd/telemetry-filter-plugin
gem install bundler:2.1.4
bundle && rspec .
