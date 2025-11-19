#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
  echo -e "${BLUE}ℹ ${1}${NC}"
}

print_success() {
  echo -e "${GREEN}✓ ${1}${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_error() {
  echo -e "${RED}✗ ${1}${NC}"
}

# Usage message
usage() {
  cat <<EOF
Usage: $0 <version>

Updates the fluent-bit BOSH blob to the specified version.

Arguments:
  version    The fluent-bit version to update to (e.g., 4.2.0, 4.3.0)

Example:
  $0 4.3.0

What this script does:
  1. Downloads the specified fluent-bit version from GitHub
  2. Calculates SHA256 checksum
  3. Adds the blob to BOSH blobstore (GCS)
  4. Uploads the blob using service account credentials
  5. Updates config/blobs.yml
  6. Removes the old blob
  7. Optionally creates a test BOSH release

Requirements:
  - bosh CLI installed
  - curl for downloading
  - service_account.json in repo root (GCS credentials)
  - Write access to GCS bucket: tpi-telemetry-release-blobs

EOF
  exit 1
}

# Check for version argument
if [ $# -ne 1 ]; then
  print_error "Error: Version argument required"
  echo
  usage
fi

VERSION="$1"

# Validate version format (e.g., 4.2.0 or 4.2)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  print_error "Invalid version format: $VERSION"
  print_info "Expected format: X.Y.Z or X.Y (e.g., 4.2.0 or 4.2)"
  exit 1
fi

# Get repository root
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

print_info "Repository root: $REPO_ROOT"

# Check for required tools
if ! command -v bosh &>/dev/null; then
  print_error "bosh CLI is not installed"
  print_info "Install from: https://bosh.io/docs/cli-v2-install/"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  print_error "curl is not installed"
  exit 1
fi

# Check for service account credentials
SERVICE_ACCOUNT_JSON="$REPO_ROOT/service_account.json"
if [ ! -f "$SERVICE_ACCOUNT_JSON" ]; then
  print_error "service_account.json not found in repo root"
  print_info "This file is required for GCS blob upload"
  exit 1
fi

print_success "All prerequisites met"

# Set up GCS credentials for BOSH
export BOSH_GCS_CREDENTIALS_SOURCE="service_account_json_file"
export BOSH_GCS_SERVICE_ACCOUNT_JSON="$SERVICE_ACCOUNT_JSON"

print_info "GCS credentials configured"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

print_info "Created temporary directory: $TEMP_DIR"

# Download fluent-bit
FLUENT_BIT_TARBALL="fluent-bit-$VERSION.tar.gz"
DOWNLOAD_URL="https://github.com/fluent/fluent-bit/archive/v${VERSION}.tar.gz"

print_info "Downloading fluent-bit $VERSION..."
print_info "URL: $DOWNLOAD_URL"

if ! curl -L -o "$TEMP_DIR/$FLUENT_BIT_TARBALL" "$DOWNLOAD_URL"; then
  print_error "Failed to download fluent-bit $VERSION"
  print_info "Verify the version exists at: https://github.com/fluent/fluent-bit/releases"
  exit 1
fi

print_success "Downloaded fluent-bit $VERSION"

# Calculate checksum
CHECKSUM=$(shasum -a 256 "$TEMP_DIR/$FLUENT_BIT_TARBALL" | awk '{print $1}')
FILE_SIZE=$(stat -f%z "$TEMP_DIR/$FLUENT_BIT_TARBALL" 2>/dev/null || stat -c%s "$TEMP_DIR/$FLUENT_BIT_TARBALL")

print_info "SHA256: $CHECKSUM"
print_info "Size: $FILE_SIZE bytes"

# Find old fluent-bit blob
OLD_BLOB=$(grep "^fluent-bit/fluent-bit-" config/blobs.yml | head -1 | cut -d: -f1 || echo "")

if [ -n "$OLD_BLOB" ]; then
  print_info "Current blob: $OLD_BLOB"
else
  print_warning "No existing fluent-bit blob found in config/blobs.yml"
fi

# Add new blob
print_info "Adding new blob to blobstore..."
if ! bosh add-blob "$TEMP_DIR/$FLUENT_BIT_TARBALL" "fluent-bit/$FLUENT_BIT_TARBALL"; then
  print_error "Failed to add blob"
  exit 1
fi

print_success "Blob added to blobstore"

# Upload blobs
print_info "Uploading blob to GCS..."
if ! bosh upload-blobs; then
  print_error "Failed to upload blobs to GCS"
  exit 1
fi

print_success "Blob uploaded to GCS bucket: tpi-telemetry-release-blobs"

# Remove old blob if it exists
if [ -n "$OLD_BLOB" ]; then
  print_info "Removing old blob: $OLD_BLOB"

  echo
  print_warning "About to remove old blob: $OLD_BLOB"
  read -p "Continue? (y/n) " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if bosh remove-blob "$OLD_BLOB"; then
      print_success "Old blob removed"
    else
      print_warning "Failed to remove old blob (may need manual cleanup)"
    fi
  else
    print_info "Skipping old blob removal"
  fi
fi

# Show git status
echo
print_info "Git status:"
git status --short config/blobs.yml

# Summary
echo
echo "════════════════════════════════════════════════════════════"
print_success "fluent-bit blob update completed!"
echo "════════════════════════════════════════════════════════════"
echo
print_info "Summary:"
echo "  • Version: $VERSION"
echo "  • File: fluent-bit/$FLUENT_BIT_TARBALL"
echo "  • SHA256: $CHECKSUM"
echo "  • Size: $FILE_SIZE bytes"
echo

# Offer to create test release
read -p "Create a test BOSH release? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  print_info "Creating test release..."

  TEST_TARBALL="/tmp/telemetry-test-fluent-bit-$VERSION.tgz"

  if bosh create-release --force --tarball="$TEST_TARBALL"; then
    print_success "Test release created: $TEST_TARBALL"
  else
    print_error "Failed to create test release"
    print_info "You may need to run: bosh sync-blobs"
    exit 1
  fi
fi

echo
print_info "Next steps:"
echo "  1. Review changes: git diff config/blobs.yml"
echo "  2. Test the release in a deployment"
echo "  3. Commit if tests pass:"
echo "     git add config/blobs.yml"
echo "     git commit -m \"chore: Update fluent-bit to $VERSION\""
