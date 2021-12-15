#!/usr/bin/env bash

set -euo pipefail

# Since moving to the VMware network there have been frequent network failures
# when connecting to pooled environments on GCP.
function retry {
  local retries=$1
  local count=0
  shift

  until "$@"; do
    exit=$?
    count=$(($count + 1))
    if [ $count -lt $retries ]; then
      echo "Attempt $count/$retries ended with exit $exit"
      # Need a short pause between smith CLI executions or it fails unexpectedly.
      sleep 30
    else
      echo "Attempted $count/$retries times and failed."
      return $exit
    fi
  done
  return 0
}
apt-get update
apt-get -y install -f git jq ssh netcat-openbsd

TASK_DIR="$PWD"
VERSION=$(cat version/version)

echo "Setting up BOSH CLI"
export BOSH_CLI=/usr/local/bin/bosh
cp "$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64 "$BOSH_CLI"
chmod 755 "$BOSH_CLI"

echo "Setting up OM CLI"
export om_cli="om/om-linux-$(cat om/version)"
chmod 755 "$om_cli"
cp "$om_cli" /usr/local/bin/om

echo "Evaluating smith environment"
tar -C /usr/local/bin -xf smith/*.tar.gz
export env=${TOOLSMITHS_ENV:-$(cat env-pool/name)}
eval "$(smith bosh)"

$PWD/ci/ci/tasks/run-acceptance-tests.sh