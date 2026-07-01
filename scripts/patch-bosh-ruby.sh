#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PATCHES_FILE="config/ruby-patches.json"

if [[ ! -f "${PATCHES_FILE}" ]]; then
    echo "No patches configuration found at ${PATCHES_FILE}. Skipping."
    exit 0
fi

# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to run this script." >&2
    exit 1
fi

# Check if gem is installed
if ! command -v gem &>/dev/null; then
    echo "Error: gem is required to download patched gems." >&2
    exit 1
fi

# Parse patches
keys=$(jq -r 'keys[]' "${PATCHES_FILE}" 2>/dev/null || echo "")
if [[ -z "${keys}" ]]; then
    echo "No default gems to patch in ${PATCHES_FILE}. Skipping."
    exit 0
fi

echo "=== Ruby Default Gem CVE Patching ==="

# 1. Fetch clean upstream spec and packaging
RUBY_RELEASE_PATH="${1:-}"
SPEC_FILE="packages/ruby-4.0/spec"
PACKAGING_FILE="packages/ruby-4.0/packaging"

mkdir -p packages/ruby-4.0

# Try local path first, then fallback to GitHub
if [[ -n "${RUBY_RELEASE_PATH}" && -d "${RUBY_RELEASE_PATH}" ]]; then
    echo "Using local bosh-package-ruby-release at ${RUBY_RELEASE_PATH}..."
    cp "${RUBY_RELEASE_PATH}/packages/ruby-4.0/spec" "${SPEC_FILE}"
    cp "${RUBY_RELEASE_PATH}/packages/ruby-4.0/packaging" "${PACKAGING_FILE}"
else
    echo "Fetching clean upstream spec and packaging from GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-4.0/spec" > "${SPEC_FILE}"
    curl -fsSL "https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-4.0/packaging" > "${PACKAGING_FILE}"
fi

# Clean up any existing downloaded gem files in packages/ruby-4.0/
rm -f packages/ruby-4.0/*.gem

# 2. Process each patch
for gem_name in ${keys}; do
    version=$(jq -r ".\"${gem_name}\"" "${PATCHES_FILE}")
    echo "Processing patch: ${gem_name} @ ${version}..."

    # Download gem file
    echo "  Downloading ${gem_name}-${version}.gem..."
    (cd packages/ruby-4.0 && gem fetch "${gem_name}" -v "${version}" --quiet)

    # Verify the gem file was downloaded
    gem_file="packages/ruby-4.0/${gem_name}-${version}.gem"
    if [[ ! -f "${gem_file}" ]]; then
        echo "Error: Failed to download ${gem_name}-${version}.gem" >&2
        exit 1
    fi

    # Add to spec files list
    echo "  Adding to spec..."
    echo "- packages/ruby-4.0/${gem_name}-${version}.gem" >> "${SPEC_FILE}"

    # Append installation/uninstallation commands to packaging
    echo "  Adding patch commands to packaging..."
    cat <<EOF >> "${PACKAGING_FILE}"

# Override the bundled ${gem_name} gem with a patched version (CVE remediation).
echo "Installing ${gem_name} ${version} (replacing bundled version)"
old_version=\$(ruby -e "begin; puts Gem::Specification.find_by_name('${gem_name}').version; rescue Exception; puts 'unknown'; end")
gem install --local "\${BOSH_COMPILE_TARGET}/packages/ruby-4.0/${gem_name}-${version}.gem" --no-document
if [[ "\${old_version}" != "unknown" && "\${old_version}" != "${version}" ]]; then
  gem uninstall ${gem_name} --version "\${old_version}" --force --executables
fi
EOF
done

echo "=== Patching Complete ==="
