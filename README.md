# Telemetry Release

### Note: difference in Xenial branch is with the files in `manifest`

## Overview
The Telemetry System uses an agent job to scrape logs from co-located bosh jobs to find possible telemetry messages. The
identified messages are then forwarded to a centralizer job, which attempts to parse each message and extract the telemetry section
from the message. If the centralizer successfully extracts a telemetry object from the message, then it is logged to the centralizer's
stdout log file.

## SPNEGO Proxy Support

The telemetry-collector and telemetry-centralizer jobs support SPNEGO/Kerberos proxy authentication.

Configuration:
- Properties: `telemetry.proxy_settings.proxy_username/password/domain`
- Requirements: kinit, curl with GSS-API support (included in Ubuntu Jammy)
- Ticket renewal: Ticket caching with on-demand renewal (included in Ubuntu Jammy)

See SPNEGO_OPERATIONS_GUIDE.md in tpi-p-telemetry for detailed documentation.

## Split TAR Output

The telemetry-collector job supports splitting collected data into separate TAR files for different data types.

### Configuration

Set the `telemetry.split_tar_by_data_type` property to `true` to enable this feature:

```yaml
properties:
  telemetry:
    split_tar_by_data_type: true
```

### Behavior

When enabled, the collector creates two TAR files instead of one:

| TAR File | Suffix | Contents |
|----------|--------|----------|
| Operational Data | `_operational` | `usage_service`, `core_consumption`, `serial_numbers` |
| CEIP Data | `_ceip` | `opsmanager` |

Both TAR files share the same `CollectionId` for downstream correlation.

### Backward Compatibility

- Default: `false` (single TAR file, existing behavior)
- When enabled, the send script automatically handles multiple TAR files
- Each TAR file is sent independently; failures are logged but don't block other sends

## Jobs
### telemetry-agent:
- Responsible for collecting and emitting telemetry from components/jobs it is collocated with.

### telemetry-centralizer:
- Receives and centralizes data emitted from agent jobs.

### telemetry-collector: the two collection runs

`bin/telemetry-collect-send` is invoked twice, with a different config file each time.
The difference matters and is easy to break.

| When | Config file | Contents | If `collect` exits non-zero |
|------|-------------|----------|-----------------------------|
| Once per deploy, from `bin/pre-start` | `config/pre-start-collect.yml` | Ops Manager config only. **No** usage service keys, and **no** `data-collection-multi-select-options`. | `bin/pre-start` fails, so the BOSH job fails, so **`apply changes` fails** |
| On the `schedule` property, from the cron entry. **Default `random`, which is once a day** at a random hour and minute | `config/collect.yml` | Everything, including usage service config when TAS is staged | That run fails and retries on the next scheduled run |

Two rules that follow from this:

- **`pre-start-collect.yml` must not carry `data-collection-multi-select-options`.**
  That run cannot collect operational data, so saying the operator selected it is
  untrue, and it makes the collector's "operational data selected but no usage service
  config" check fire on every apply-changes. There is a longer comment in
  `pre-start-collect.yml.erb` and a spec pinning it in
  `spec/jobs/telemetry_collector_collect_yml_spec.rb`.
- **The script works from a copy, never the rendered file.**
  `create_or_update_options` and `set_spnego_enabled_flag` both rewrite the file handed
  to them. The rendered config belongs to BOSH. The script used to `sed -i` it directly
  and permanently delete the usage service keys, which left the collector reading a file
  that no longer matched the deployment.

  The copy goes to `/var/vcap/data/tmp/telemetry-collector`, mode 700, and the file
  itself is created 0600 before anything is copied into it. It is a verbatim copy of the
  rendered config, so it holds the Ops Manager password and the usage service client
  secret. Two places it must not go:

  - not `/tmp`, which any user on the VM can list, and the `EXIT` trap does not run on
    `SIGKILL`
  - not `/var/vcap/data/telemetry-collector`, this job's own data directory, because
    that is a **handoff point between products**. The collector writes its TAR files
    there and a consumer picks them up. Do not put anything in it that is not a TAR.

    Concretely, `hub-tas-agent` bind-mounts that directory into its own bpm container
    (`shared: true`, `writable: false`) and watches it. It would not have *read* our
    working copy -- its `fsnotify` watch is non-recursive and its filter requires the
    `FoundationDetails_` prefix, so a subdirectory and a `.yml` inside it are both
    ignored -- but there is no reason to put a file holding the Ops Manager password
    and the usage service client secret inside another product's mount. Keep it out.

