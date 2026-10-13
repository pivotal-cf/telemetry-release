#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
TOTAL=0

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1 - $2"
    FAILURES=$((FAILURES + 1))
}

run_test() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    echo "Running: ${name}"
    "$@"
}

# ----------------------------------------------------------------------------
# Test 1: create-final-release.sh refuses to run on dirty repo (exit 60)
# ----------------------------------------------------------------------------
test_create_final_release_dirty_repo() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    local bindir
    bindir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}' '${bindir}'" RETURN

    git -C "${tmpdir}" init -q
    git -C "${tmpdir}" config user.email "test@example.com"
    git -C "${tmpdir}" config user.name "Tester"
    mkdir -p "${tmpdir}/ci" "${tmpdir}/config" "${tmpdir}/scripts"
    echo "1.0.0" > "${tmpdir}/ci/VERSION"
    echo "blobstore: {}" > "${tmpdir}/config/private.yml"
    echo "committed" > "${tmpdir}/tracked.txt"
    cp "${REPO_ROOT}/scripts/create-final-release.sh" "${tmpdir}/scripts/"
    chmod +x "${tmpdir}/scripts/create-final-release.sh"

    # Stub bosh and gh
    cat > "${bindir}/bosh" <<'EOF'
#!/usr/bin/env bash
echo "bosh 7.1.0"
EOF
    cat > "${bindir}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh 2.0.0"
EOF
    chmod +x "${bindir}/bosh" "${bindir}/gh"

    git -C "${tmpdir}" add .
    git -C "${tmpdir}" commit -m "initial commit" -q

    # Make repo dirty
    echo "dirty change" >> "${tmpdir}/tracked.txt"

    local stderr_file="${bindir}/stderr.log"
    local rc=0

    PATH="${bindir}:${PATH}" "${tmpdir}/scripts/create-final-release.sh" 2>"${stderr_file}" || rc=$?

    if [[ $rc -ne 60 ]]; then
        fail "create-final-release.sh dirty exit code" "expected 60, got ${rc}"
        return
    fi

    local expected_msg="Error: repository ${tmpdir} has uncommitted changes"
    if ! grep -qF "${expected_msg}" "${stderr_file}"; then
        fail "create-final-release.sh dirty message" "expected stderr to contain '${expected_msg}', got: $(cat "${stderr_file}")"
        return
    fi

    pass "create-final-release.sh exits 60 on dirty repo with expected message"
}

# ----------------------------------------------------------------------------
# Test 2: create-final-release.sh stages only named files, not unrelated files
# ----------------------------------------------------------------------------
test_create_final_release_stages_only_named() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local remotedir
    remotedir="$(mktemp -d)"
    local bindir
    bindir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}' '${remotedir}' '${bindir}'" RETURN

    git init --bare -q "${remotedir}/origin.git"

    git -C "${tmpdir}" init -q
    git -C "${tmpdir}" config user.email "test@example.com"
    git -C "${tmpdir}" config user.name "Tester"
    git -C "${tmpdir}" remote add origin "${remotedir}/origin.git"
    mkdir -p "${tmpdir}/ci" "${tmpdir}/config" "${tmpdir}/scripts" "${tmpdir}/releases/telemetry" "${tmpdir}/packages"
    echo "1.0.0" > "${tmpdir}/ci/VERSION"
    echo "blobstore: {}" > "${tmpdir}/config/private.yml"
    echo "---" > "${tmpdir}/config/blobs.yml"
    echo "committed" > "${tmpdir}/tracked.txt"
    cp "${REPO_ROOT}/scripts/create-final-release.sh" "${tmpdir}/scripts/"
    chmod +x "${tmpdir}/scripts/create-final-release.sh"

    git -C "${tmpdir}" add .
    git -C "${tmpdir}" commit -m "initial commit" -q
    git -C "${tmpdir}" push -u origin HEAD -q

    # Stub bosh create-release to generate release files and modify config/blobs.yml,
    # AND simulate an unrelated untracked file appearing during the build
    cat > "${bindir}/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"create-release"* ]]; then
    for arg in "$@"; do
        if [[ "$prev" == "--tarball" ]]; then
            touch "$arg"
        fi
        prev="$arg"
    done
    mkdir -p releases/telemetry .final_builds
    echo "manifest" > releases/telemetry/telemetry-1.0.0.yml
    echo "index" > releases/telemetry/index.yml
    echo "fingerprint" > .final_builds/job.yml
    echo "blobs update" >> config/blobs.yml
    echo "unrelated untracked file" > unrelated.txt
    exit 0
