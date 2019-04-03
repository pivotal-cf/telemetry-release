#!/usr/bin/env bash

set -euo pipefail

apt-get update
apt-get -y install ssh netcat-openbsd

BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

BBL_CLI=("$PWD"/bbl-cli-github-release/bbl-v*_linux_x86-64)
chmod 755 "$BBL_CLI"

cd bbl-state
eval "$("$BBL_CLI" print-env)"

echo Testing that logs matching telemetry-source are sent to centralizer
EXPECTED_LOG="this is a telemetry-source test at $(date +%s)"
INSERT_AGENT_LOG_CMD="echo \"$EXPECTED_LOG\" | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log"
ASSERT_CENTRALIZER_LOG_CMD="sudo grep \"$EXPECTED_LOG\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log"

"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-agent -c "$INSERT_AGENT_LOG_CMD"
sleep 5
"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-centralizer -c "$ASSERT_CENTRALIZER_LOG_CMD"


echo Testing that logs not matching telemetry-source are not sent to centralizer
EXPECTED_LOG="NOT a telemetry msg test at $(date +%s)"
INSERT_AGENT_LOG_CMD="echo \"$EXPECTED_LOG\" | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log"
ASSERT_CENTRALIZER_LOG_CMD="if sudo grep \"$EXPECTED_LOG\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log; then exit 1; fi"

"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-agent -c "$INSERT_AGENT_LOG_CMD"
sleep 5
"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-centralizer -c "$ASSERT_CENTRALIZER_LOG_CMD"
