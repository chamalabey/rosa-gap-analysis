#!/usr/bin/env bash
# checks-manifest.sh - Single source of truth for gap-analysis check metadata.
#
# Sourced by the workflow step scripts (scripts/steps/*.sh) and by the thin
# gap-all.sh driver. Defines the ordered check lists, per-check metadata, and the
# shared helpers used to run a check and read its status file.
#
# This replaces the per-check `declare -A` blocks and the duplicated per-check
# execution blocks that previously lived inline in gap-all.sh.
#
# Contract: callers set the following environment before using run_check /
# read_check_status:
#   BASELINE, TARGET   - resolved full versions
#   REPORT_DIR         - directory for reports, status-check-*.json, result-*.rc
#   STEPS              - comma-separated step filter ("" = run all)
#   VERBOSE_FLAG       - "--verbose" or "" (optional)

# Resolve the directory containing the gap-*.py scripts (scripts/).
# checks-manifest.sh lives in scripts/steps/lib, so scripts/ is two levels up.
GAP_SCRIPTS_DIR="${GAP_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ---------------------------------------------------------------------------
# Ordered check lists
# ---------------------------------------------------------------------------
# OFFLINE_CHECKS: no live cluster / Prow-snapshot data required (checks 1,2,3,6,7).
# LIVE_CHECKS:    Prow GCS snapshot / JUnit data (checks 9-13), with feature-gates
#                 (check #8, informational, offline-data) appended LAST so the
#                 documented "Feature Gates always executes last" rule is preserved
#                 while keeping exactly one "live/gap execution" step.
# ALL_CHECKS:     canonical execution + reporting order (offline then live).
OFFLINE_CHECKS=(aws gcp ocp versions-channels ocm-version-gate)
LIVE_CHECKS=(api-resources critical-alerts cluster-install e2e-validation upgrade-e2e feature-gates)
ALL_CHECKS=("${OFFLINE_CHECKS[@]}" "${LIVE_CHECKS[@]}")

# Valid --steps values (for driver validation).
VALID_STEPS="${ALL_CHECKS[*]}"

# ---------------------------------------------------------------------------
# Per-check metadata (keyed by step name)
# ---------------------------------------------------------------------------
declare -gA CHECK_SCRIPT=(
    ["aws"]="gap-aws-sts.py"
    ["gcp"]="gap-gcp-wif.py"
    ["ocp"]="gap-ocp-gate-ack.py"
    ["versions-channels"]="gap-versions-channels.py"
    ["ocm-version-gate"]="gap-ocm-version-gate.py"
    ["api-resources"]="gap-api-resources.py"
    ["critical-alerts"]="gap-critical-alerts.py"
    ["cluster-install"]="gap-cluster-install.py"
    ["e2e-validation"]="gap-e2e-validation.py"
    ["upgrade-e2e"]="gap-upgrade-e2e.py"
    ["feature-gates"]="gap-feature-gates.py"
)

# Global check number (used for status-check-<num>.json file naming).
declare -gA CHECK_NUM=(
    ["aws"]=1
    ["gcp"]=2
    ["ocp"]=3
    ["versions-channels"]=6
    ["ocm-version-gate"]=7
    ["api-resources"]=9
    ["critical-alerts"]=10
    ["cluster-install"]=11
    ["e2e-validation"]=12
    ["upgrade-e2e"]=13
    ["feature-gates"]=8
)

# Display number (human-facing; aws/gcp each cover two global checks).
declare -gA CHECK_DISPLAY_NUM=(
    ["aws"]="1-2"
    ["gcp"]="3-4"
    ["ocp"]=5
    ["versions-channels"]=6
    ["ocm-version-gate"]=7
    ["api-resources"]=9
    ["critical-alerts"]=10
    ["cluster-install"]=11
    ["e2e-validation"]=12
    ["upgrade-e2e"]=13
    ["feature-gates"]=8
)

declare -gA CHECK_NAME=(
    ["aws"]="AWS STS Policy Gap"
    ["gcp"]="GCP WIF Template Gap"
    ["ocp"]="OCP Admin Gate Acknowledgments"
    ["ocm-version-gate"]="OCM Version Gates"
    ["versions-channels"]="Versions & Channels"
    ["api-resources"]="API Resources and CRD Diff Validation"
    ["critical-alerts"]="Critical Alerts Diff Validation"
    ["cluster-install"]="Cluster Install and Delete Validation"
    ["e2e-validation"]="Target E2E Validation and alert monitoring"
    ["upgrade-e2e"]="Upgrade Validation from Y-1 to Y with E2E Tests"
    ["feature-gates"]="Feature Gates Gap"
)

