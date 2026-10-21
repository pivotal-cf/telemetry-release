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
        if [[ "$1" == "--output" ]]; then printf '%s' "$RELEASE_CONTENT" > "$2"; exit 0; fi
        shift
    done
fi
exit 1
EOF
    chmod +x "${bindir}/bosh" "${bindir}/gh"

    if UPDATE_OUT="${tmpdir}/out" UPDATE_ERR="${tmpdir}/err" \
        PATH="${bindir}:${PATH}" CLI_SOURCE=ghe SKIP_UPLOAD=true \
        GCS_SERVICE_ACCOUNT_KEY_GRAVITY='{}' MISMATCH_BLOB_DIGEST="${mismatch}" \
        "${tmpdir}/scripts/update-telemetry-cli.sh" >"${tmpdir}/out" 2>"${tmpdir}/err"; then
        RUN_RC=0
    else
        RUN_RC=$?
    fi
    RUN_OUT="$(cat "${tmpdir}/out")"
    RUN_BLOBS="$(cat "${tmpdir}/config/blobs.yml")"
    RUN_DIR="${tmpdir}"
    RUN_BINDIR="${bindir}"
}

cleanup_run() {
    rm -rf "${RUN_DIR}" "${RUN_BINDIR}"
}

RELEASE_CONTENT='pre-release-binary'
RELEASE_SHA="$(printf '%s' "${RELEASE_CONTENT}" | sha256sum | awk '{print $1}')"
export RELEASE_CONTENT

echo "Running: stable release selection filters prereleases before choosing latest"
RELEASES_JSON='[{"tagName":"2.4.17-dev.1","isPrerelease":true},{"tagName":"2.4.16","isPrerelease":false}]'
RELEASE_JSON='{"tagName":"2.4.17-dev.1","isPrerelease":true,"assets":[{"name":"telemetry-cli-linux-amd64","digest":"sha256:PLACEHOLDER"}]}'
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
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-linux-amd64\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASES_JSON RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" || true
if [[ "${RUN_RC}" -eq 0 && "${RUN_BLOBS}" == *"telemetry-cli-linux-2.4.17-dev.1:"* ]]; then
    pass "exact mode installs prerelease 2.4.17-dev.1"
else
    fail "exact mode installs requested prerelease" "rc=${RUN_RC}; output: ${RUN_OUT}; blobs: ${RUN_BLOBS}"
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
RELEASE_JSON="$(printf '{\"tagName\":\"2.4.17-dev.1\",\"isPrerelease\":true,\"assets\":[{\"name\":\"telemetry-cli-linux-amd64\",\"digest\":\"sha256:%s\"}]}' "${RELEASE_SHA}")"
export RELEASE_JSON
CLI_VERSION=2.4.17-dev.1 run_update "2.4.16" "old" true || true
if [[ "${RUN_RC}" -ne 0 ]]; then
    pass "exact mode exits non-zero when installed digest differs"
else
    fail "exact mode rejects digest mismatch" "expected non-zero; output: ${RUN_OUT}"
fi
cleanup_run

echo "Running: prerelease suffix remains part of version comparison"
RELEASES_JSON='[{"tagName":"2.4.17","isPrerelease":false}]'
RELEASE_CONTENT='stable-binary'
RELEASE_SHA="$(printf '%s' "${RELEASE_CONTENT}" | sha256sum | awk '{print $1}')"
export RELEASES_JSON RELEASE_CONTENT
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
