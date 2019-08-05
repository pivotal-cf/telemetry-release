#!/usr/bin/env bash

set -euo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

VERSION=$(cat version/version)

apt-get update
apt-get -y install git
pushd telemetry-release
"$BOSH_CLI" create-release --force --version "$VERSION" --tarball "$TASK_DIR/release-tarball/release.tgz"
