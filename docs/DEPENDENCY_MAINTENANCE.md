# Dependency Maintenance

## Ruby BOSH Package (`packages/ruby-3.4`)

The `ruby-3.4` package is normally maintained as a **fingerprint reference** to
[cloudfoundry/bosh-package-ruby-release](https://github.com/cloudfoundry/bosh-package-ruby-release).
It contains only `spec.lock` (the package fingerprint) and `VERSION` (the vendored Ruby version).

### Normal update flow

```bash
tpi release bump-ruby
```

This fetches the latest Ruby 3.4.x version from upstream bosh-package-ruby-release,
runs `bosh vendor-package`, and commits the updated `spec.lock` and `VERSION`.

---

### Emergency gem-level CVE patches

Sometimes a CVE is fixed in a bundled gem before the upstream Ruby release ships.
When that happens, the package must be **promoted to a local source package** so
the packaging script can install the patched gem directly.

This is the current state as of May 2026 (net-imap CVE patch — see below).

#### What "promoted" looks like

Instead of just `spec.lock` + `VERSION`, the package directory also contains:
- `packages/ruby-3.4/spec`
- `packages/ruby-3.4/packaging`
- `src/compile-3.4.env`, `src/runtime-3.4.env`, `src/gemrc`, `src/overwrite_shebang.rb`
- `src/config/`, `src/patches/`

`tpi release bump-ruby` will **refuse to run** in this state and print instructions.

#### How to revert once upstream has the fix

1. Confirm the fix is present in bosh-package-ruby-release (check that
   `packages/ruby-3.4/packaging` installs/uninstalls the patched gem version).

2. Remove the local source files:

   ```bash
   git rm packages/ruby-3.4/spec packages/ruby-3.4/packaging
   git rm src/compile-3.4.env src/runtime-3.4.env src/gemrc src/overwrite_shebang.rb
   git rm -r src/config src/patches
   git commit -m "chore: revert ruby-3.4 to fingerprint reference (CVE resolved upstream)"
   ```

3. Run the normal update:

   ```bash
   tpi release bump-ruby
   ```

---

### Active patches

#### net-imap 0.5.14 (applied May 2026)

**CVEs addressed:**
- `GHSA-vcgp-9326-pqcp` — STARTTLS stripping vulnerability (critical)
- `GHSA-75xq-5h9v-w6px` — CRLF/command injection via Symbol arguments
- `GHSA-hm49-wcqc-g2xg` — CRLF/command injection via store/setquota/RawData
- `GHSA-q2mw-fvj9-vvcw` — Quadratic time complexity DoS
- `GHSA-87pf-fpwv-p7m7` — SCRAM-* max_iterations DoS

**Background:** Ruby 3.4.9 bundles net-imap 0.5.8. The fixes landed in net-imap
0.5.14 on April 23, 2026 — two days after Ruby 4.0.3 shipped and before Ruby
3.4.10 was released. net-imap is not used by the telemetry CLI; this is a
compliance fix to clear the security scanner.

**Upstream PR:** Submit to cloudfoundry/bosh-package-ruby-release with the same
packaging script change (install net-imap 0.5.14, uninstall 0.5.8).

**Revert trigger:** When bosh-package-ruby-release cuts a release that includes
the net-imap 0.5.14 patch, or when Ruby 3.4.10 ships with net-imap 0.5.14+
baked in and bosh-package-ruby-release updates to it.
