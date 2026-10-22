#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_GIT="$(command -v git)"
FAILURES=0

fail() { echo "  FAIL: $1 - $2"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS: $1"; }

setup_case() {
    CASE_DIR="$(mktemp -d)"
    BIN_DIR="${CASE_DIR}/bin"
    WORK="${CASE_DIR}/repo"
    ORIGIN="${CASE_DIR}/origin.git"
    mkdir -p "${BIN_DIR}" "${WORK}/ci" "${WORK}/config" "${WORK}/scripts" "${WORK}/releases/telemetry" "${WORK}/packages"
    "${REAL_GIT}" init --bare -q "${ORIGIN}"
    "${REAL_GIT}" -C "${WORK}" init -q -b "${TEST_BRANCH:-dev/x}"
    "${REAL_GIT}" -C "${WORK}" config user.email test@example.com
    "${REAL_GIT}" -C "${WORK}" config user.name Tester
    "${REAL_GIT}" -C "${WORK}" remote add origin "${ORIGIN}"
    echo "${TEST_VERSION:-1.2.3-dev.7}" > "${WORK}/ci/VERSION"
    echo "blobstore: {}" > "${WORK}/config/private.yml"
    echo "---" > "${WORK}/config/blobs.yml"
    echo 'releases/**/*.tgz' > "${WORK}/.gitignore"
    cp "${REPO_ROOT}/scripts/create-final-release.sh" "${WORK}/scripts/"
    "${REAL_GIT}" -C "${WORK}" add .
    "${REAL_GIT}" -C "${WORK}" commit -q -m initial
    "${REAL_GIT}" -C "${WORK}" push -q -u origin HEAD

    cat > "${BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GIT_LOG}"
exec "${REAL_GIT}" "$@"
EOF
    cat > "${BIN_DIR}/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo 'bosh 7.1.0'; exit 0; fi
if [[ "$1" == "create-release" ]]; then
    while (($#)); do
        if [[ "$1" == --tarball ]]; then tarball="$2"; shift 2; else shift; fi
    done
    mkdir -p releases/telemetry .final_builds
    echo manifest > "releases/telemetry/telemetry-${VERSION}.yml"
    echo index > releases/telemetry/index.yml
    echo fingerprint > .final_builds/job.yml
    echo tarball > "$tarball"
    exit 0
fi
EOF
    cat > "${BIN_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo 'gh 2.0.0'; exit 0; fi
if [[ "$1" == release && "$2" == view ]]; then
    if [[ -f "${GH_RELEASE_STATE}" ]]; then
        if grep -q '^prerelease$' "${GH_RELEASE_STATE}"; then prerelease=true; else prerelease=false; fi
        if [[ "$*" == *--jq* ]]; then echo "${prerelease}"; else echo "{\"isPrerelease\":${prerelease}}"; fi
        exit 0
    fi
    exit 1
fi
if [[ "$1" == release && "$2" == create ]]; then
    printf '%s\n' "$*" >> "${GH_CREATE_LOG}"
    if [[ "${FAIL_FIRST_RELEASE:-false}" == true && ! -f "${GH_RELEASE_STATE}" ]]; then exit 1; fi
    touch "${GH_RELEASE_STATE}"
    exit 0
fi
exit 0
EOF
    chmod +x "${BIN_DIR}/git" "${BIN_DIR}/bosh" "${BIN_DIR}/gh"
    export REAL_GIT GIT_LOG="${CASE_DIR}/git.log" GH_CREATE_LOG="${CASE_DIR}/gh-create.log"
    export GH_RELEASE_STATE="${CASE_DIR}/release-exists" VERSION="${TEST_VERSION:-1.2.3-dev.7}"
    export FAIL_FIRST_RELEASE=false
    : > "${GIT_LOG}"
    : > "${GH_CREATE_LOG}"
}

run_script() {
    (cd "${WORK}" && PATH="${BIN_DIR}:${PATH}" AUTO_APPROVE=true \
        ./scripts/create-final-release.sh) > "${CASE_DIR}/out" 2> "${CASE_DIR}/err"
}

cleanup_case() { rm -rf "${CASE_DIR}"; }

echo 'Running: remote release tag verification accepts matching and missing tags'
HELPERS_FILE="$(mktemp)"
sed -n '/^verify_remote_release_tag() {/,/^}$/p' "${REPO_ROOT}/scripts/create-final-release.sh" > "${HELPERS_FILE}"
source "${HELPERS_FILE}"
print_error() { echo "$*" >&2; }
git() {
    if [[ "${REMOTE_TAG_OUTPUT:-}" == '__MISSING__' ]]; then return 0; fi
    printf '%s\n' "${REMOTE_TAG_OUTPUT:-}"
}
REMOTE_TAG_OUTPUT=$'release-sha\trefs/tags/2.4.17-dev.1\nrelease-sha\trefs/tags/2.4.17-dev.1^{}'
verify_remote_release_tag 2.4.17-dev.1 release-sha || fail 'matching remote tag' 'expected success'
REMOTE_TAG_OUTPUT=$'other-sha\trefs/tags/2.4.17-dev.1\nother-sha\trefs/tags/2.4.17-dev.1^{}'
if verify_remote_release_tag 2.4.17-dev.1 release-sha; then fail 'mismatched remote tag' 'expected failure'; else pass 'mismatched remote tag is rejected'; fi
REMOTE_TAG_OUTPUT=__MISSING__
verify_remote_release_tag 2.4.17-dev.1 release-sha || fail 'missing remote tag' 'expected success'
rm -f "${HELPERS_FILE}"

echo 'Running: dev release uses prerelease and verified target, and pushes only its branch'
setup_case
if run_script; then
    sha="$("${REAL_GIT}" -C "${WORK}" rev-parse HEAD)"
    if grep -q -- '--prerelease' "${GH_CREATE_LOG}" && grep -q -- "--target ${sha}" "${GH_CREATE_LOG}" &&
        ! grep -qx 'push' "${GIT_LOG}" && grep -q "push origin HEAD:refs/heads/dev/x" "${GIT_LOG}" &&
        grep -q 'ls-remote origin refs/heads/dev/x' "${GIT_LOG}" &&
        [[ -f "${WORK}/releases/telemetry/telemetry-${VERSION}.tgz" ]]; then
        pass 'dev release flags, explicit push, remote verification, and repository tarball'
    else
        fail 'dev release behavior' "git: $(cat "${GIT_LOG}"); gh: $(cat "${GH_CREATE_LOG}")"
    fi
else fail 'dev release execution' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
cleanup_case

echo 'Running: dev release rejects a non-dev branch'
TEST_BRANCH=main setup_case
if run_script; then fail 'dev branch guard' 'expected failure';
elif grep -q 'must run on a dev/' "${CASE_DIR}/out" "${CASE_DIR}/err"; then pass 'dev release rejects non-dev branch';
else fail 'dev branch guard' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
cleanup_case

echo 'Running: stable release rejects a dev branch'
TEST_BRANCH=dev/x TEST_VERSION=1.2.3 setup_case
if run_script; then fail 'stable branch guard' 'expected failure';
elif grep -q 'Stable releases cannot run on dev/' "${CASE_DIR}/out" "${CASE_DIR}/err"; then pass 'stable release rejects dev branch';
else fail 'stable branch guard' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
cleanup_case

echo 'Running: stable release omits prerelease flag'
TEST_BRANCH=main TEST_VERSION=1.2.3 setup_case
if run_script && ! grep -q -- '--prerelease' "${GH_CREATE_LOG}"; then pass 'stable release has no prerelease flag';
else fail 'stable release flags' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err" "${GH_CREATE_LOG}")"; fi
cleanup_case

echo 'Running: existing dev GitHub pre-release is left unchanged'
setup_case
echo prerelease > "${GH_RELEASE_STATE}"
if run_script && grep -q 'already exists. No changes made' "${CASE_DIR}/out" &&
    [[ ! -s "${GH_CREATE_LOG}" ]]; then
    pass 'existing dev pre-release exits without changing it'
else fail 'existing dev pre-release' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
cleanup_case

echo 'Running: existing stable GitHub release is rejected for a dev version'
setup_case
touch "${GH_RELEASE_STATE}"
if run_script; then fail 'existing stable release for dev version' 'expected failure';
elif grep -q 'exists but is not a pre-release' "${CASE_DIR}/out"; then pass 'existing stable release is rejected';
else fail 'existing stable release for dev version' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
cleanup_case

echo 'Running: retry after release failure skips the build'
setup_case
export FAIL_FIRST_RELEASE=true
if run_script; then fail 'first release attempt' 'expected GitHub create failure';
elif [[ -f "${WORK}/releases/telemetry/telemetry-${VERSION}.yml" ]]; then
    : > "${CASE_DIR}/bosh.log"
    # Make a bosh shim that records whether a retry rebuilds.
    cat > "${BIN_DIR}/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then echo 'bosh 7.1.0'; exit 0; fi
if [[ "$1" == create-release ]]; then echo "$*" >> "${BOSH_RETRY_LOG}"; fi
exit 99
EOF
    chmod +x "${BIN_DIR}/bosh"
    export BOSH_RETRY_LOG="${CASE_DIR}/bosh.log"
    export FAIL_FIRST_RELEASE=false
    if run_script && [[ ! -s "${CASE_DIR}/bosh.log" ]] && [[ "$(grep -c '^release create' "${GH_CREATE_LOG}")" -eq 2 ]]; then
        pass 'retry creates release without invoking bosh create-release'
    else fail 'retry behavior' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err" "${GH_CREATE_LOG}")"; fi
else fail 'first release attempt' "$(cat "${CASE_DIR}/out" "${CASE_DIR}/err")"; fi
unset FAIL_FIRST_RELEASE
cleanup_case

if [[ "${FAILURES}" -gt 0 ]]; then echo "${FAILURES} test(s) failed"; exit 1; fi
echo 'All create-final-release dev tests passed'