## Known consumers of this release

Anything that colocates the `telemetry-collector` job inherits the two rules above.
Check this list before changing how the job is invoked or what it writes where.

| Tile | Pins | How it uses the collector |
|---|---|---|
| `tpi-p-telemetry` (Telemetry tile) | tracks this repo | Normal path. Operator picks the data programs on the form. Sends. |
| `platform-services-tile` | `telemetry` **2.4.12**, pinned in `Kilnfile.lock` | Colocates the job on its `hub_tas_agent` instance group. `audit_mode: true`, so it never sends — it writes TARs to `/var/vcap/data/telemetry-collector` and `hub-tas-agent` collects them. `split_tar_by_data_type: true`. Hardcodes `data_collection_multi_select_options` to **both** `operational_data` and `ceip_data`; there is no form for it. |

Two things to know about `platform-services-tile` specifically:

- **It pins a released version**, so changes here do not reach it until someone bumps
  that pin. The CLI ships inside this release, so the script and the collector binary
  always move together — there is no way to get a new collector with an old script.
- **It always asks for operational data.** So the collector's "operational data was
  selected but no usage service config arrived" warning is live for that tile. It stays
  quiet in normal operation, because when `cf` is present the usage service values are
  real, and when `cf` is absent this script strips the keys and the collector finds no
  `cf` product to complain about. It fires only in the genuinely broken state, which is
  the point.

There is at least one more consumer that has never been identified. If you find it, add
it here.

### The TAR handoff contract, and where it is thin

`hub-tas-agent` reads our output like this (`src/pkg/core/product-consumption-reporter/`):

- at startup it globs `FoundationDetails_*_operational.tar` and `FoundationDetails_*_ceip.tar`
- then it watches the directory with `fsnotify`, added via `w.Add(dir)` — **not recursive**
  — and reacts only to `Create` events prefixed `<dir>/FoundationDetails_` and not ending
  in `.partial`
- it waits 5 seconds after the last event before sending, to let the write settle
- it never reads `collect.yml`

So the contract we have to keep is narrow and we already keep it: write
`FoundationDetails_*_{operational,ceip}.tar` into that directory, build them as
`.partial` and rename, and put nothing else in there.

**The thin part is cleanup.** `hub-tas-agent` never deletes what it consumed, and cannot
— its mount is `writable: false`. So this script deletes the previous run's TARs at the
top of every run, and there is no signal telling us whether the file we are deleting was
ever sent. If `hub-tas-agent` is down for longer than one collection interval, the next
run deletes an unsent TAR.

That is survivable, and it is not something we can fix from this side:

- the TAR is a point-in-time snapshot, not a delta, so the next one largely supersedes a
  lost one
- `hub-tas-agent` re-globs on startup, so being down briefly loses nothing
- an in-flight send is unaffected by our `rm`, because unlinking an open file on Linux
  does not disturb the reader
- not deleting is worse: the TARs would accumulate on a shared ephemeral disk forever

Two things on the consumer side would close it properly, and both are theirs to make:

1. **A failed send is never retried.** `sendFileWithTimeout` logs the error and returns.
   The file is only re-attempted if a new TAR appears or the agent restarts.
2. **The send timeout is a fixed 1 minute.** A TAR that grows past what the link can
   transfer in 60 seconds would fail on every single run, forever, and nothing would
   raise an alarm.

Of the two, the missing retry matters more than the delete race.

### Running the specs

```bash
rspec
```

`bundle exec rspec` does not currently work — the committed `Gemfile.lock` cannot
resolve on a recent Ruby. Nothing in the build runs these specs, so run them by hand.

