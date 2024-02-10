#!/usr/bin/env bash

set -euxo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$TASK_DIR"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

export BOSH_ENVIRONMENT=10.0.0.5

BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

VERSION=$(cat version/version)

apt-get update
apt-get -y install git
pushd telemetry-release

  cat > config/private.yml <<EOM
---
blobstore:
  options:
    credentials_source: static
    json_key: |
      $(echo $GCS_SERVICE_ACCOUNT_KEY)
EOM

  "$BOSH_CLI" create-release --final --version "${VERSION}"

  git add .
  git config --global user.name $GITHUB_NAME
  git config --global user.email $GITHUB_EMAIL
  git commit -m "Create final release $VERSION"
