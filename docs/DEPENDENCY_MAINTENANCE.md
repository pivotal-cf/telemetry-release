# Dependency Maintenance

## Ruby BOSH Package (`packages/ruby-4.0`)

The `ruby-4.0` package is normally maintained as a **fingerprint reference** to
[cloudfoundry/bosh-package-ruby-release](https://github.com/cloudfoundry/bosh-package-ruby-release).
In that state it contains only `spec.lock` (the package fingerprint) and `VERSION`
(the vendored Ruby version).

### Normal update flow

```bash
tpi release bump-ruby
```

This fetches the latest Ruby 4.0.x version from upstream bosh-package-ruby-release,
runs `bosh vendor-package`, and commits the updated `spec.lock` and `VERSION`.

---

### Emergency gem-level CVE patches

Sometimes a CVE is fixed in a bundled gem before the upstream Ruby release ships.
When that happens, the package must be **promoted to a local source package** so
the packaging script can install the patched gem directly.

This is the current state as of May 2026 (net-imap CVE patch — see below).

#### What "promoted" looks like

Instead of just `spec.lock` + `VERSION`, the package directory also contains:
- `packages/ruby-4.0/spec`
- `packages/ruby-4.0/packaging`
- `src/compile-4.0.env`, `src/runtime-4.0.env`, `src/gemrc`, `src/overwrite_shebang.rb`
- `src/config/`, `src/patches/`

`tpi release bump-ruby` will **refuse to run** in this state and print instructions.

#### How to revert once upstream has the fix

1. Confirm the fix is present in bosh-package-ruby-release (check that
   `packages/ruby-4.0/packaging` installs/uninstalls the patched gem version).

2. Remove the local source files:

   ```bash
   git rm packages/ruby-4.0/spec packages/ruby-4.0/packaging
   git rm src/compile-4.0.env src/runtime-4.0.env
   git rm src/gemrc src/overwrite_shebang.rb
   git rm -r src/config src/patches
   git rm config/blobs.yml   # then restore just the ruby-4.0 lines you added
   git commit -m "chore: revert ruby-4.0 to fingerprint reference (CVE resolved upstream)"
   ```

3. Run the normal update:

   ```bash
   tpi release bump-ruby
   ```

---

### Active patches

#### net-imap 0.6.4 (applied May 2026)

**CVEs addressed:** net-imap CVEs affecting 0.6.2 (the version bundled with Ruby 4.0.4).
See [ruby-advisory-db](https://github.com/rubysec/ruby-advisory-db) for the full list.

**Background:** Ruby 4.0.4 bundles net-imap 0.6.2. net-imap 0.6.4 ships the fixes.
net-imap is not used by the telemetry CLI; this is a compliance fix to clear the
security scanner.

**Upstream PR:** Submit to cloudfoundry/bosh-package-ruby-release with the same
packaging script change (install net-imap 0.6.4, uninstall 0.6.2).

**Revert trigger:** When bosh-package-ruby-release cuts a release that includes
the net-imap 0.6.4 patch, or when a future Ruby 4.0.x ships with net-imap 0.6.4+
baked in and bosh-package-ruby-release updates to it.

---

#### json 2.19.8 (applied June 2026)

**CVEs addressed:** json CVEs affecting 2.18.0 (the version bundled with Ruby 4.0.5).

**Background:** Ruby 4.0.5 bundles json 2.18.0. json 2.19.8 ships the fixes.

**Upstream PR:** Submit to cloudfoundry/bosh-package-ruby-release with the same
packaging script change (install json 2.19.8, uninstall 2.18.0).

**Revert trigger:** When bosh-package-ruby-release cuts a release that includes
the json 2.19.8 patch, or when a future Ruby 4.0.x ships with json 2.19.8+
baked in and bosh-package-ruby-release updates to it.

---

### History

#### net-imap 0.5.14 in ruby-3.4 (applied May 2026, resolved when ruby-3.4 was removed)

Ruby 3.4.x was removed entirely in favour of Ruby 4.0 in May 2026. Prior to removal,
the same CVE-patch pattern was applied to `ruby-3.4`: net-imap 0.5.8 → 0.5.14.
See commits `fb414af` and `65b272e` for that precedent.
