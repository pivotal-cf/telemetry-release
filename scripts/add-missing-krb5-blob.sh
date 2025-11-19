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
⚠️  ONE-TIME USE ONLY ⚠️

This script adds the missing krb5 blob that was not uploaded during
SPNEGO development.

Usage: $0

What this script does:
  1. Checks if krb5 blob is already in config/blobs.yml
  2. If missing, downloads the version referenced in blobs/krb5/
  3. Adds it to BOSH blobstore
  4. Uploads to GCS
  5. Updates config/blobs.yml

Note: After the krb5 blob is added once, use update-krb5.sh for version updates.

Requirements:
  - bosh CLI installed
  - curl for downloading
  - service_account.json in repo root (GCS credentials)
  - Write access to GCS bucket: tpi-telemetry-release-blobs

EOF
  exit 1
}

# Check for help flag
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi

# Get repository root
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

print_info "Repository root: $REPO_ROOT"

# Check if krb5 blob already exists in config/blobs.yml
if grep -q "^krb5/krb5-" config/blobs.yml 2>/dev/null; then
  print_success "krb5 blob already exists in config/blobs.yml"

  echo
  print_info "Current krb5 blob:"
  grep "^krb5/krb5-" config/blobs.yml | head -1

  echo
  print_info "This script is only needed when the krb5 blob is missing."
  print_info "To update to a different version, use: ./scripts/update-krb5.sh <version>"
  exit 0
fi

print_warning "No krb5 blob found in config/blobs.yml"

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

# Check if there's a local krb5 blob we can reference
KRB5_LOCAL_BLOB=""
if [ -d "blobs/krb5" ]; then
  KRB5_LOCAL_BLOB=$(find blobs/krb5 -name 'krb5-*.tar.gz' -type f 2>/dev/null | head -1 || echo "")
fi

# Determine which version to add
if [ -n "$KRB5_LOCAL_BLOB" ]; then
  # Extract version from local blob filename
  BLOB_FILENAME=$(basename "$KRB5_LOCAL_BLOB")
  VERSION="${BLOB_FILENAME#krb5-}"
  VERSION="${VERSION%.tar.gz}"

  print_info "Found local krb5 blob: $BLOB_FILENAME"
  print_info "Version: $VERSION"

  echo
  read -p "Add this local blob to the blobstore? (y/n) " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Operation cancelled"
    exit 0
  fi

  USE_LOCAL_BLOB=true
else
  # No local blob, ask user which version to download
  print_warning "No local krb5 blob found in blobs/krb5/"
  echo
  print_info "Please specify which krb5 version to download and add:"
  read -r -p "Version (e.g., 1.21.3, 1.22.1): " VERSION

  if [ -z "$VERSION" ]; then
    print_error "No version specified"
    exit 1
  fi

  # Validate version format
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    print_error "Invalid version format: $VERSION"
    print_info "Expected format: X.Y.Z or X.Y (e.g., 1.21.3 or 1.21)"
    exit 1
  fi

  USE_LOCAL_BLOB=false
fi

# Set up GCS credentials for BOSH
export BOSH_GCS_CREDENTIALS_SOURCE="service_account_json_file"
export BOSH_GCS_SERVICE_ACCOUNT_JSON="$SERVICE_ACCOUNT_JSON"

print_info "GCS credentials configured"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

print_info "Created temporary directory: $TEMP_DIR"

KRB5_TARBALL="krb5-$VERSION.tar.gz"
TARBALL_PATH=""

if [ "$USE_LOCAL_BLOB" = true ]; then
  # Use existing local blob
  TARBALL_PATH="$KRB5_LOCAL_BLOB"
  print_info "Using local blob: $TARBALL_PATH"
else
  # Download from kerberos.org
  MAJOR_MINOR=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')

  DOWNLOAD_URLS=(
    "https://kerberos.org/dist/krb5/${MAJOR_MINOR}/krb5-${VERSION}.tar.gz"
    "https://web.mit.edu/kerberos/dist/krb5/${MAJOR_MINOR}/krb5-${VERSION}.tar.gz"
  )

  print_info "Downloading krb5 $VERSION..."

  DOWNLOAD_SUCCESS=false
  for url in "${DOWNLOAD_URLS[@]}"; do
    print_info "Trying: $url"

    if curl -f -L -o "$TEMP_DIR/$KRB5_TARBALL" "$url"; then
      DOWNLOAD_SUCCESS=true
      print_success "Downloaded from: $url"
      break
    else
      print_warning "Failed to download from: $url"
    fi
  done

  if [ "$DOWNLOAD_SUCCESS" = false ]; then
    print_error "Failed to download krb5 $VERSION from any mirror"
    print_info "Verify the version exists at: https://kerberos.org/dist/krb5/${MAJOR_MINOR}/"
    exit 1
  fi

  TARBALL_PATH="$TEMP_DIR/$KRB5_TARBALL"

  # Verify tarball integrity
  print_info "Verifying tarball integrity..."
  if tar -tzf "$TARBALL_PATH" >/dev/null 2>&1; then
    print_success "Tarball integrity verified"
  else
    print_error "Tarball appears to be corrupted"
    exit 1
  fi
fi

# Calculate checksum
CHECKSUM=$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')
FILE_SIZE=$(stat -f%z "$TARBALL_PATH" 2>/dev/null || stat -c%s "$TARBALL_PATH")

print_info "SHA256: $CHECKSUM"
print_info "Size: $FILE_SIZE bytes"

# Add blob
print_info "Adding blob to blobstore..."
if ! bosh add-blob "$TARBALL_PATH" "krb5/$KRB5_TARBALL"; then
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

# Show git status
echo
print_info "Git status:"
git status --short config/blobs.yml

# Summary
echo
echo "════════════════════════════════════════════════════════════"
print_success "krb5 blob added successfully!"
echo "════════════════════════════════════════════════════════════"
echo
print_info "Summary:"
echo "  • Version: $VERSION"
echo "  • File: krb5/$KRB5_TARBALL"
echo "  • SHA256: $CHECKSUM"
echo "  • Size: $FILE_SIZE bytes"
echo

# Verify release can be created
read -p "Verify BOSH release can be created? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  print_info "Creating test release..."

  TEST_TARBALL="/tmp/telemetry-test-krb5-added.tgz"

  if bosh create-release --force --tarball="$TEST_TARBALL"; then
    print_success "Test release created successfully: $TEST_TARBALL"
    echo
    print_success "The krb5 blob issue is resolved!"
  else
    print_error "Failed to create test release"
    print_info "You may need to run: bosh sync-blobs"
    exit 1
  fi
fi

echo
print_info "Next steps:"
echo "  1. Review changes: git diff config/blobs.yml"
echo "  2. Commit the changes:"
echo "     git add config/blobs.yml"
echo "     git commit -m \"chore: Add krb5 $VERSION blob to blobstore\""
echo
print_info "For future krb5 version updates, use:"
echo "  ./scripts/update-krb5.sh <new-version>"
