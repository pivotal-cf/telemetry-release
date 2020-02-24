#!/usr/bin/env bash

set -euo pipefail

base="$(dirname "$BASH_SOURCE[0]")/../.."

apt-get update
apt-get -y install ssh netcat-openbsd

BBL_CLI=$(find "$PWD"/bbl-cli-github-release -name bbl-v*_linux_x86-64)
chmod 755 "$BBL_CLI"

pushd bbl-state
eval "$("$BBL_CLI" print-env)"
popd

export BOSH_CLI=$(find "$PWD"/bosh-cli-github-release -name bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

$base/ci/tasks/run-acceptance-tests.sh $AUDIT_MODE
