#!/usr/bin/env bash

set -euo pipefail

cd telemetry-receiver-source/src/fluentd/telemetry-filter-plugin
gem install bundler:2.6.8
bundle && rspec .
