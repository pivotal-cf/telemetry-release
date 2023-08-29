#!/usr/bin/env bash

set -euo pipefail

cd telemetry-receiver-source/src/fluentd/telemetry-filter-plugin
gem install bundler:2.3.26
bundle && rspec .
