#!/usr/bin/env bash

set -euxo pipefail

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
apt-get -y install git jq ssh netcat-openbsd

TASK_DIR="$PWD"
VERSION=$(cat version/version)

export BOSH_ENVIRONMENT=10.0.0.5

echo "Setting up BOSH CLI"
export BOSH_CLI=/usr/local/bin/bosh
cp "$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64 "$BOSH_CLI"
chmod 755 "$BOSH_CLI"

echo "Setting up OM CLI"
export om_cli="om/om-linux-amd64-$(cat om/version)"
chmod 755 "$om_cli"
cp "$om_cli" /usr/local/bin/om

echo "Setting up SMITH CLI"
SMITH_CLI=/usr/local/bin/smith
cp "$PWD"/smith/smith_linux_amd64 "$SMITH_CLI"
chmod 755 "$SMITH_CLI"

echo "Setting up BBL CLI"
BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

echo "Evaluating smith environment"
if [[ -n $TOOLSMITHS_ENV_LOCKFILE ]]; then
  mkdir -p testbed-lease
  echo "$TOOLSMITHS_ENV_LOCKFILE" > testbed-lease/metadata
fi

# Writing variables to temp file
echo "Write vars to temp file"
smith bosh -l testbed-lease/metadata > temp_env.sh

# Sourcing Temp File
echo "Source tempfile"
source temp_env.sh

eval $(smith bosh -l testbed-lease/metadata)
echo "BOSH_ENVIRONMENT: $BOSH_ENVIRONMENT"
eval $(smith om -l testbed-lease/metadata)

$PWD/ci/ci/tasks/run-acceptance-tests.sh
