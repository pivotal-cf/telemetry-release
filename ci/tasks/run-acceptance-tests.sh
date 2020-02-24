#!/usr/bin/env bash

base="$(dirname "$BASH_SOURCE[0]")/../.."
AUDIT_MODE="${$1-false}"
if [AUDIT_MODE != "true"]; then
cd "$base/src/acceptance_tests"
else cd "$base/src/acceptance_tests_audit_mode"
fi
gem install bundler:1.16.2
bundle
rspec spec