## GCS Blobstore & Resource Allocation

The BOSH release blobstore and binary distributions are stored in GCP project `dtnz01-tpe-titan01` and tagged with standard cost allocation labels:
- **BOSH Release Blobstore Bucket:** `gs://tpi-telemetry-release-blobs` (`system=artifact-distribution`, `environment=production`, `component-type=storage-bucket`, `workload-name=bosh-release`)
- **CLI Release Source Bucket:** `gs://tpi-telemetry-cli-production-builds` (`system=artifact-distribution`, `environment=production`, `component-type=storage-bucket`, `workload-name=cli-release`)

See `tpi-meta/docs/GCP_RESOURCE_INVENTORY.md` for full ecosystem resource inventory and billing query examples.

## How a finalized release gets into Artifactory

After you finalize a release (tag it and create a GitHub release), an external
Concourse pipeline picks it up, builds it, and pushes it to internal Artifactory
(`tas-ecosystem-generic-prod-local/compiled-releases/`). This is not run by
this repo's own GitHub Actions — it is owned by the `tas-ecosystem` team.

**Where to check it:** the pipeline is `bosh-releases` on the `tas-ecosystem`
Concourse team. The three jobs for this release are:
- `ingest-telemetry_main` — reads the release's blobs out of GCS and uploads
  the raw release tarball to Artifactory. This is the job that fetches from
  `gs://tpi-telemetry-release-blobs`.
- `scan-telemetry_main` — security scan of the uploaded tarball.
- `compile-telemetry_main` — compiles the release against a stemcell and
  uploads the compiled release to Artifactory. This job and the scan job pull
  the tarball from Artifactory, not from GCS.

Job URL (bookmark this):
`https://tpe-concourse-rock.acc.broadcom.net/teams/tas-ecosystem/pipelines/bosh-releases/jobs/ingest-telemetry_main`

If a release doesn't show up in Artifactory a few minutes after finalizing,
check that job first — it fails fast (under two minutes) rather than hanging.

**What the ingest job needs from GCP:** it authenticates as
`tnz-bosh@ltnz001-tas-be.iam.gserviceaccount.com` and needs read access
(`storage.objects.get`/`.list` — i.e. `roles/storage.objectViewer`) to
`gs://tpi-telemetry-release-blobs` in project `dtnz01-tpe-titan01`. It does
not need write access, and it does not need access to any other bucket in
this project (the CLI build buckets and `tpi-p-telemetry`'s bucket are for
repos that aren't bosh releases, so this job never touches them).

**If this bucket is ever deleted and recreated, this permission always has to
be re-granted, no matter what.** This is true even if the new bucket has the
exact same name, in the exact same region. A bucket's IAM policy is attached
to the bucket resource itself, not its name — deleting the bucket destroys
that policy for good, and a new bucket (even a same-named one) starts with a
blank slate. This isn't specific to the org policy below; it would be true
regardless.

Separately, `dtnz01-tpe-titan01` has a Domain Restricted Sharing org policy
that blocks adding IAM members from outside an allow-list of Cloud Identity
customer IDs. This is what actually stopped us in August 2026 — not the
re-grant step itself (expected), but the fact that re-doing it hit this
policy for the first time. The original grant, made years before this policy
existed (or before it was enforced this strictly), had kept working the whole
time — org policies like this block *new* bindings, they don't retroactively
undo old ones. Once `ltnz001-tas-be`'s customer ID (or a scoped exception for
this one service account) is added to the allow-list, that blocker goes away
for good, and any future re-grant (after another bucket recreation, say) can
be done directly with the command below — no support ticket needed:

```
gcloud storage buckets add-iam-policy-binding gs://tpi-telemetry-release-blobs \
  --member="serviceAccount:tnz-bosh@ltnz001-tas-be.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"
```

