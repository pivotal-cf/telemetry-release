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

assert_centralizer_log() {
  INSERT_AGENT_LOG_CMD="echo \"$1\" | sudo tee -a /var/vcap/sys/log/telemetry-agent/telemetry-agent.stdout.log"
  "$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-agent -c "$INSERT_AGENT_LOG_CMD"
  sleep 5
  "$BOSH_CLI" -d telemetry-components-acceptance ssh telemetry-centralizer -c "$2"
}

echo Testing that logs matching telemetry-source embedded as a string value in a JSON object are extracted and sent to centralizer
INPUT_LOG='{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"app\": \"da\\\"ta\", \"counter\": 42}, \"telemetry-source\": \"my-origin\"}'
EXPECTED_LOG='{"data":{"app":"da\"ta","counter":42},"telemetry-source":"my-origin"}'
ASSERT_CENTRALIZER_LOG_CMD="sudo grep \"$EXPECTED_LOG\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log"
assert_centralizer_log "$INPUT_LOG" "$ASSERT_CENTRALIZER_LOG_CMD"

echo Testing that logs not matching the expected structure are filtered out by the centralizer
INPUT_LOG="NOT a telemetry-source msg test at $(date +%s)"
ASSERT_CENTRALIZER_LOG_CMD="if sudo grep \"$INPUT_LOG\" /var/vcap/sys/log/telemetry-centralizer/telemetry-centralizer.stdout.log; then exit 1; fi"
assert_centralizer_log "$INPUT_LOG" "$ASSERT_CENTRALIZER_LOG_CMD"