fi
echo "bosh 7.1.0"
exit 0
EOF

    cat > "${bindir}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"release view"* ]]; then
    exit 1
fi
echo "gh 2.0.0"
exit 0
EOF
    chmod +x "${bindir}/bosh" "${bindir}/gh"

    local stdout_file="${bindir}/out.log"
    local stderr_file="${bindir}/err.log"
    local rc=0
    PATH="${bindir}:${PATH}" AUTO_APPROVE="true" \
        "${tmpdir}/scripts/create-final-release.sh" </dev/null >"${stdout_file}" 2>"${stderr_file}" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "create-final-release.sh execution" "expected exit 0, got ${rc}. out: $(cat "${stdout_file}") err: $(cat "${stderr_file}")"
        return
    fi

    # Check git log of the latest commit: unrelated.txt must NOT be committed
    if git -C "${tmpdir}" show HEAD --name-only | grep -qF "unrelated.txt"; then
        fail "stages only named files" "unrelated.txt was committed by create-final-release.sh"
        return
    fi

    # Check git status: unrelated.txt must still be untracked (??), not staged or committed
    if ! git -C "${tmpdir}" status --porcelain | grep -q "^?? unrelated.txt"; then
        fail "stages only named files" "unrelated.txt should remain untracked"
        return
    fi

    pass "create-final-release.sh stages only named files, leaving unrelated files untouched"
}

# ----------------------------------------------------------------------------
# Test 3: create-final-release.sh without AUTO_APPROVE fails on non-terminal
# ----------------------------------------------------------------------------
test_create_final_release_no_terminal() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    local bindir
    bindir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}' '${bindir}'" RETURN

    git -C "${tmpdir}" init -q
    git -C "${tmpdir}" config user.email "test@example.com"
    git -C "${tmpdir}" config user.name "Tester"
    mkdir -p "${tmpdir}/ci" "${tmpdir}/config" "${tmpdir}/scripts" "${tmpdir}/releases/telemetry"
    echo "1.0.0" > "${tmpdir}/ci/VERSION"
    echo "blobstore: {}" > "${tmpdir}/config/private.yml"
    echo "---" > "${tmpdir}/config/blobs.yml"
    cp "${REPO_ROOT}/scripts/create-final-release.sh" "${tmpdir}/scripts/"
    chmod +x "${tmpdir}/scripts/create-final-release.sh"

    git -C "${tmpdir}" add .
    git -C "${tmpdir}" commit -m "initial commit" -q

    cat > "${bindir}/bosh" <<'EOF'
#!/usr/bin/env bash
echo "bosh 7.1.0"
exit 0
EOF
    # Simulate existing release to trigger the prompt at line 128
    cat > "${bindir}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"release view"* ]]; then
    exit 0
fi
echo "gh 2.0.0"
exit 0
EOF
    chmod +x "${bindir}/bosh" "${bindir}/gh"

    local stderr_file="${bindir}/stderr.log"
    local rc=0
    PATH="${bindir}:${PATH}" \
        "${tmpdir}/scripts/create-final-release.sh" </dev/null 2>"${stderr_file}" || rc=$?

    if [[ $rc -ne 1 ]]; then
        fail "create-final-release.sh non-terminal" "expected exit 1, got ${rc}. stderr: $(cat "${stderr_file}")"
        return
    fi

    if ! grep -qF "Error: stdin is not a terminal" "${stderr_file}"; then
        fail "create-final-release.sh non-terminal error" "expected 'Error: stdin is not a terminal' in stderr, got: $(cat "${stderr_file}")"
        return
    fi

    pass "create-final-release.sh exits 1 on non-terminal stdin at prompt"
}

