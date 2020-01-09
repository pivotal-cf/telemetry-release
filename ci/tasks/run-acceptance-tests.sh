#!/usr/bin/env bash

base="$(dirname "$BASH_SOURCE[0]")/../.."

cd "$base/src/acceptance_tests"
gem install bundler:1.16.2
bundle
rspec spec