The owner on record for our project (`dtnz01-tpe-titan01`) is
**Satish Zanjurne** (`satish.zanjurne@broadcom.com`) — he's listed as
`project-owner-email` in the project's own GCP labels, and as the requestor
on the ServiceNow ticket that created it (`ritm0466201`). He is not on the
`tas-ecosystem`/CI side — he owns the project whose org policy is doing the
blocking, i.e. our side, not the side that needs the access. If a support
ticket about this org policy needs a name to start with, he's it.

Org policy changes like this one are handled by Cloud Platform Engineering
(CPE), not the normal IT support portal. File the request at
`https://brdcmitsm-cloudops.wolkenservicedesk.com/`.

For reference, here are the five blob objects (by their GCS object ID, not
their bosh blob name) that build #51 of `ingest-telemetry_main` failed to
read during the August 2026 incident, before the permission was fixed:
- `f5ad4bd2-a6f8-47c7-7b5d-7f21e89be4f2` (9,147 bytes)
- `1ce9ab5b-688e-4aa5-7079-d0a39cfc982f` (3,857 bytes)
- `fa2199cf-7031-4a7f-4a4a-7005726ccfa7` (3,833,068 bytes)
- `5ed0477e-8041-464c-49d3-66b4c8f5ad05` (2,191 bytes)
- `c4eb0cf3-c8ac-4257-76f6-5a9d194ded94` (43,552,682 bytes)

These correspond to the `telemetry-agent`, `telemetry-collector`,
`telemetry-centralizer`, `fluentd`, and `fluent-bit` blobs. The object IDs are
generated per upload and will be different for future releases — they're
recorded here only as a worked example of what "the ingest job's blobs" means
in practice, and to make old incident logs easier to cross-check.

## Required Message Format in Logs
Message must contain a JSON object (or one encoded as a string) with these fields:
  - `telemetry-source`: [string] The source name for the telemetry data
  - `telemetry-time`: [string] Time formatted in RFC3339

The message may contain additional key(s) which conform to the following:
  - key names may not begin with `telemetry`
  - values must be objects

Additionally, log messages may not contain the substrings `"telemetry-source"` or `\"telemetry-source\"` except as specified above.

Because your ability to log specific kinds of messages may vary depending on your technology choices, the telemetry system recognizes
messages in a variety of formats. Use the format that best suits your existing logging facility.

**Valid log message formats:**

Let's say your source is `my-component` and you want to log a message type `create-instance` with data `{ "cluster-size": 42, "cool-feature-enabled": true }`.

A) Message is exactly the telemetry message
```
{ "telemetry-source": "my-component","telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true }}
```

B) Message is embedded as a string value in a JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "{\"create-instance\": { \"cluster-size\": 42, \"cool-feature-enabled\": true}, \"telemetry-source\": \"my-component\", \"telemetry-time\": \"2009-11-10T23:00:00Z\"}"}
```

C) Message is embedded as a JSON object within another JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "whatever", "data": { "something": "else", "telemetry-thing": { "telemetry-source": "my-component", "telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true } }, "more": "otherthings"} }
```

D) Message is embedded in a text log message
```
Tue 14-Mar-2019 [Thread-14] com.java.SomeClassThatLogs myhostname {"telemetry-source": "my-component", "telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true }} maybe some junk here
```

## Recommendations for telemetry messages

#### Use distinct key names
Your data may be processed at a later stage using technologies which have naming constraints (e.g. SQL). In this case keys could potentially be the names of tables or columns, so if they are similar, they could cause unintended collisions. For example:
- they will be transformed (e.g. `key-name` might become `key_name`)
- they will be treated case-insensitively (e.g. `FOO` will be equivalent to `foo`).

These collisions could cause undefined behavior when your telemetry data is processed. Because of this, take care to name your keys distinctly.


## Requirements
- The telemetry-agent must be colocated in the same instance group as your job
- Your job must either be owned by vcap or run with bpm for the agent to be able to scrape your log files

## How to Deploy
See [centralizer](https://github.com/pivotal-cf/telemetry-release/blob/main/manifest/centralizer.yml) and [agent](https://github.com/pivotal-cf/telemetry-release/blob/main/manifest/agent.yml) manifests for how we deploy the agent and centralizer in separate deployments.
