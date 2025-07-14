#!/usr/bin/env bash

set -euxo pipefail

cd telemetry-release/src/acceptance_tests/telemetry_receiver

go version

go install github.com/onsi/ginkgo/ginkgo@latest

ginkgo --fail-on-pending -race --randomize-all --randomize-suites -r .
