#!/usr/bin/env bash

set -euxo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

export BOSH_ENVIRONMENT=10.0.0.5

BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

VERSION=$(cat version/version)

apt-get update
apt-get -y install git
pushd telemetry-release
"$BOSH_CLI" create-release --force --version "$VERSION" --tarball "$TASK_DIR/release-tarball/release.tgz"
