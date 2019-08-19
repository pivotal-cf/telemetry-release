#!/usr/bin/env bash

base="$(dirname "$BASH_SOURCE[0]")/../.."

cd "$base/src/acceptance_tests"
bundle
rspec spec
