#!/usr/bin/env bash

set -euo pipefail

task_dir="$PWD"
bosh_cli=("$task_dir"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$bosh_cli"

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

  old_blob=$("$bosh_cli" blobs | grep telemetry-collector | awk '{print $1}')
  new_blob_path="$task_dir"/pivotal-telemetry-collector/telemetry-collector-linux-amd64
  new_blob="pivotal-telemetry-collector/telemetry-collector-linux-$version"

  "$bosh_cli" remove-blob "$old_blob"
  "$bosh_cli" add-blob "$new_blob_path" "$new_blob"
  "$bosh_cli" upload-blobs

  git add .
  git config --global user.name $GITHUB_NAME
  git config --global user.email $GITHUB_EMAIL
  git commit -m "Update pivotal-telemetry-collector blob to version $version"
popd
