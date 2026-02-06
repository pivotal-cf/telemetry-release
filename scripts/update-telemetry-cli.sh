#!/usr/bin/env bash
#
# This script:
#   1. Determines the latest telemetry-cli version from the GitHub Enterprise release
#   2. Compares against the current blob version in config/blobs.yml
#   3. If a newer version exists:
#      a) Downloads the Linux amd64 binary from the GitHub Release
#      b) Removes the old blob via `bosh remove-blob`
#      c) Adds the new blob via `bosh add-blob`
#      d) Uploads to GCS via `bosh upload-blobs`
#   4. If already up to date, exits cleanly with a message
#
# Usage:
#   ./scripts/update-telemetry-cli.sh
#
# Environment variables (optional, for CI):
#   GCS_SERVICE_ACCOUNT_KEY  - JSON string of GCP service account (CI only)
#   GH_TOKEN                 - GitHub token for API access (CI only; locally uses gh auth)
#   GH_HOST                  - GitHub host (defaults to github.gwd.broadcom.net)
#   SKIP_UPLOAD              - Set to "true" to skip bosh upload-blobs (for dry-run)
#
# Prerequisites:
#   - bosh CLI installed
#   - gh CLI installed and authenticated to github.gwd.broadcom.net
#   - service_account.json in repo root (local) OR GCS_SERVICE_ACCOUNT_KEY env var (CI)
#   - curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ============================================================================
# Configuration
# ============================================================================
GH_HOST="${GH_HOST:-github.gwd.broadcom.net}"
CLI_REPO="TNZ/tpi-telemetry-cli"
BLOB_PREFIX="telemetry-cli"

