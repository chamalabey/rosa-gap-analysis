#!/usr/bin/env bash
# step-live-checks.sh - Workflow step 5: gap execution against live Prow data.
#
# Runs the checks backed by Prow GCS snapshots / JUnit:
#   api-resources (9), critical-alerts (10), cluster-install (11),
#   e2e-validation (12), upgrade-e2e (13).
# Feature Gates (check #8, informational, offline-data) is appended LAST so the
# documented "Feature Gates always executes last" ordering rule is preserved while
# keeping a single gap-execution step. All checks honor the STEPS filter.
#
# Inputs (env): BASELINE, TARGET (or ${REPORT_DIR}/gap-run.env), REPORT_DIR,
#               STEPS (optional filter), VERBOSE (optional)
# Each check writes status-check-<num>.json and result-check-<step>.rc into REPORT_DIR.
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"
source "${STEP_DIR}/lib/checks-manifest.sh"

REPORT_DIR="${REPORT_DIR:-reports}"
STEPS="${STEPS:-}"

load_run_versions || exit 1

log_info "[live-checks] Baseline=${BASELINE} Target=${TARGET}"

rc=0
run_check_list "${LIVE_CHECKS[@]}" || rc=$?
exit $rc
