#!/usr/bin/env bash

set -euo pipefail

cd telemetry-receiver-source/src/fluentd/telemetry-filter-plugin
gem install bundler:2.5.6
bundle && rspec .
