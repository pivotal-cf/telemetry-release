#!/usr/bin/env bash

set -euxo pipefail

cd telemetry-release/src/acceptance_tests/telemetry_receiver

go version

go install github.com/onsi/ginkgo/ginkgo@latest

ginkgo -failOnPending -race -randomizeAllSpecs -randomizeSuites -r .
