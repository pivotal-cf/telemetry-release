#!/usr/bin/env bash

set -euo pipefail

export BOSH_ENVIRONMENT=10.0.0.5

task_dir="$PWD"
bosh_cli=("$task_dir"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$bosh_cli"

BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

version=$(cat pivotal-telemetry-collector/version | cut -d '#' -f 1)

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

  # Check if new version already exists
  set +e
  "$bosh_cli" blobs | grep telemetry-collector-linux-"$version"
  if [[ $? == "0" ]]; then
    echo "Version has not changed"
    exit 0
  fi
  set -e

  old_blob=$("$bosh_cli" blobs | grep telemetry-collector | awk '{print $1}')
  new_blob_path="$task_dir"/pivotal-telemetry-collector/telemetry-collector-linux-amd64
  new_blob="telemetry-collector/telemetry-collector-linux-$version"

  "$bosh_cli" remove-blob "$old_blob"
  "$bosh_cli" add-blob "$new_blob_path" "$new_blob"
  "$bosh_cli" upload-blobs

  git add .
  git config --global user.name $GITHUB_NAME
  git config --global user.email $GITHUB_EMAIL
  git commit -m "Update telemetry-collector blob to version $version"
popd
