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
om_cli="om/om-linux-amd64-$(cat om/version)"
chmod 755 "$om_cli"
cp "$om_cli" /usr/local/bin/om

echo "Setting up SMITH CLI"
SMITH_CLI=/usr/local/bin/smith
cp "$PWD"/smith/smith_linux_amd64 "$SMITH_CLI"
chmod 755 "$SMITH_CLI"

echo "Setting up BBL CLI"
BBL_CLI=/usr/local/bin/bbl
cp "$PWD"/bbl-cli-github-release/bbl-*_linux_amd64 "$BBL_CLI"
chmod 755 "$BBL_CLI"

echo "Evaluating smith environment"
if [[ -n $TOOLSMITHS_ENV_LOCKFILE ]]; then
  mkdir -p testbed-lease
  echo "$TOOLSMITHS_ENV_LOCKFILE" > testbed-lease/metadata
fi

eval $(smith bosh -l testbed-lease/metadata)
echo "BOSH_ENVIRONMENT: $BOSH_ENVIRONMENT"
eval $(smith om -l testbed-lease/metadata)

export NETWORK=$(smith read --lockfile=testbed-lease/metadata | jq -r .ert_subnet)
export AZ=$(smith read --lockfile=testbed-lease/metadata | jq -r .azs[0])

echo "Uploading stemcell..."

retry 5 bosh upload-stemcell "$TASK_DIR/stemcell/stemcell.tgz"

echo "Uploading releases..."
retry 5 bosh upload-release -n "$TASK_DIR/release-tarball/release.tgz"
retry 5 bosh upload-release -n "$TASK_DIR/bpm-release/release.tgz"

echo "Deploying telemetry centralizer"
retry 5 bosh deploy -n -d "$CENTRALIZER_DEPLOYMENT_NAME" "$TASK_DIR/telemetry-release/manifest/centralizer.yml" \
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
    --var az="$AZ" \
    --var data_collection_multi_select_options="$DATA_COLLECTION_MULTI_SELECT_OPTIONS" \
    --var operational_data_only="$OPERATIONAL_DATA_ONLY"

echo "Deploying telemetry agent"
retry 5 bosh deploy -n -d "$AGENT_DEPLOYMENT_NAME" "$TASK_DIR/telemetry-release/manifest/agent.yml" \
    --var agent_deployment_name="$AGENT_DEPLOYMENT_NAME" \
    --var centralizer_deployment_name="$CENTRALIZER_DEPLOYMENT_NAME" \
    --var network_name="$NETWORK" \
    --var az="$AZ"

