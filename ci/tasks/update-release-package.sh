#!/usr/bin/env bash

set -euxo pipefail

export BOSH_ENVIRONMENT=10.0.0.5

task_dir="$PWD"
bosh_cli=("$task_dir"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$bosh_cli"

BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

apt-get update
apt-get -y install git

version=$(git -C "$PWD"/telemetry-cli-source-code tag --sort=-v:refname | head -n 1)

pushd telemetry-release
cat >config/private.yml <<EOM
---
blobstore:
  options:
    credentials_source: static
    json_key: |
      $(echo $GCS_SERVICE_ACCOUNT_KEY)
EOM

# Check if new version already exists
set +e
"$bosh_cli" blobs | grep -E "telemetry-(cli|collector)-linux-${version}"
exit_code=$?
set -e

if [[ "${exit_code}" == "0" ]]; then
	echo "Version has not changed"
	exit 0
fi

old_blob=$("$bosh_cli" blobs | grep -E "telemetry-cli|telemetry-collector" | awk '{print $1}' | sed 's/:$//')
new_blob_path="${task_dir}/binary/telemetry-cli-linux-amd64"
new_blob="telemetry-cli/telemetry-cli-linux-${version}"

"$bosh_cli" remove-blob "${old_blob}"
"$bosh_cli" add-blob "${new_blob_path}" "${new_blob}"
"$bosh_cli" upload-blobs

git add .
git config --global user.name "${GITHUB_NAME}"
git config --global user.email "${GITHUB_EMAIL}"
git commit -m "Update telemetry-cli blob to version ${version}"
popd
