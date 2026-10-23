# Gap Analysis Step-Registry Workflow

This documents the ci-operator **step registry** implementation of the gap-analysis
job ([ROSAENG-15179](https://redhat.atlassian.net/browse/ROSAENG-15179)): the
`scripts/gap-all.sh` job expressed as discrete, independently-runnable,
composable steps in the openshift/release step-registry format.

Source lives at `ci-operator/step-registry/rosa/gap-analysis/` (mirror of the
openshift/release layout, to be contributed upstream).

## Why a step registry

- **Debuggability** — each check is its own ci-operator step with its own pod,
  logs, and exit code, so you can see (and re-run) exactly which check failed.
- **Reusability / composability** — refs can be added, removed, or reordered in
  any workflow; chains bundle them; workflows wire pre/test/post.
- **Clear contracts** — steps exchange state through files, not in-memory globals.

## Steps (refs)

Lifecycle:

| Ref | Phase | Purpose |
|-----|-------|---------|
| `rosa-gap-analysis-setup` | pre | Validate prerequisites (python3/jq), init `${SHARED_DIR}/gap-analysis-reports`, clear stale state |
| `rosa-gap-analysis-ocm-auth` | pre | Validate the OCM token from `${CLUSTER_PROFILE_DIR}/ocm-token`; stage it at `${SHARED_DIR}/ocm-token` for downstream reuse (graceful no-op if absent) |
| `rosa-gap-analysis-resolve-versions` | pre | Resolve `BASELINE`/`TARGET` once; write `${SHARED_DIR}/gap-versions.env` (safe `printf %q`); emit `GAP_SKIP=1` to skip gracefully |
| `rosa-gap-analysis-report` | post | Aggregate per-check reports into the combined HTML/JSON report |
| `rosa-gap-analysis-cleanup` | post | Remove staged secrets/scratch (`ocm-token`, `gap-versions.env`) and analyzer temp dirs |

Checks (one ref per global gap-analysis check; mapping to `scripts/gap-*.py`):

| Ref | Check | Script | Type |
|-----|-------|--------|------|
| `rosa-gap-analysis-aws-sts` | 1-2 | gap-aws-sts.py | standard |
| `rosa-gap-analysis-gcp-wif` | 3-4 | gap-gcp-wif.py | standard |
| `rosa-gap-analysis-ocp-gate-ack` | 5 | gap-ocp-gate-ack.py | standard |
| `rosa-gap-analysis-versions-channels` | 6 | gap-versions-channels.py | standard |
| `rosa-gap-analysis-ocm-version-gate` | 7 | gap-ocm-version-gate.py | standard |
| `rosa-gap-analysis-api-resources` | 9 | gap-api-resources.py | informational |
| `rosa-gap-analysis-critical-alerts-diff` | 10 | gap-critical-alerts.py | informational |
| `rosa-gap-analysis-cluster-install` | 11 | gap-cluster-install.py | informational |
| `rosa-gap-analysis-e2e-validation` | 12 | gap-e2e-validation.py | informational |
| `rosa-gap-analysis-upgrade-e2e` | 13 | gap-upgrade-e2e.py | standard |
| `rosa-gap-analysis-feature-gates` | 8 | gap-feature-gates.py | informational (runs **last**) |

> `critical-alerts-diff` is named to avoid colliding with the existing **capture**
> ref `rosa-gap-analysis-critical-alerts` (see "Capture vs analysis" below).

## Chain and workflow

- **Chain** `rosa-gap-analysis-checks` — all 11 checks in `gap-all.sh` order
  (1-7, then 9-13, feature-gates #8 last). Drop it into any workflow's `test`, or
  inline the refs to add/remove/reorder.
- **Workflow** `rosa-gap-analysis-offline` — the full job with no cluster
  provisioning:
  - `pre`: setup → ocm-auth → resolve-versions
  - `test`: `rosa-gap-analysis-checks` chain
  - `post`: report → cleanup

## Step contract

Steps are configured entirely through environment variables and exchange state
through `${SHARED_DIR}`; artifacts go to `${ARTIFACT_DIR}`.

| Variable | Produced by | Consumed by | Meaning |
|----------|-------------|-------------|---------|
| `${SHARED_DIR}/gap-versions.env` | resolve-versions | checks, report | `GAP_SKIP`, `BASELINE`, `TARGET` (shell-quoted) |
| `${SHARED_DIR}/ocm-token` | ocm-auth | checks | validated OCM token for `ocm login` |
| `${SHARED_DIR}/gap-analysis-reports` | checks | report | per-check JSON/HTML + status files |
| `${ARTIFACT_DIR}` | every step | CI | per-step artifacts + per-step logs |
| `OPENSHIFT_VERSION` / `BASELINE` / `TARGET` | job env | resolve-versions, checks | version inputs (precedence: OPENSHIFT_VERSION > BASELINE+TARGET > auto-detect) |
| `OCM_LOGIN_ENV` | job env | ocm-auth, checks | OCM environment (default `staging`) |

**Exit semantics** map to ci-operator per-step: standard checks exit non-zero on
validation FAIL (failing the step/job); informational checks exit 0 on findings
and non-zero only on execution error; `report` never owns the verdict.
`test` steps are fail-fast — to run every check in one pass and still fail on any
standard FAIL, move the check refs into `post` with `best_effort: false`.

## Running a step independently

Each ref's `commands.sh` defaults `GAP_SCRIPTS_DIR` to the image path
`/gap-analysis/scripts`; override it to run locally against this repo's `scripts/`:

```bash
export GAP_SCRIPTS_DIR="$PWD/scripts"
export SHARED_DIR=$(mktemp -d) ARTIFACT_DIR=$(mktemp -d)
BASELINE=4.21.15 TARGET=4.22.0-rc.3 \
  ci-operator/step-registry/rosa/gap-analysis/resolve-versions/rosa-gap-analysis-resolve-versions-commands.sh
ci-operator/step-registry/rosa/gap-analysis/feature-gates/rosa-gap-analysis-feature-gates-commands.sh
ci-operator/step-registry/rosa/gap-analysis/report/rosa-gap-analysis-report-commands.sh
```

## Image requirement

All refs use `from: gap-analysis` — an image with python3 + the `scripts/gap-*.py`
analyzers (and ideally `ocm`/`rosa` for the OCM/ROSA-backed checks), built from this
repo's `ci/Containerfile`. The consuming ci-operator config must make that image
available (e.g. via `base_images`/`images`). Wiring a ci-operator config/job that
uses `rosa-gap-analysis-offline` is tracked separately.

## Capture vs analysis

The openshift/release `rosa/gap-analysis` registry already contains **capture**
refs (`api-resources-and-crd`, `critical-alerts`, `cluster-install-delete-metrics`)
that snapshot a **live** ROSA cluster in e2e workflows' `post` phase and upload to
Prow GCS. The refs here are the **analysis** side: they read those GCS
snapshots/JUnit (no cluster) and run the gap comparison. The two are complementary
and intentionally distinct.

## Validation

```bash
# shell + yaml/json + naming
shellcheck --severity=error ci-operator/step-registry/rosa/gap-analysis/*/*-commands.sh
# authoritative registry validation (in an openshift/release checkout):
make validate-step-registry   # or run ci-operator-configresolver --registry ... --validate-only
```
