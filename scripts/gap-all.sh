#!/usr/bin/env bash
# Run all gap analyses.
#
# Thin orchestrator: parses CLI/env, then drives the discrete workflow steps in
# scripts/steps/ (each independently runnable; see docs/workflow-architecture.md):
#   1 setup -> 2 ocm-auth -> 3 resolve-versions -> 4 offline-checks
#   -> 5 live-checks -> 6 report -> 7 cleanup
# All per-check logic lives in the step scripts + scripts/steps/lib/checks-manifest.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/steps"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${STEPS_DIR}/lib/checks-manifest.sh"   # provides ALL_CHECKS (step validation)

BASELINE=""
TARGET=""
VERSION=""
VERBOSE=false
DRY_RUN=false
REPORT_DIR="${REPORT_DIR:-reports}"
STEPS=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run gap analysis between two OpenShift versions for both AWS and GCP platforms.
Validates target version structure in managed-cluster-config repository.
Exits 1 if target version validation fails (FAIL), exits 0 if validation passes (PASS).

Optional Arguments:
  --baseline <version>     Baseline version (must be used with --target)
  --target <version>       Target version (must be used with --baseline)
  --version <version>      Single version to analyze (auto-resolves baseline and target)
  --steps <steps>          Comma-separated list of steps to run (default: all)
                           Available: aws,gcp,ocp,versions-channels,ocm-version-gate,api-resources,critical-alerts,cluster-install,e2e-validation,upgrade-e2e,feature-gates
                           Example: --steps aws,gcp (runs only AWS and GCP)
                           Example: --steps api-resources (runs only API Resources and CRD comparison)
                           Example: --steps critical-alerts (runs only Critical Alerts Diff Validation)
                           Example: --steps cluster-install (runs only Cluster Install and Delete Validation)
                           Example: --steps e2e-validation (runs only Target E2E Validation and alert monitoring)
                           Example: --steps upgrade-e2e (runs only Upgrade Validation from Y-1 to Y with E2E Tests)
  --dry-run                Show resolved versions and exit without running analysis
  --verbose                Enable verbose logging
  --report-dir <path>      Directory to store reports (default: reports/)
  -h, --help               Show this help

Note: You must use either:
  - --version <version>              (auto-resolve baseline and target)
  - --baseline <ver> --target <ver>  (explicit control, both required)

Environment Variables:
  BASE_VERSION            Baseline version (must be used with TARGET_VERSION)
  TARGET_VERSION          Target version (must be used with BASE_VERSION)
                          Special values: NIGHTLY (dev nightly), CANDIDATE (dev candidate)
  OPENSHIFT_VERSION       Single version to analyze (auto-resolves baseline and target)
  REPORT_DIR              Directory to store reports (default: reports/)
  ARTIFACT_DIR            Directory for per-step logs (default: REPORT_DIR)

Version Resolution Precedence (highest to lowest):
  1. --version flag (auto-resolve baseline and target)
  2. OPENSHIFT_VERSION env var (auto-resolve baseline and target)
  3. --baseline AND --target flags (explicit control, both required)
  4. BASE_VERSION AND TARGET_VERSION env vars (explicit control, both required)
  5. Auto-detected (latest stable for baseline, latest candidate for target)

Single Version Resolution (--version or OPENSHIFT_VERSION):
  For GA or older versions (<= current GA):
    - Compares within same minor version (z-stream comparison)
    - BASE = previous z-stream, TARGET = latest z-stream
    - Example: --version 4.19 -> BASE=4.19.21, TARGET=4.19.22

  For pre-GA versions (> current GA):
    - Compares across minor versions
    - BASE = latest from (version-1) using baseline precedence (stable > candidate > CI > nightly)
    - TARGET = latest for version using target precedence (candidate > CI > nightly)
    - Example: --version 4.23 -> BASE=4.22.x (candidate), TARGET=4.23.0-rc.0 (candidate if available)

Examples:
  # Auto-detect versions (stable -> candidate)
  $0

  # Single version (auto-resolve baseline and target) - RECOMMENDED
  $0 --version 4.21          # GA version: z-stream comparison (4.21.14 vs 4.21.15)
  $0 --version 4.22          # Pre-GA: cross-minor (4.21.15 vs 4.22.0-rc.3)
  $0 --version 4.19          # Older GA: z-stream comparison (4.19.21 vs 4.19.22)

  # Explicit baseline and target (both required)
  $0 --baseline 4.21 --target 4.22
  $0 --baseline 4.21.6 --target 4.22.0-ec.3 --verbose

  # Run specific steps only
  $0 --version 4.22 --steps aws,gcp         # Only AWS and GCP
  $0 --baseline 4.21 --target 4.22 --steps aws  # Only AWS
  $0 --steps feature-gates                  # Only Feature Gates (auto-detect versions)

  # Dry-run mode (show versions without running analysis)
  $0 --version 4.21 --dry-run
  $0 --baseline 4.21 --target 4.22 --dry-run
  $0 --dry-run               # Show auto-detected versions

  # Using environment variables
  OPENSHIFT_VERSION=4.22 $0                        # Same as --version 4.22
  BASE_VERSION=4.21.5 TARGET_VERSION=4.22.0-ec.2 $0  # Both required
  BASE_VERSION=4.21 TARGET_VERSION=NIGHTLY $0      # Nightly target

