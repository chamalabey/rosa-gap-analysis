#!/usr/bin/env bash
# step-resolve-versions.sh - Workflow step 3: version & channel discovery.
#
# Resolves BASELINE and TARGET using the documented precedence and writes them to
# ${REPORT_DIR}/gap-run.env for the downstream check/report steps to source.
#
# Precedence (highest to lowest):
#   1. VERSION            (--version / single-version auto-resolve)
#   2. OPENSHIFT_VERSION  (env, single-version auto-resolve)
#   3. BASELINE + TARGET  (explicit, both required)
#   4. BASE_VERSION + TARGET_VERSION (env, both required)
#   5. Auto-detect (latest stable baseline -> latest candidate target)
#
# Graceful skip: when a single version cannot be resolved (not in accepted
# streams) or only one z-stream exists, writes GAP_SKIP=1 to gap-run.env and
# exits 0 so the job SKIPs rather than FAILs.
#
# Inputs (env): VERSION, BASELINE, TARGET, OPENSHIFT_VERSION, BASE_VERSION,
#               TARGET_VERSION, REPORT_DIR
# Output: ${REPORT_DIR}/gap-run.env
# Independently runnable: VERSION=4.22 REPORT_DIR=/tmp/x step-resolve-versions.sh
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"
source "${GAP_SCRIPTS_DIR}/lib/openshift-releases.sh"

REPORT_DIR="${REPORT_DIR:-reports}"
mkdir -p "$REPORT_DIR"

VERSION="${VERSION:-}"
BASELINE="${BASELINE:-}"
TARGET="${TARGET:-}"
BASELINE_PULLSPEC=""
TARGET_PULLSPEC=""

RUN_ENV="${REPORT_DIR}/gap-run.env"

# Write a graceful-skip marker and exit 0.
# Values are written with printf %q so the file is safe to `source` even when a
# version/reason contains shell metacharacters (prevents command injection).
write_skip() {
    local reason="$1"
    {
        printf 'GAP_SKIP=1\n'
        printf 'GAP_SKIP_REASON=%q\n' "$reason"
    } > "$RUN_ENV"
    log_warning "[resolve-versions] ${reason} — skipping gap analysis"
    exit 0
}

# Resolve a single version string into "BASELINE TARGET" (or the SKIP sentinel).
# NOTE: the command substitution is guarded with `|| rc=$?` so that a non-zero
# return from resolve_openshift_version does NOT trip `set -e` and bypass the
# intended graceful-skip handling below (previously a monolith bug).
resolve_single_version() {
    local ver="$1"
    local label="$2"
    local rc=0
    local result=""
    log_info "[resolve-versions] Resolving baseline and target from ${label} ${ver}..."
    result=$(resolve_openshift_version "$ver") || rc=$?

    if [[ $rc -ne 0 ]]; then
        write_skip "Version ${ver} not found in accepted streams or not available"
    fi
    if [[ "$result" == "SKIP SKIP" ]]; then
        write_skip "Only one z-stream version available for ${ver}"
    fi

    BASELINE=$(echo "$result" | awk '{print $1}')
    TARGET=$(echo "$result" | awk '{print $2}')
    log_info "[resolve-versions] Resolved from ${label} ${ver}: BASELINE=${BASELINE}, TARGET=${TARGET}"
}

if [[ -n "$VERSION" ]]; then
    resolve_single_version "$VERSION" "--version"

elif [[ -n "${OPENSHIFT_VERSION:-}" ]]; then
    resolve_single_version "$OPENSHIFT_VERSION" "OPENSHIFT_VERSION="

elif [[ -n "$BASELINE" ]] && [[ -n "$TARGET" ]]; then
    # Resolve minor versions to full versions if needed (e.g., 4.21 -> 4.21.15)
    if [[ $(echo "$BASELINE" | tr -cd '.' | wc -c) -eq 1 ]]; then
        log_info "[resolve-versions] Resolving baseline minor version: $BASELINE..."
        BASELINE=$(get_latest_version_baseline_priority "$BASELINE")
        log_info "[resolve-versions] Resolved baseline: $BASELINE"
    fi
    if [[ $(echo "$TARGET" | tr -cd '.' | wc -c) -eq 1 ]]; then
        log_info "[resolve-versions] Resolving target minor version: $TARGET..."
        TARGET=$(get_latest_version_target_priority "$TARGET")
        log_info "[resolve-versions] Resolved target: $TARGET"
    fi
    log_info "[resolve-versions] Using baseline and target from CLI: BASELINE=$BASELINE, TARGET=$TARGET"