# standard -> non-zero process exit FAILs the job; informational -> validation
# FAIL still exits 0 (only execution errors exit non-zero). Note: this affects
# only summary display; job exit is driven uniformly by the per-check process
# exit code (see aggregate_job_result).
declare -gA CHECK_TYPE=(
    ["aws"]="standard"
    ["gcp"]="standard"
    ["ocp"]="standard"
    ["versions-channels"]="standard"
    ["ocm-version-gate"]="standard"
    ["api-resources"]="informational"
    ["critical-alerts"]="informational"
    ["cluster-install"]="informational"
    ["e2e-validation"]="informational"
    ["upgrade-e2e"]="standard"
    ["feature-gates"]="informational"
)

declare -gA CHECK_COUNT_FIELD=(
    ["aws"]="differences_count"
    ["gcp"]="differences_count"
    ["ocp"]="gates_count"
    ["ocm-version-gate"]="gates_count"
    ["versions-channels"]=""
    ["api-resources"]="differences_count"
    ["critical-alerts"]="differences_count"
    ["cluster-install"]="differences_count"
    ["e2e-validation"]="differences_count"
    ["upgrade-e2e"]="differences_count"
    ["feature-gates"]="total_changes"
)

# Populated by read_check_status (used by the report step for the summary).
declare -gA CHECK_RESULT=()
declare -gA CHECK_STATUS=()
declare -gA CHECK_MESSAGE=()
declare -gA CHECK_DIFF_COUNT=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# should_run_step <step> : returns 0 if the step should run given the STEPS filter.
# Empty STEPS means "run all".
should_run_step() {
    local step_name="$1"
    local steps_filter="${STEPS:-}"
    if [[ -z "$steps_filter" ]]; then
        return 0
    fi
    local s
    IFS=',' read -ra _srs_arr <<< "$steps_filter"
    for s in "${_srs_arr[@]}"; do
        # trim surrounding whitespace
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        if [[ "$s" == "$step_name" ]]; then
            return 0
        fi
    done
    return 1
}

# run_check <step> : run one gap-*.py check, honoring the STEPS filter.
# Records the process exit code to result-check-<step>.rc so the report step and
# driver can aggregate the job result. Never aborts the caller (does not rely on
# set -e); always returns 0 so a failing check does not stop the sequence.
run_check() {
    local step="$1"
    should_run_step "$step" || return 0

    local script="${CHECK_SCRIPT[$step]}"
    local name="${CHECK_NAME[$step]}"
    local rc=0

    log_info ""
    log_info "Running ${name}..."
    python3 "${GAP_SCRIPTS_DIR}/${script}" \
        --baseline "$BASELINE" \
        --target "$TARGET" \
        --report-dir "$REPORT_DIR" \
        ${VERBOSE_FLAG:-} 2>&1 || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "${name} script failed with exit code ${rc}"
    fi

    echo "$rc" > "${REPORT_DIR}/result-check-${step}.rc"
    return 0
}

