#!/usr/bin/env bash

set -euo pipefail

apt-get update
apt-get -y install ssh netcat-openbsd

BBL_CLI=$(find "$PWD"/bbl-cli-github-release -name bbl-v*_linux_x86-64)
chmod 755 "$BBL_CLI"

pushd bbl-state
eval "$("$BBL_CLI" print-env)"
popd

export BOSH_CLI=$(find "$PWD"/bosh-cli-github-release -name bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

curl -L -o cf-cli.tgz "https://packages.cloudfoundry.org/stable?release=linux64-binary&source=github"
tar xzvf cf-cli.tgz
mv cf /usr/local/bin/

export CF_CLI=/usr/local/bin/cf

cf login -a $CF_API -o $CF_ORG -s $CF_SPACE -u $CF_USERNAME -p $CF_PASSWORD

cd telemetry-components-release/src/acceptance_tests
bundle
rspec spec
