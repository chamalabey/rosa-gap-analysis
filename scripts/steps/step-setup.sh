#!/usr/bin/env bash
# step-setup.sh - Workflow step 1: environment setup and prerequisite validation.
#
# Validates required tooling, creates the report directory, and clears stale
# per-run state (status-check-*.json, result-check-*.rc, gap-run.env) so a reused
# REPORT_DIR cannot surface data from a previous run.
#
# Inputs (env): REPORT_DIR (default: reports)
# Independently runnable: REPORT_DIR=/tmp/x step-setup.sh
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"

REPORT_DIR="${REPORT_DIR:-reports}"

log_info "[setup] Validating prerequisites..."

# Hard requirements - always needed by the workflow itself.
missing=0
for cmd in python3 jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "[setup] Required command not found: ${cmd}"
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    log_error "[setup] Missing required tooling; cannot continue."
    exit 1
fi

# Optional tooling - individual checks degrade gracefully when these are absent.
for cmd in oc rosa ocm gcloud git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_warning "[setup] Optional command not found: ${cmd} (dependent checks may SKIP/WARN)"
    fi
done

log_info "[setup] Preparing report directory: ${REPORT_DIR}"
mkdir -p "$REPORT_DIR"

# Clear stale per-run state.
rm -f "${REPORT_DIR}"/status-check-*.json
rm -f "${REPORT_DIR}"/result-check-*.rc
rm -f "${REPORT_DIR}/gap-run.env"

log_success "[setup] Environment ready."