# read_check_status <step> : populate CHECK_RESULT/STATUS/MESSAGE/DIFF_COUNT from
# the per-check result file and status-check-<num>.json. If the status file is
# missing (script crashed before writing one), fabricate a FAIL status file so the
# combined report still has parseable input (same behavior as the old monolith).
read_check_status() {
    local step="$1"
    local num="${CHECK_NUM[$step]}"
    local count_field="${CHECK_COUNT_FIELD[$step]}"
    local status_file="${REPORT_DIR}/status-check-${num}.json"
    local rc_file="${REPORT_DIR}/result-check-${step}.rc"

    # Process (execution) result: non-zero exit = execution failure for this check.
    if [[ -f "$rc_file" ]]; then
        CHECK_RESULT[$step]="$(cat "$rc_file" 2>/dev/null || echo 0)"
    else
        # No result file: a should-run check that produced no execution record did
        # not complete -> treat as a failure (consistent with the fabricated FAIL
        # status below and the old monolith's crashed-check semantics).
        CHECK_RESULT[$step]=1
    fi

    if [[ -f "$status_file" ]]; then
        CHECK_STATUS[$step]=$(jq -r '.status' "$status_file" 2>/dev/null || echo "UNKNOWN")
        local message
        message=$(jq -r '.details.message // "status unavailable"' "$status_file" 2>/dev/null || echo "status unavailable")
        local first_error
        first_error=$(jq -r '.details.errors[0] // empty' "$status_file" 2>/dev/null || true)
        if [[ -n "$first_error" && "$message" != *"$first_error"* ]]; then
            message="${message} (${first_error})"
        fi
        CHECK_MESSAGE[$step]="$message"
        if [[ -n "$count_field" ]]; then
            CHECK_DIFF_COUNT[$step]=$(jq -r ".details.${count_field} // 0" "$status_file" 2>/dev/null || echo "0")
        else
            CHECK_DIFF_COUNT[$step]=0
        fi
    else
        # Create fallback status file so subsequent layers (combined report) can parse it.
        local name="${CHECK_NAME[$step]}"
        CHECK_STATUS[$step]="FAIL"
        CHECK_MESSAGE[$step]="Script execution failed or crashed"
        CHECK_DIFF_COUNT[$step]=1

        cat <<EOF > "$status_file"
{
  "check_number": $num,
  "check_name": "$name",
  "status": "FAIL",
  "exit_code": 1,
  "details": {
    "message": "Script execution failed or crashed",
    "${count_field:-critical_failures}": 1
  }
}
EOF
    fi
}

# aggregate_job_result : echo "fail" if any should-run check recorded a non-zero
# process exit (result-check-<step>.rc == 1) OR produced no result file at all
# (did not complete), else "pass". Mirrors the old monolith rule: the job fails iff
# any executed check's process exited non-zero (standard FAIL or execution error for
# any check, including informational), and a check that was expected to run but left
# no result is treated as a failure rather than silently passing.
aggregate_job_result() {
    local step rc_file rc
    for step in "${ALL_CHECKS[@]}"; do
        should_run_step "$step" || continue
        rc_file="${REPORT_DIR}/result-check-${step}.rc"
        if [[ -f "$rc_file" ]]; then
            rc="$(cat "$rc_file" 2>/dev/null || echo 1)"
            # Any non-zero exit fails the job: standard FAIL / execution error (1),
            # but also signals like 137 (OOM/SIGKILL), 143 (SIGTERM/timeout), 139
            # (segfault), 2 (argparse). Matching only "1" would silently pass those.
            if [[ "$rc" != "0" ]]; then
                echo "fail"
                return 0
            fi
        else
            # Expected-to-run check with no result file did not complete -> fail.
            echo "fail"
            return 0
        fi
    done
    echo "pass"
}

# load_run_versions : ensure BASELINE/TARGET are available (from env, else from
# ${REPORT_DIR}/gap-run.env written by step-resolve-versions) and derive
# VERBOSE_FLAG. Returns 1 if versions cannot be determined.
load_run_versions() {
    BASELINE="${BASELINE:-}"
    TARGET="${TARGET:-}"
    if [[ -z "$BASELINE" || -z "$TARGET" ]]; then
        if [[ -f "${REPORT_DIR}/gap-run.env" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "${REPORT_DIR}/gap-run.env"
        fi
    fi
    VERBOSE_FLAG="${VERBOSE_FLAG:-}"
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        VERBOSE_FLAG="--verbose"
    fi
    if [[ -z "${BASELINE:-}" || -z "${TARGET:-}" ]]; then
        log_error "BASELINE and TARGET must be set (via env or ${REPORT_DIR}/gap-run.env)"
        return 1
    fi
    return 0
}

# run_check_list <step>... : run the given checks in order; return 1 if any
# should-run check recorded a non-zero process exit OR left no result file (did not
# complete), else 0. Kept consistent with aggregate_job_result.
run_check_list() {
    local steps=("$@")
    local step rcf step_rc=0
    for step in "${steps[@]}"; do
        run_check "$step"
    done
    for step in "${steps[@]}"; do
        should_run_step "$step" || continue
        rcf="${REPORT_DIR}/result-check-${step}.rc"
        if [[ ! -f "$rcf" ]] || [[ "$(cat "$rcf" 2>/dev/null || echo 1)" != "0" ]]; then
            step_rc=1
        fi
    done
    return $step_rc
}
