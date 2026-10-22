#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/update-telemetry-cli.sh"
FAILURES=0

fail() {
    echo "  FAIL: $1 - $2"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "  PASS: $1"
}

run_update() {
    local current_version="$1"
    local current_sha="$2"
    local mismatch="${3:-false}"
    local release_tarball="${4:-${RELEASE_TARBALL}}"
    local tmpdir bindir
    tmpdir="$(mktemp -d)"
    bindir="$(mktemp -d)"
    mkdir -p "${tmpdir}/scripts" "${tmpdir}/config"
    cp "${SCRIPT}" "${tmpdir}/scripts/update-telemetry-cli.sh"
    cat > "${tmpdir}/config/blobs.yml" <<EOF
telemetry-cli/telemetry-cli-linux-${current_version}:
  size: 22
  sha: sha256:${current_sha}
EOF

    cat > "${bindir}/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "bosh 7.1.0"; exit 0; fi
if [[ "$1" == "remove-blob" ]]; then exit 0; fi
if [[ "$1" == "add-blob" ]]; then
    sha="$(sha256sum "$2" | awk '{print $1}')"
    if [[ "${MISMATCH_BLOB_DIGEST:-false}" == "true" ]]; then sha="wrong"; fi
    printf '%s\n  size: 22\n  sha: sha256:%s\n' "$3:" "$sha" >> config/blobs.yml
    exit 0
fi
exit 0
EOF
    cat > "${bindir}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "gh 2.0.0"; exit 0; fi
if [[ "$1" == "auth" ]]; then exit 0; fi
if [[ "$1" == "release" && "$2" == "list" ]]; then
    query=""
    while (($#)); do
        if [[ "$1" == "--jq" ]]; then query="$2"; shift 2; else shift; fi
    done
    printf '%s' "$RELEASES_JSON" | jq -r "$query"
    exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
    printf '%s' "$RELEASE_JSON"
    exit 0
fi
if [[ "$1" == "release" && "$2" == "download" ]]; then
    while (($#)); do
        if [[ "$1" == "--output" ]]; then cp "$RELEASE_TARBALL" "$2"; exit 0; fi
        shift
    done
fi
exit 1
EOF
    chmod +x "${bindir}/bosh" "${bindir}/gh"
    cat > "${bindir}/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "$2" ]]; then
    echo "mv rejects moving a file onto itself" >&2
    exit 1
fi
exec /bin/mv "$@"
EOF
    chmod +x "${bindir}/mv"

    if UPDATE_OUT="${tmpdir}/out" UPDATE_ERR="${tmpdir}/err" \
        PATH="${bindir}:${PATH}" CLI_SOURCE=ghe SKIP_UPLOAD=true RELEASE_TARBALL="${release_tarball}" \
        GCS_SERVICE_ACCOUNT_KEY_GRAVITY='{}' MISMATCH_BLOB_DIGEST="${mismatch}" \
        "${tmpdir}/scripts/update-telemetry-cli.sh" >"${tmpdir}/out" 2>"${tmpdir}/err"; then
        RUN_RC=0
    else
        RUN_RC=$?
    fi
    RUN_OUT="$(cat "${tmpdir}/out")"
    RUN_ERR="$(cat "${tmpdir}/err")"
    RUN_BLOBS="$(cat "${tmpdir}/config/blobs.yml")"
    RUN_DIR="${tmpdir}"
    RUN_BINDIR="${bindir}"
}

cleanup_run() {
    rm -rf "${RUN_DIR}" "${RUN_BINDIR}"
}

FIXTURE_DIR="$(mktemp -d)"
mkdir -p "${FIXTURE_DIR}/release"
printf '%s' 'pre-release-binary' > "${FIXTURE_DIR}/release/telemetry-cli-linux-amd64"
tar czf "${FIXTURE_DIR}/telemetry-cli-2.4.17-dev.1.tgz" -C "${FIXTURE_DIR}/release" telemetry-cli-linux-amd64
RELEASE_TARBALL="${FIXTURE_DIR}/telemetry-cli-2.4.17-dev.1.tgz"
RELEASE_SHA="$(sha256sum "${RELEASE_TARBALL}" | awk '{print $1}')"
RELEASE_BINARY_SHA="$(sha256sum "${FIXTURE_DIR}/release/telemetry-cli-linux-amd64" | awk '{print $1}')"
export RELEASE_TARBALL

echo "Running: stable release selection filters prereleases before choosing latest"
RELEASES_JSON='[{"tagName":"2.4.17-dev.1","isPrerelease":true},{"tagName":"2.4.16","isPrerelease":false}]'
RELEASE_JSON='{"tagName":"2.4.17-dev.1","isPrerelease":true,"assets":[{"name":"telemetry-cli-2.4.17-dev.1.tgz","digest":"sha256:PLACEHOLDER"}]}'
export RELEASES_JSON RELEASE_JSON
run_update "2.4.15" "old" || true
if [[ "${RUN_RC}" -eq 0 && "${RUN_BLOBS}" == *"telemetry-cli-linux-2.4.16:"* ]]; then
    pass "default mode selects stable 2.4.16"
else
    fail "default mode selects stable release" "rc=${RUN_RC}; output: ${RUN_OUT}; blobs: ${RUN_BLOBS}"
fi
cleanup_run

echo "Running: exact mode installs the requested prerelease"
RELEASES_JSON='[]'
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-2.4.17-dev.1.tgz\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASES_JSON RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" || true
if [[ "${RUN_RC}" -eq 0 && "${RUN_BLOBS}" == *"telemetry-cli-linux-2.4.17-dev.1:"* ]]; then
    pass "exact mode installs prerelease 2.4.17-dev.1"
else
    fail "exact mode installs requested prerelease" "rc=${RUN_RC}; output: ${RUN_OUT}; blobs: ${RUN_BLOBS}"
fi
cleanup_run

echo "Running: exact mode accepts an already installed exact version"
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-2.4.17-dev.1.tgz\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.17-dev.1" "${RELEASE_BINARY_SHA}" || true
if [[ "${RUN_RC}" -eq 0 && "${RUN_OUT}" == *"NO_UPDATE=true"* ]]; then
    pass "exact mode recognizes the installed exact version"
else
    fail "exact mode recognizes the installed exact version" "rc=${RUN_RC}; output: ${RUN_OUT}; error: ${RUN_ERR}"
fi
cleanup_run

echo "Running: exact mode rejects a tarball missing the Linux binary"
mkdir -p "${FIXTURE_DIR}/empty-release"
tar czf "${FIXTURE_DIR}/missing-binary.tgz" -C "${FIXTURE_DIR}/empty-release" .
MISSING_BINARY_SHA="$(sha256sum "${FIXTURE_DIR}/missing-binary.tgz" | awk '{print $1}')"
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-2.4.17-dev.1.tgz\",\"digest\":\"sha256:%s\"}]}' "${MISSING_BINARY_SHA}")"
export RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" false "${FIXTURE_DIR}/missing-binary.tgz" || true
if [[ "${RUN_RC}" -ne 0 && "${RUN_OUT}${RUN_ERR}" == *"Could not find linux-amd64 binary in release tarball"* ]]; then
    pass "exact mode rejects tarball without Linux binary"
else
    fail "exact mode rejects tarball without Linux binary" "rc=${RUN_RC}; output: ${RUN_OUT}; error: ${RUN_ERR}"
fi
cleanup_run

echo "Running: exact dev mode rejects a stable GitHub release"
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":false,\"assets\":[{\"name\":\"telemetry-cli-2.4.17-dev.1.tgz\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" || true
if [[ "${RUN_RC}" -ne 0 && "${RUN_OUT}" == *"is not a pre-release"* ]]; then
    pass "exact dev mode rejects a stable release"
else
    fail "exact dev release must be prerelease" "rc=${RUN_RC}; output: ${RUN_OUT}"
fi
cleanup_run

echo "Running: exact mode fails when the requested release does not exist"
RELEASE_JSON=''
export RELEASE_JSON
CLI_VERSION=9.9.9-dev.1 run_update "2.4.16" "old" || true
if [[ "${RUN_RC}" -ne 0 && "${RUN_OUT}" == *"Could not find exact release 9.9.9-dev.1"* ]]; then
    pass "exact mode rejects a missing release"
else
    fail "exact mode rejects missing release" "rc=${RUN_RC}; output: ${RUN_OUT}"
fi
cleanup_run

echo "Running: exact mode rejects an installed digest mismatch"
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-2.4.17-dev.1.tgz\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" true || true
if [[ "${RUN_RC}" -ne 0 && "${RUN_OUT}${RUN_ERR}" == *"Installed blob version or digest does not match release 2.4.17-dev.1"* ]]; then
    pass "exact mode exits non-zero when installed digest differs"
else
    fail "exact mode rejects digest mismatch at digest check" "rc=${RUN_RC}; output: ${RUN_OUT}; error: ${RUN_ERR}"
fi
cleanup_run

echo "Running: prerelease suffix remains part of version comparison"
RELEASES_JSON='[{"tagName":"2.4.17","isPrerelease":false}]'
export RELEASES_JSON
CLI_VERSION= run_update "2.4.17-dev.1" "${RELEASE_SHA}" || true
if [[ "${RUN_RC}" -eq 0 && "${RUN_BLOBS}" == *"telemetry-cli-linux-2.4.17:"* && "${RUN_OUT}" != *"NO_UPDATE=true"* ]]; then
    pass "2.4.17-dev.1 compares distinctly from 2.4.17"
else
    fail "version comparison preserves prerelease suffix" "rc=${RUN_RC}; output: ${RUN_OUT}; blobs: ${RUN_BLOBS}"
fi
cleanup_run

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} test(s) failed"
    exit 1
fi
echo "All prerelease tests passed"
