#!/usr/bin/env bash

set -euo pipefail

TASK_DIR="$PWD"
BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

BBL_CLI=("$PWD"/bbl-cli-github-release/bbl-v*_linux_x86-64)
chmod 755 "$BBL_CLI"

eval "$("$BBL_CLI" print-env)"

echo Testing that logs matching telemetry-source are sent to centralizer
EXPECTED_LOG="this is a telemetry-source test at $(date +%s)"
INSERT_AGENT_LOG_CMD="echo \"$EXPECTED_LOG\" | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log"
ASSERT_CENTRALIZER_LOG_CMD="sudo grep \"$EXPECTED_LOG\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log"

"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-agent -c "$INSERT_AGENT_LOG_CMD"
sleep 5
"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-centralizer -c "$ASSERT_CENTRALIZER_LOG_CMD"


echo Testing that logs not matching telemetry-source are not sent to centralizer
EXPECTED_LOG="this is a non telemetry message test at $(date +%s)"
INSERT_AGENT_LOG_CMD="echo \"$EXPECTED_LOG\" | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log"
ASSERT_CENTRALIZER_LOG_CMD="sudo grep \"this is a non telemetry message\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log | grep -v \"$EXPECTED_LOG\""

"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-agent -c "$INSERT_AGENT_LOG_CMD"
sleep 5
"$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-centralizer -c "$ASSERT_CENTRALIZER_LOG_CMD"
