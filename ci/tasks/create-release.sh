#!/usr/bin/env bash

set -euo pipefail

TASK_DIR="$PWD"
BOSH_CLI="$PWD/bosh-cli-github-release/bosh-cli-*-linux-amd64"

cd telemetry-components-release
"$BOSH_CLI" create-release --force --tarball "$TASK_DIR/release-tarball/release.tgz"