# ----------------------------------------------------------------------------
# Test 4: update-fluent-bit.sh with AUTO_APPROVE=true auto-approves prompts
# ----------------------------------------------------------------------------
test_update_fluent_bit_auto_approve() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    mkdir -p "${tmpdir}/bin" "${tmpdir}/scripts" "${tmpdir}/config"
    git -C "${tmpdir}" init -q
    touch "${tmpdir}/service_account.json"
    echo "fluent-bit/fluent-bit-1.0.0.tar.gz:" > "${tmpdir}/config/blobs.yml"
    cp "${REPO_ROOT}/scripts/update-fluent-bit.sh" "${tmpdir}/scripts/"
    chmod +x "${tmpdir}/scripts/update-fluent-bit.sh"

    cat > "${tmpdir}/bin/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"blobs"* ]]; then
    echo "fluent-bit/fluent-bit-1.0.0.tar.gz"
    exit 0
fi
if [[ "$*" == *"add-blob"* ]]; then exit 0; fi
if [[ "$*" == *"upload-blobs"* ]]; then exit 0; fi
if [[ "$*" == *"remove-blob"* ]]; then exit 0; fi
if [[ "$*" == *"create-release"* ]]; then
    for arg in "$@"; do
        if [[ "$arg" == --tarball=* ]]; then
            touch "${arg#*=}"
        fi
    done
    exit 0
fi
exit 0
EOF

    cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        touch "$arg"
    fi
    prev="$arg"
done
exit 0
EOF

    cat > "${tmpdir}/bin/shasum" <<'EOF'
#!/usr/bin/env bash
echo "dummychecksum  file"
exit 0
EOF
    chmod +x "${tmpdir}/bin/bosh" "${tmpdir}/bin/curl" "${tmpdir}/bin/shasum"

    local stderr_file="${tmpdir}/stderr.log"
    local rc=0

    PATH="${tmpdir}/bin:${PATH}" AUTO_APPROVE="true" \
        "${tmpdir}/scripts/update-fluent-bit.sh" "5.1.4" </dev/null 2>"${stderr_file}" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "update-fluent-bit.sh AUTO_APPROVE" "expected exit 0, got ${rc}. stderr: $(cat "${stderr_file}")"
        return
    fi

    if ! grep -qF "Auto-approved: Continue? (y/n)" "${stderr_file}"; then
        fail "update-fluent-bit.sh AUTO_APPROVE log" "expected 'Auto-approved: Continue? (y/n)' in stderr, got: $(cat "${stderr_file}")"
        return
    fi

    pass "update-fluent-bit.sh auto-approves prompts with AUTO_APPROVE=true"
}

# ----------------------------------------------------------------------------
# Test 5: update-fluent-bit.sh without AUTO_APPROVE fails on non-terminal
# ----------------------------------------------------------------------------
test_update_fluent_bit_no_terminal() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    mkdir -p "${tmpdir}/bin" "${tmpdir}/scripts" "${tmpdir}/config"
    git -C "${tmpdir}" init -q
    touch "${tmpdir}/service_account.json"
    echo "---" > "${tmpdir}/config/blobs.yml"
    cp "${REPO_ROOT}/scripts/update-fluent-bit.sh" "${tmpdir}/scripts/"
    chmod +x "${tmpdir}/scripts/update-fluent-bit.sh"

    cat > "${tmpdir}/bin/bosh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"blobs"* ]]; then
    echo "fluent-bit/fluent-bit-1.0.0.tar.gz"
    exit 0
fi
if [[ "$*" == *"add-blob"* ]]; then exit 0; fi
if [[ "$*" == *"upload-blobs"* ]]; then exit 0; fi
if [[ "$*" == *"remove-blob"* ]]; then exit 0; fi
exit 0
EOF

    cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        touch "$arg"
    fi
    prev="$arg"
