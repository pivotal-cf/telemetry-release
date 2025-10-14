#!/usr/bin/env bash

set -euo pipefail

base="$(dirname "${BASH_SOURCE[0]}")/../.."
if [ "${AUDIT_MODE:-false}" != "true" ]; then
	cd "$base/src/acceptance_tests"
else
	cd "$base/src/acceptance_tests_audit_mode"
fi
gem install bundler:2.6.8
bundle
rspec spec
