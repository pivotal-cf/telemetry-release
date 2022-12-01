#!/usr/bin/env bash

# This script can be used to update our bundled
# ruby 3.1 release. For now, it only turns the
# the pipeline red if there is a new release.

set -euo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$TASK_DIR"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"



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

  "$BOSH_CLI" vendor-package ruby-3.1 "$TASK_DIR/ruby-release"

  if [ -z "$(git status --porcelain)" ]; then
    echo "No new version of ruby-release"
    exit 0
  fi

  git add .

  package_version=$(cat "$TASK_DIR/ruby-release/packages/ruby-3.1/version")
  git config --global user.name ${GITHUB_NAME}
  git config --global user.email ${GITHUB_EMAIL}
  git commit -m "Update ruby-3.1 package to ${package_version} from ruby-release"

  echo "Updated ruby-3.1 package to ${package_version} from ruby-release"
  exit 0
popd