Exit Codes:
  0 - All checks passed (PASS)
  1 - One or more checks failed (FAIL) OR execution failure

EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline) BASELINE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --steps) STEPS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --report-dir) REPORT_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate flag combinations.
if [[ -n "$VERSION" ]] && { [[ -n "$BASELINE" ]] || [[ -n "$TARGET" ]]; }; then
    log_error "Cannot use --version together with --baseline or --target"
    log_error "Use either:"
    log_error "  --version <version>              (auto-resolve baseline and target)"
    log_error "  --baseline <ver> --target <ver>  (explicit control)"
    exit 1
fi
if { [[ -n "$BASELINE" ]] && [[ -z "$TARGET" ]]; } || { [[ -z "$BASELINE" ]] && [[ -n "$TARGET" ]]; }; then
    if [[ -n "$BASELINE" ]]; then
        log_error "Cannot use --baseline without --target"
    else
        log_error "Cannot use --target without --baseline"
    fi
    log_error "Use either:"
    log_error "  --version <version>              (auto-resolve baseline and target)"
    log_error "  --baseline <ver> --target <ver>  (explicit control)"
    exit 1
fi

# Validate --steps values.
if [[ -n "$STEPS" ]]; then
    IFS=',' read -ra _steps_arr <<< "$STEPS"
    for step in "${_steps_arr[@]}"; do
        step="$(echo "$step" | xargs)"
        if ! printf '%s\n' "${ALL_CHECKS[@]}" | grep -qx "$step"; then
            log_error "Invalid step: $step"
            log_error "Valid steps are: ${ALL_CHECKS[*]}"
            exit 1
        fi
    done
    log_info "Steps to run: ${STEPS}"
fi

# Export configuration consumed by the step scripts.
export REPORT_DIR STEPS VERBOSE VERSION BASELINE TARGET
# GAP_FULL_REPORT: default on (per-check JSON only, combined report provides HTML).
if [[ "${GAP_FULL_REPORT:-1}" == "0" ]]; then
    unset GAP_FULL_REPORT
else
    export GAP_FULL_REPORT=1
fi

START_TIME=$(date +%s)
START_TIME_FORMATTED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
export START_TIME START_TIME_FORMATTED

LOG_DIR="${ARTIFACT_DIR:-$REPORT_DIR}"
mkdir -p "$LOG_DIR"

# run_step <name> <script> : run a step, tee its output to a per-step log, and
# return the step's exit code (not tee's). Does not abort on failure.
run_step() {
    local name="$1" script="$2"
    local log="${LOG_DIR}/step-${name}.log"
    local rc=0
    log_info ""
    log_info ">>> STEP: ${name}"
    set +e
    "${STEPS_DIR}/${script}" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    return $rc
}

# --- Dry-run: resolve versions only, print, and exit. ---
if [[ "$DRY_RUN" == "true" ]]; then
    run_step resolve-versions step-resolve-versions.sh || { log_error "Version resolution failed"; exit 1; }
    # shellcheck disable=SC1091
    source "${REPORT_DIR}/gap-run.env"
    if [[ "${GAP_SKIP:-0}" == "1" ]]; then
        exit 0
    fi
    log_info ""
    log_info "========================================="
    log_info "  Dry-Run Mode (Version Resolution Only)"
    log_info "========================================="
    log_success "Baseline: $BASELINE"
    log_success "Target:   $TARGET"
    [[ -n "${BASELINE_PULLSPEC:-}" ]] && log_info "Baseline pullspec: $BASELINE_PULLSPEC"
    [[ -n "${TARGET_PULLSPEC:-}" ]] && log_info "Target pullspec: $TARGET_PULLSPEC"
    if [[ -n "$STEPS" ]]; then
        log_info "Steps to run: ${STEPS}"
    else
        log_info "Steps to run: all (${ALL_CHECKS[*]})"
    fi
    log_info "========================================="
    log_info "Exiting without running gap analysis"
    exit 0
fi

# --- Full workflow. ---
run_step setup step-setup.sh || { log_error "Setup step failed"; exit 1; }
run_step ocm-auth step-ocm-auth.sh || { log_error "OCM authentication failed"; exit 1; }
run_step resolve-versions step-resolve-versions.sh || { log_error "Version resolution failed"; exit 1; }

# Load resolved versions; honor graceful skip.
# shellcheck disable=SC1091
source "${REPORT_DIR}/gap-run.env"
if [[ "${GAP_SKIP:-0}" == "1" ]]; then
    run_step cleanup step-cleanup.sh || true
    exit 0
fi
export BASELINE TARGET

log_info "========================================="
log_info "  OpenShift Gap Analysis Suite"
log_info "========================================="
log_info "Baseline: $BASELINE"
log_info "Target:   $TARGET"
log_info "Report Directory: $REPORT_DIR"
log_info "========================================="

run_step offline-checks step-offline-checks.sh || true
run_step live-checks step-live-checks.sh || true

report_rc=0
run_step report step-report.sh || report_rc=$?

run_step cleanup step-cleanup.sh || true

exit $report_rc