elif [[ -n "${BASE_VERSION:-}" ]] && [[ -n "${TARGET_VERSION:-}" ]]; then
    BASELINE="$BASE_VERSION"

    if [[ "${TARGET_VERSION^^}" == "NIGHTLY" ]]; then
        log_info "[resolve-versions] TARGET_VERSION=NIGHTLY detected, using latest dev nightly..."
        TARGET=$(get_latest_dev_nightly_version)
        TARGET_PULLSPEC=$(get_latest_dev_nightly_pullspec)
        log_info "[resolve-versions] Auto-detected nightly target version: $TARGET"
        log_info "[resolve-versions] Auto-detected nightly target pullspec: $TARGET_PULLSPEC"
    elif [[ "${TARGET_VERSION^^}" == "CANDIDATE" ]]; then
        log_info "[resolve-versions] TARGET_VERSION=CANDIDATE detected, using latest candidate..."
        TARGET=$(get_latest_candidate_version)
        TARGET_PULLSPEC=$(get_latest_candidate_pullspec)
        log_info "[resolve-versions] Auto-detected candidate target version: $TARGET"
        log_info "[resolve-versions] Auto-detected candidate target pullspec: $TARGET_PULLSPEC"
    else
        TARGET="$TARGET_VERSION"
    fi

    if [[ $(echo "$BASELINE" | tr -cd '.' | wc -c) -eq 1 ]]; then
        log_info "[resolve-versions] Resolving baseline minor version: $BASELINE..."
        BASELINE=$(get_latest_version_baseline_priority "$BASELINE")
        log_info "[resolve-versions] Resolved baseline: $BASELINE"
    fi
    if [[ $(echo "$TARGET" | tr -cd '.' | wc -c) -eq 1 ]]; then
        log_info "[resolve-versions] Resolving target minor version: $TARGET..."
        TARGET=$(get_latest_version_target_priority "$TARGET")
        log_info "[resolve-versions] Resolved target: $TARGET"
    fi
    log_info "[resolve-versions] Using baseline and target from env vars: BASELINE=$BASELINE, TARGET=$TARGET"

else
    log_info "[resolve-versions] Auto-detecting baseline version from latest stable..."
    BASELINE=$(get_latest_stable_version)
    BASELINE_PULLSPEC=$(get_latest_stable_pullspec)
    log_info "[resolve-versions] Auto-detected baseline version: $BASELINE"
    log_info "[resolve-versions] Auto-detected baseline pullspec: $BASELINE_PULLSPEC"

    baseline_minor=$(extract_version_from_stable "$BASELINE")
    special_target=$(get_special_target_mapping "$baseline_minor")

    if [[ -n "$special_target" ]]; then
        log_info "[resolve-versions] Applying special target mapping: baseline $baseline_minor -> target $special_target"
        TARGET=$(get_latest_version_target_priority "$special_target")
        log_info "[resolve-versions] Auto-detected target version (special mapping): $TARGET"
    else
        log_info "[resolve-versions] Auto-detecting target version from latest candidate..."
        TARGET=$(get_latest_candidate_version)
        TARGET_PULLSPEC=$(get_latest_candidate_pullspec)
        log_info "[resolve-versions] Auto-detected target version: $TARGET"
        log_info "[resolve-versions] Auto-detected target pullspec: $TARGET_PULLSPEC"
    fi
fi

# Persist the resolved contract for downstream steps.
# Use printf %q so each value is shell-quoted and safe to `source`, even if a
# version string contains shell metacharacters (prevents command injection via
# gap-run.env, which the driver and load_run_versions source).
{
    printf 'GAP_SKIP=0\n'
    printf 'BASELINE=%q\n' "$BASELINE"
    printf 'TARGET=%q\n' "$TARGET"
    printf 'BASELINE_PULLSPEC=%q\n' "$BASELINE_PULLSPEC"
    printf 'TARGET_PULLSPEC=%q\n' "$TARGET_PULLSPEC"
} > "$RUN_ENV"

log_success "[resolve-versions] Resolved BASELINE=${BASELINE}, TARGET=${TARGET} -> ${RUN_ENV}"
