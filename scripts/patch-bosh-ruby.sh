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

# Check if bosh is installed
if ! command -v bosh &>/dev/null; then
    echo "Error: bosh CLI is required to register patched gems as blobs." >&2
    exit 1
fi

# Check if yq is installed
if ! command -v yq &>/dev/null; then
    echo "Error: yq is required to inspect config/blobs.yml." >&2
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

# Clean up any stray gem files left in packages/ruby-4.0/ by older versions of
# this script. NOTE: packages/<name>/ is not one of BOSH's file-resolution
# roots for a package's 'files:' entries (only blobs/ and src/ are searched),
# so a raw gem dropped here is silently invisible to 'bosh create-release'
# until the release is actually built -- always register patched gems as
# blobs (below) instead of leaving them here.
rm -f packages/ruby-4.0/*.gem

# 2. Process each patch
for gem_name in ${keys}; do
    version=$(jq -r ".\"${gem_name}\"" "${PATCHES_FILE}")
    echo "Processing patch: ${gem_name} @ ${version}..."

    # Remove any stale blob entry left by a previous version of this gem
    if [[ -f config/blobs.yml ]]; then
        stale_keys=$(yq -r --arg prefix "packages/ruby-4.0/${gem_name}-" 'keys[] | select(startswith($prefix))' config/blobs.yml 2>/dev/null || true)
        while IFS= read -r stale_key; do
            [[ -z "${stale_key}" ]] && continue
            echo "  Removing stale blob entry: ${stale_key}"
            bosh remove-blob "${stale_key}" || true
        done <<< "${stale_keys}"
    fi

    # Download gem file to a scratch dir, not packages/ruby-4.0/ (see note above)
    tmp_dir=$(mktemp -d)
    echo "  Downloading ${gem_name}-${version}.gem..."
    (cd "${tmp_dir}" && gem fetch "${gem_name}" -v "${version}" --quiet)

    # Verify the gem file was downloaded
    gem_file="${tmp_dir}/${gem_name}-${version}.gem"
    if [[ ! -f "${gem_file}" ]]; then
        echo "Error: Failed to download ${gem_name}-${version}.gem" >&2
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Register it as a blob so 'bosh create-release' can resolve the spec
    # entry below. This only registers locally (populates config/blobs.yml
    # and the local blob cache) -- 'tpi release prep' detects and offers to
    # run 'bosh upload-blobs' once GCS credentials are confirmed available.
    blob_name="packages/ruby-4.0/${gem_name}-${version}.gem"
    echo "  Registering as blob: ${blob_name}..."
    bosh add-blob "${gem_file}" "${blob_name}"
    rm -rf "${tmp_dir}"

    # Add to spec files list
    echo "  Adding to spec..."
    echo "- ${blob_name}" >> "${SPEC_FILE}"

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
