#!/usr/bin/env bash
# step-offline-checks.sh - Workflow step 4: offline gap analysis (no cluster).
#
# Runs the checks that need no live cluster / Prow-snapshot data:
#   aws (1-2), gcp (3-4), ocp (5), versions-channels (6), ocm-version-gate (7).
# Honors the STEPS filter, so individual checks can be run in isolation:
#   REPORT_DIR=/tmp/x BASELINE=4.21.15 TARGET=4.22.0-rc.3 STEPS=aws step-offline-checks.sh
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

log_info "[offline-checks] Baseline=${BASELINE} Target=${TARGET}"

rc=0
run_check_list "${OFFLINE_CHECKS[@]}" || rc=$?
exit $rc