# ============================================================================
# Colors and helpers
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
print_step()    { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

if ! command -v bosh &> /dev/null; then
    print_error "bosh CLI is not installed."
    print_info "Install from: https://bosh.io/docs/cli-v2-install/"
    exit 1
fi
print_info "bosh CLI: $(bosh --version 2>&1 | head -1)"

if ! command -v gh &> /dev/null; then
    print_error "gh CLI is not installed."
    print_info "Install from: https://cli.github.com/"
    exit 1
fi
print_info "gh CLI: $(gh --version | head -1)"

# Verify gh is authenticated to our GitHub Enterprise instance
if ! GH_HOST="${GH_HOST}" gh auth status --hostname "${GH_HOST}" &> /dev/null; then
    print_error "gh CLI is not authenticated to ${GH_HOST}"
    print_info "Run: gh auth login --hostname ${GH_HOST}"
    exit 1
fi
print_success "gh CLI authenticated to ${GH_HOST}"

# ============================================================================
# Set up GCS credentials for bosh upload-blobs
# ============================================================================
print_step "Configuring GCS credentials"

if [[ -n "${GCS_SERVICE_ACCOUNT_KEY:-}" ]]; then
    # CI mode: create config/private.yml from env var
    print_info "Using GCS_SERVICE_ACCOUNT_KEY from environment (CI mode)"
    cat > config/private.yml <<EOM
---
blobstore:
  options:
    credentials_source: static
    json_key: |
      ${GCS_SERVICE_ACCOUNT_KEY}
EOM
elif [[ -f "${REPO_ROOT}/service_account.json" ]]; then
    # Local mode: create config/private.yml from service_account.json
    print_info "Using service_account.json (local mode)"
    SERVICE_ACCOUNT_CONTENT=$(cat "${REPO_ROOT}/service_account.json")
    cat > config/private.yml <<EOM
---
blobstore:
  options:
    credentials_source: static
    json_key: |
$(echo "${SERVICE_ACCOUNT_CONTENT}" | sed 's/^/      /')
EOM
else
    print_error "No GCS credentials found."
    print_info "Either set GCS_SERVICE_ACCOUNT_KEY or place service_account.json in repo root."
    exit 1
fi
print_success "GCS credentials configured (config/private.yml)"

# ============================================================================
# Determine current blob version from config/blobs.yml
# ============================================================================
print_step "Checking current telemetry-cli blob version"

CURRENT_BLOB_LINE=$(grep "^${BLOB_PREFIX}/" config/blobs.yml || echo "")
if [[ -z "${CURRENT_BLOB_LINE}" ]]; then
    print_warning "No existing telemetry-cli blob found in config/blobs.yml"
    CURRENT_VERSION="0.0.0"
    CURRENT_BLOB_PATH=""
else
    # Extract the full blob path (e.g., "telemetry-cli/telemetry-cli-linux-2.4.0:")
    CURRENT_BLOB_PATH=$(echo "${CURRENT_BLOB_LINE}" | sed 's/:$//')
    # Extract version from the blob path
    CURRENT_VERSION=$(echo "${CURRENT_BLOB_PATH}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    print_info "Current blob: ${CURRENT_BLOB_PATH}"
    print_info "Current version: ${CURRENT_VERSION}"
fi

# ============================================================================
# Determine latest version from GitHub Release
# ============================================================================
print_step "Checking latest telemetry-cli release"

LATEST_TAG=$(GH_HOST="${GH_HOST}" gh release list \
    --repo "${CLI_REPO}" \
    --limit 1 \
    --json tagName \
    --jq '.[0].tagName' 2>/dev/null || echo "")

if [[ -z "${LATEST_TAG}" ]]; then
    print_error "Could not determine latest release from ${GH_HOST}/${CLI_REPO}"
    print_info "Check your gh auth status and that releases exist."
    exit 1
fi

# The tag may or may not have a 'v' prefix; strip it for comparison
LATEST_VERSION="${LATEST_TAG#v}"

print_info "Latest release tag: ${LATEST_TAG}"
print_info "Latest version: ${LATEST_VERSION}"

# ============================================================================
# Compare versions
# ============================================================================
print_step "Comparing versions"

version_to_comparable() {
    # Convert "2.4.1" to "002004001" for simple string comparison
    echo "$1" | awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}'
}

CURRENT_COMPARABLE=$(version_to_comparable "${CURRENT_VERSION}")
LATEST_COMPARABLE=$(version_to_comparable "${LATEST_VERSION}")

if [[ "${CURRENT_COMPARABLE}" == "${LATEST_COMPARABLE}" ]]; then
    print_success "Already up to date (version ${CURRENT_VERSION}). Nothing to do."
    echo ""
    echo "NO_UPDATE=true"
    exit 0
fi

if [[ "${CURRENT_COMPARABLE}" > "${LATEST_COMPARABLE}" ]]; then
    print_warning "Current version (${CURRENT_VERSION}) is NEWER than latest release (${LATEST_VERSION})."
    print_warning "This is unexpected. Skipping update."
    echo ""
    echo "NO_UPDATE=true"
    exit 0
fi

print_info "Update available: ${CURRENT_VERSION} -> ${LATEST_VERSION}"

# ============================================================================
# Download the Linux amd64 binary from the GitHub Release
# ============================================================================
print_step "Downloading telemetry-cli ${LATEST_VERSION}"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

BINARY_PATH="${TEMP_DIR}/telemetry-cli-linux-amd64"

# The release should have a linux binary asset. Try to download it.
print_info "Downloading linux-amd64 binary from GitHub Release ${LATEST_TAG}..."

if ! GH_HOST="${GH_HOST}" gh release download "${LATEST_TAG}" \
    --repo "${CLI_REPO}" \
    --pattern "telemetry-cli-linux-amd64" \
    --output "${BINARY_PATH}" 2>/dev/null; then
    
    # Fallback: try the .tgz release tarball and extract the linux binary
    print_warning "Direct binary download failed. Trying release tarball..."
    
    TARBALL_NAME="telemetry-cli-${LATEST_VERSION}.tgz"
    TARBALL_PATH="${TEMP_DIR}/${TARBALL_NAME}"
    
    if ! GH_HOST="${GH_HOST}" gh release download "${LATEST_TAG}" \
        --repo "${CLI_REPO}" \
        --pattern "${TARBALL_NAME}" \
        --output "${TARBALL_PATH}" 2>/dev/null; then
        
        print_error "Could not download telemetry-cli binary from release ${LATEST_TAG}"
        print_info "Available assets:"
        GH_HOST="${GH_HOST}" gh release view "${LATEST_TAG}" --repo "${CLI_REPO}" --json assets --jq '.assets[].name' || true
        exit 1
    fi

    # Extract the linux binary from the tarball
    print_info "Extracting linux binary from tarball..."
    tar xzf "${TARBALL_PATH}" -C "${TEMP_DIR}" --include='*telemetry-cli-linux-amd64' 2>/dev/null \
        || tar xzf "${TARBALL_PATH}" -C "${TEMP_DIR}" 2>/dev/null

    # Find the binary (it might be in a subdirectory)
    EXTRACTED_BINARY=$(find "${TEMP_DIR}" -name "telemetry-cli-linux-amd64" -type f | head -1)
    if [[ -z "${EXTRACTED_BINARY}" ]]; then
        # Also try looking for just the linux binary with any naming convention
        EXTRACTED_BINARY=$(find "${TEMP_DIR}" -name "*linux*amd64*" -type f ! -name "*.tgz" | head -1)
    fi

    if [[ -z "${EXTRACTED_BINARY}" ]]; then
        print_error "Could not find linux-amd64 binary in release tarball."
        print_info "Tarball contents:"
        tar tzf "${TARBALL_PATH}" | head -20
        exit 1
    fi

    # Move it to the expected location
    mv "${EXTRACTED_BINARY}" "${BINARY_PATH}"
fi

chmod +x "${BINARY_PATH}"
BINARY_SIZE=$(stat -f%z "${BINARY_PATH}" 2>/dev/null || stat -c%s "${BINARY_PATH}")
print_success "Downloaded binary (${BINARY_SIZE} bytes)"

# ============================================================================
# Update BOSH blob
# ============================================================================
print_step "Updating BOSH blob"

NEW_BLOB_PATH="${BLOB_PREFIX}/${BLOB_PREFIX}-linux-${LATEST_VERSION}"

# Remove old blob if it exists
if [[ -n "${CURRENT_BLOB_PATH}" ]]; then
    print_info "Removing old blob: ${CURRENT_BLOB_PATH}"
    bosh remove-blob "${CURRENT_BLOB_PATH}"
fi

# Add new blob
print_info "Adding new blob: ${NEW_BLOB_PATH}"
bosh add-blob "${BINARY_PATH}" "${NEW_BLOB_PATH}"

# Upload blobs to GCS
if [[ "${SKIP_UPLOAD:-false}" == "true" ]]; then
    print_warning "SKIP_UPLOAD=true -- skipping bosh upload-blobs"
else
    print_info "Uploading blobs to GCS..."
    bosh upload-blobs
    print_success "Blobs uploaded to GCS"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo -e "${GREEN}TELEMETRY-CLI BLOB UPDATED${NC}"
echo "=========================================="
echo ""
echo "  ${CURRENT_VERSION} -> ${LATEST_VERSION}"
echo "  Blob: ${NEW_BLOB_PATH}"
echo ""
echo "  Review changes:"
echo "    git diff config/blobs.yml"
echo ""
echo "  If everything looks good, commit:"
echo "    git add -A"
echo "    git commit -m \"chore: update telemetry-cli blob to ${LATEST_VERSION}\""
echo ""
