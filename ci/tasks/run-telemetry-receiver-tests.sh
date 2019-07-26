#!/usr/bin/env bash

set -euo pipefail

cd telemetry-components-release/src/acceptance_tests/telemetry_receiver

go version

go get github.com/onsi/ginkgo/ginkgo

ginkgo -failOnPending -race -randomizeAllSpecs -randomizeSuites -r .
