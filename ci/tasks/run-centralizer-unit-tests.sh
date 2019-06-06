#!/usr/bin/env bash

set -euo pipefail

cd telemetry-components-release/src/fluentd/telemetry-filter-plugin
bundle && rspec .
