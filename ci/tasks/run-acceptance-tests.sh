#!/usr/bin/env bash

base="$(dirname "$BASH_SOURCE[0]")/../.."
if [ "$AUDIT_MODE" != "true" ]; then
  cd "$base/src/acceptance_tests"
else
  cd "$base/src/acceptance_tests_audit_mode"
fi
gem install bundler:2.6.8
bundle
rspec spec