done
exit 0
EOF

    cat > "${tmpdir}/bin/shasum" <<'EOF'
#!/usr/bin/env bash
echo "dummychecksum  file"
exit 0
EOF
    chmod +x "${tmpdir}/bin/bosh" "${tmpdir}/bin/curl" "${tmpdir}/bin/shasum"

    local stderr_file="${tmpdir}/stderr.log"
    local rc=0

    PATH="${tmpdir}/bin:${PATH}" \
        "${tmpdir}/scripts/update-fluent-bit.sh" "5.1.4" </dev/null 2>"${stderr_file}" || rc=$?

    if [[ $rc -ne 1 ]]; then
        fail "update-fluent-bit.sh non-terminal" "expected exit 1, got ${rc}. stderr: $(cat "${stderr_file}")"
        return
    fi

    if ! grep -qF "Error: stdin is not a terminal" "${stderr_file}"; then
        fail "update-fluent-bit.sh non-terminal error" "expected 'Error: stdin is not a terminal' in stderr, got: $(cat "${stderr_file}")"
        return
    fi

    pass "update-fluent-bit.sh exits 1 on non-terminal stdin at prompt"
}

# ----------------------------------------------------------------------------
# Test 6: ask_yes_no interactive terminal behavior (y vs n)
# ----------------------------------------------------------------------------
test_ask_yes_no_terminal() {
    local res_y
    res_y=$(python3 -c "
import pty, os, sys
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.dup2(slave, 0)
    os.close(slave)
    os.execlp('bash', 'bash', '-c', 'eval \"\$(sed -n \"/^ask_yes_no()/,/^}/p\" ${REPO_ROOT}/scripts/create-final-release.sh)\"; if ask_yes_no \"Test?\"; then echo YES; else echo NO; fi')
else:
    os.close(slave)
    os.write(master, b'y\n')
    out = b''
    while True:
        try:
            chunk = os.read(master, 1024)
            if not chunk: break
            out += chunk
        except OSError: break
    os.close(master)
    os.waitpid(pid, 0)
    print(out.decode(errors='replace').strip())
" 2>/dev/null || true)

    if ! echo "${res_y}" | grep -q "YES"; then
        fail "ask_yes_no terminal 'y'" "expected YES, got: ${res_y}"
        return
    fi

    local res_n
    res_n=$(python3 -c "
import pty, os, sys
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.dup2(slave, 0)
    os.close(slave)
    os.execlp('bash', 'bash', '-c', 'eval \"\$(sed -n \"/^ask_yes_no()/,/^}/p\" ${REPO_ROOT}/scripts/create-final-release.sh)\"; if ask_yes_no \"Test?\"; then echo YES; else echo NO; fi')
else:
    os.close(slave)
    os.write(master, b'n\n')
    out = b''
    while True:
        try:
            chunk = os.read(master, 1024)
            if not chunk: break
            out += chunk
        except OSError: break
    os.close(master)
    os.waitpid(pid, 0)
    print(out.decode(errors='replace').strip())
" 2>/dev/null || true)

    if ! echo "${res_n}" | grep -q "NO"; then
        fail "ask_yes_no terminal 'n'" "expected NO, got: ${res_n}"
        return
    fi

    pass "ask_yes_no responds correctly to 'y' and 'n' with a terminal"
}

run_test "test_create_final_release_dirty_repo" test_create_final_release_dirty_repo
run_test "test_create_final_release_stages_only_named" test_create_final_release_stages_only_named
run_test "test_create_final_release_no_terminal" test_create_final_release_no_terminal
run_test "test_update_fluent_bit_auto_approve" test_update_fluent_bit_auto_approve
run_test "test_update_fluent_bit_no_terminal" test_update_fluent_bit_no_terminal
run_test "test_ask_yes_no_terminal" test_ask_yes_no_terminal

echo ""
echo "Summary: $((TOTAL - FAILURES))/${TOTAL} passed, ${FAILURES} failed"
if [[ ${FAILURES} -gt 0 ]]; then
    exit 1
fi
