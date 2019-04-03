#!/usr/bin/env bash

set -euo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

apt-get update
apt-get -y install git
pushd telemetry-components-release
"$BOSH_CLI" create-release --force --timestamp-version --tarball "$TASK_DIR/release-tarball/release.tgz"
