# Gap Analysis Workflow Architecture

The gap-analysis suite runs as a **workflow of discrete, independently-runnable
steps** instead of a single monolithic script. `gap-all.sh` is now a thin driver
that parses CLI/env and sequences the step scripts in `scripts/steps/`. All
per-check logic lives in the step scripts plus the shared manifest.

This is the implementation of [ROSAENG-15179](https://redhat.atlassian.net/browse/ROSAENG-15179).

## Why

- **Debuggability** — each step runs in isolation and writes its own log, so you
  can identify (and re-run) exactly the step that failed.
- **Composability** — checks can be run individually via `--steps`.
- **Clear contracts** — steps exchange state through files/env, not in-memory
  globals, so any step can be executed standalone.

## Steps

Steps run inside a single container (no cross-container state passing). The driver
runs them in order:

| # | Step script | Responsibility |
|---|-------------|----------------|
| 1 | `steps/step-setup.sh` | Validate prerequisites; create `REPORT_DIR`; clear stale `status-check-*.json`, `result-check-*.rc`, `gap-run.env`. |
| 2 | `steps/step-ocm-auth.sh` | OCM login when credentials are present (graceful no-op otherwise). |
| 3 | `steps/step-resolve-versions.sh` | Resolve `BASELINE`/`TARGET`; write `gap-run.env`. Graceful SKIP when a version can't be resolved. |
| 4 | `steps/step-offline-checks.sh` | Offline checks (no cluster/snapshot): aws (1-2), gcp (3-4), ocp (5), versions-channels (6), ocm-version-gate (7). |
| 5 | `steps/step-live-checks.sh` | Prow-data checks: api-resources (9), critical-alerts (10), cluster-install (11), e2e-validation (12), upgrade-e2e (13), then **feature-gates (8) last**. |
| 6 | `steps/step-report.sh` | Reconstruct status, generate the combined HTML/JSON report, print the summary, and exit with the aggregated job result. |
| 7 | `steps/step-cleanup.sh` | Best-effort removal of analyzer temp dirs (`ocp-crs-*`, `mcc-checkout-*`). |

**Feature Gates ordering:** check #8 (Feature Gates) is offline-data but, per the
long-standing "Feature Gates always executes last" rule, it is appended to the end
of `step-live-checks.sh` so it runs after every other check. It still honors the
`STEPS` filter.

## Shared state & artifacts

- **`${REPORT_DIR}/gap-run.env`** — written by `step-resolve-versions.sh`
  (`BASELINE`, `TARGET`, pullspecs, `GAP_SKIP`). Sourced by the driver and the
  downstream check/report steps. This is what lets each step run standalone.
- **`${REPORT_DIR}/status-check-<num>.json`** — per-check status (written by each
  `gap-*.py`; a FAIL fallback is fabricated by the report step if a check crashed).
- **`${REPORT_DIR}/result-check-<step>.rc`** — each check's process exit code,
  used to aggregate the overall job result.
- **`${ARTIFACT_DIR:-$REPORT_DIR}/step-<name>.log`** — per-step log (separate
  artifact per step).

## Step contract

Steps are configured entirely through environment variables:

| Variable | Used by | Meaning |
|----------|---------|---------|
| `REPORT_DIR` | all | Report/output directory (default `reports`). |
| `BASELINE`, `TARGET` | offline/live/report | Resolved full versions (from env or `gap-run.env`). |
| `STEPS` | offline/live/report | Comma-separated check filter (`""` = all). |
| `VERBOSE` | offline/live | `true` adds `--verbose` to each `gap-*.py`. |
| `VERSION`, `OPENSHIFT_VERSION`, `BASE_VERSION`, `TARGET_VERSION` | resolve-versions | Version-resolution inputs (same precedence as the driver). |
| `OCM_TOKEN` / `OCM_CLIENT_ID` + `OCM_CLIENT_SECRET`, `OCM_URL` | ocm-auth | OCM credentials. |
| `ARTIFACT_DIR` | driver | Where per-step logs are written (default `REPORT_DIR`). |
| `BUILD_LOG`, `job`, `buildid` | report | Optional CI metadata for the combined report / artifact URLs. |

**Exit semantics (unchanged from the monolith):** the job fails (exit 1) iff any
executed check's **process** exited non-zero. Standard checks (1-7, 13) exit 1 on
validation FAIL; informational checks (8-12) exit 0 on validation FAIL and non-zero
only on execution error. `aggregate_job_result` enforces this uniformly from the
`result-check-*.rc` files.

## Running steps independently

```bash
# One check in isolation (no resolver, no auth needed):
REPORT_DIR=/tmp/dbg BASELINE=4.21.15 TARGET=4.22.0-rc.3 STEPS=aws \
  scripts/steps/step-offline-checks.sh

# Resolve versions only and inspect the contract:
REPORT_DIR=/tmp/dbg scripts/steps/step-resolve-versions.sh --version 4.22  # via env VERSION too
VERSION=4.22 REPORT_DIR=/tmp/dbg scripts/steps/step-resolve-versions.sh

# Re-run ONLY report generation against existing artifacts (e.g. downloaded Prow run):
REPORT_DIR=/tmp/prowdl scripts/steps/step-report.sh
```

The full suite is unchanged for callers:

```bash
./scripts/gap-all.sh --version 4.22
./scripts/gap-all.sh --baseline 4.21 --target 4.22 --steps aws,gcp
```

## Shared manifest

`scripts/steps/lib/checks-manifest.sh` is the single source of truth for check
metadata (`CHECK_SCRIPT`, `CHECK_NUM`, `CHECK_DISPLAY_NUM`, `CHECK_NAME`,
`CHECK_TYPE`, `CHECK_COUNT_FIELD`), the ordered check lists (`OFFLINE_CHECKS`,
`LIVE_CHECKS`, `ALL_CHECKS`), and the shared helpers (`should_run_step`,
`run_check`, `read_check_status`, `aggregate_job_result`, `run_check_list`,
`load_run_versions`). **Adding a new check** means adding one row to each manifest
array and placing the step in `OFFLINE_CHECKS` or `LIVE_CHECKS` — no driver change.
