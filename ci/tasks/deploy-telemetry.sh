#!/usr/bin/env bash

set -euo pipefail

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
apt-get -y install git jq

TASK_DIR="$PWD"
VERSION=$(cat version/version)

echo "Setting up BOSH CLI"
BOSH_CLI=/usr/local/bin/bosh
cp "$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64 "$BOSH_CLI"
chmod 755 "$BOSH_CLI"

echo "Setting up OM CLI"
om_cli="om/om-linux-$(cat om/version)"
chmod 755 "$om_cli"
cp "$om_cli" /usr/local/bin/om

echo "Evaluating smith environment"
tar -C /usr/local/bin -xf smith/*.tar.gz
export env=${TOOLSMITHS_ENV:-$(cat env-pool/name)}
export NETWORK="$(smith read | jq -r .ert_subnet)"
export AZ="$(smith read | jq -r .azs[0])"
eval "$(smith bosh)"

echo "Uploading stemcell..."

retry 5 "$BOSH_CLI" upload-stemcell "$TASK_DIR/jammy-stemcell/stemcell.tgz"

echo "Uploading releases..."
retry 5 "$BOSH_CLI" upload-release -n "$TASK_DIR/release-tarball/release.tgz"
retry 5 "$BOSH_CLI" upload-release -n "$TASK_DIR/bpm-release/release.tgz"

echo "Deploying telemetry centralizer"
retry 5 "$BOSH_CLI" deploy -n -d "$CENTRALIZER_DEPLOYMENT_NAME" "$TASK_DIR/telemetry-release/manifest/centralizer.yml" \
    --var centralizer_deployment_name="$CENTRALIZER_DEPLOYMENT_NAME" \
    --var audit_mode="$AUDIT_MODE" \
    --var loader_api_key="$LOADER_API_KEY" \
    --var loader_endpoint="$LOADER_ENDPOINT" \
    --var env_type="$ENV_TYPE" \
    --var iaas_type="$IAAS_TYPE" \
    --var foundation_id="$FOUNDATION_ID" \
    --var foundation_nickname="$FOUNDATION_NICKNAME" \
    --var flush_interval="$FLUSH_INTERVAL" \
    --var collector_cron_schedule="'$COLLECTOR_CRON_SCHEDULE'" \
    --var opsmanager_hostname="$OPSMANAGER_HOSTNAME" \
    --var opsmanager_client_name="$OPSMANAGER_CLIENT_NAME" \
    --var opsmanager_client_secret="$OPSMANAGER_CLIENT_SECRET" \
    --var opsmanager_insecure_skip_tls_verify="$OPSMANAGER_INSECURE_SKIP_TLS_VERIFY" \
    --var cf_api_url="$CF_API_URL" \
    --var usage_service_url="$USAGE_SERVICE_URL" \
    --var usage_service_client_id="$USAGE_SERVICE_CLIENT_ID" \
    --var usage_service_client_secret="$USAGE_SERVICE_CLIENT_SECRET" \
    --var usage_service_insecure_skip_tls_verify="$USAGE_SERVICE_INSECURE_SKIP_TLS_VERIFY" \
    --var network_name="$NETWORK" \
    --var az="$AZ"

echo "Deploying telemetry agent"
retry 5 "$BOSH_CLI" deploy -n -d "$AGENT_DEPLOYMENT_NAME" "$TASK_DIR/telemetry-release/manifest/agent.yml" \
    --var agent_deployment_name="$AGENT_DEPLOYMENT_NAME" \
    --var centralizer_deployment_name="$CENTRALIZER_DEPLOYMENT_NAME" \
    --var network_name="$NETWORK" \
    --var az="$AZ"

