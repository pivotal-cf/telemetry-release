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


TASK_DIR="$PWD"
BOSH_CLI=("$PWD"/bosh-cli-github-release/bosh-cli-*-linux-amd64)
chmod 755 "$BOSH_CLI"

VERSION=$(cat version/version)

apt-get update
apt-get -y install git

echo "Uploading stemcell..."

retry 5 "$BOSH_CLI" upload-stemcell "$TASK_DIR/xenial-stemcell/*.tgz"

echo "Uploading releases..."
retry 5 "$BOSH_CLI" upload-release --force "$TASK_DIR/release-tarball/*.tgz"
retry 5 "$BOSH_CLI" upload-release --force "$TASK_DIR/bpm-release/*.tgz"

echo "Deploying telemetry centralizer"
retry 5 "$BOSH_CLI" deploy -d "$DEPLOYMENT_NAME" "$TASK_DIR/telemetry-release/manifest/centralizer.yml" \
    --var deployment_name="$DEPLOYMENT_NAME"
    --var audit_mode="$AUDIT_MODE"
    --var loader_api_key="$LOADER_API_KEY"
    --var loader_endpoint="$LOADER_ENDPOINT"
    --var env_type="$ENV_TYPE"
    --var iaas_type="$IAAS_TYPE"
    --var foundation_id="$FOUNDATION_ID"
    --var foundation_nickname="$FOUNDATION_NICKNAME"
    --var flush_interval="$FLUSH_INTERVAL"
    --var collector_cron_schedule="$COLLECTOR_CRON_SCHEDULE"
    --var opsmanager_hostname="$OPSMANAGER_HOSTNAME"
    --var opsmanager_client_name="$OPSMANAGER_CLIENT_NAME"
    --var opsmanager_client_secret="$OPSMANAGER_CLIENT_SECRET"
    --var opsmanager_insecure_skip_tls_verify="$OPSMANAGER_INSECURE_SKIP_TLS_VERIFY"
    --var cf_api_url="$CF_API_URL"
    --var usage_service_url="$USAGE_SERVICE_URL"
    --var usage_service_client_id="$USAGE_SERVICE_CLIENT_ID"
    --var usage_service_client_secret="$USAGE_SERVICE_CLIENT_SECRET"
    --var usage_service_insecure_skip_tls_verify="$USAGE_SERVICE_INSECURE_SKIP_TLS_VERIFY"