#!/usr/bin/env bash
# step-report.sh - Workflow step 6: report generation and result aggregation.
#
# Reconstructs per-check status from status-check-*.json + result-check-*.rc,
# generates the combined HTML/JSON report, prints the summary, and exits with the
# aggregated job result (1 if any executed check's process exited non-zero).
#
# Can be re-run standalone against a prior run's artifacts (no checks re-executed):
#   REPORT_DIR=/tmp/prowdl step-report.sh   (reads gap-run.env / env for versions)
#
# Inputs (env): BASELINE, TARGET (or ${REPORT_DIR}/gap-run.env), REPORT_DIR,
#               STEPS (optional filter), BUILD_LOG, START_TIME,
#               START_TIME_FORMATTED, job, buildid (optional)
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"
source "${STEP_DIR}/lib/checks-manifest.sh"

REPORT_DIR="${REPORT_DIR:-reports}"
STEPS="${STEPS:-}"

load_run_versions || exit 1

START_TIME="${START_TIME:-$(date +%s)}"
START_TIME_FORMATTED="${START_TIME_FORMATTED:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"

# Print one check's summary line from the populated arrays.
print_individual_check() {
    local step_name="$1"
    should_run_step "$step_name" || return 0

    local num="${CHECK_DISPLAY_NUM[$step_name]}"
    local name="${CHECK_NAME[$step_name]}"
    local result="${CHECK_RESULT[$step_name]:-0}"
    local diff_count="${CHECK_DIFF_COUNT[$step_name]:-0}"
    local message="${CHECK_MESSAGE[$step_name]:-}"
    local ctype="${CHECK_TYPE[$step_name]:-standard}"
    local status_val="${CHECK_STATUS[$step_name]:-}"

    local symbol="" status=""
    if [[ "$status_val" == "SKIP" ]]; then
        symbol="ℹ "
        status="SKIP"
    elif [[ "$result" -eq 0 ]]; then
        if [[ "$diff_count" -gt 0 ]]; then
            symbol="⚠ "
            status="WARNING"
        else
            symbol="✓ "
            if [[ "$ctype" == "informational" ]]; then
                status="INFORMATIONAL"
            else
                status="PASS"
            fi
        fi
    else
        symbol="✗ "
        if [[ "$ctype" == "informational" ]]; then
            symbol="⚠ "
            status="ERROR"
        else
            status="FAIL"
        fi
    fi

    echo "[$symbol] CHECK #$num: $name - $status ($message)"
}

# Populate arrays (and fabricate fallback status files for crashed checks).
for step in "${ALL_CHECKS[@]}"; do
    should_run_step "$step" || continue
    read_check_status "$step"
done

# Duration.
end_time=$(date +%s)
duration=$((end_time - START_TIME))
duration_formatted=$(printf '%dm %ds' $((duration / 60)) $((duration % 60)))

# Combined report (warn-only on failure; individual reports remain available).
log_info ""
log_info "Generating combined report..."
combined_exit_code=0
python3 "${GAP_SCRIPTS_DIR}/generate-combined-report.py" \
    --baseline "$BASELINE" \
    --target "$TARGET" \
    --report-dir "$REPORT_DIR" \
    ${BUILD_LOG:+--build-log "$BUILD_LOG"} 2>&1 || combined_exit_code=$?
if [[ $combined_exit_code -ne 0 ]]; then
    log_warning "Failed to generate combined report (individual reports still available) with exit code $combined_exit_code"
fi

# Aggregate overall job result from per-check process exit codes.
job_result="$(aggregate_job_result)"
if [[ "$job_result" == "fail" ]]; then
    log_error ""
    log_error "❌ FAILED"
else
    log_success ""
    log_success "✅ PASSED"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info ""
echo "==============================================================================="
echo "GAP ANALYSIS SUMMARY"
echo "==============================================================================="

job="${job:-job123}"
buildid="${buildid:-build1234}"

echo "Baseline: ${BASELINE}"
echo "Target: ${TARGET}"
echo "Started: ${START_TIME_FORMATTED}"
echo "Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Duration: ${duration_formatted}"
echo ""
echo "RESULTS:"

for step in "${ALL_CHECKS[@]}"; do
    print_individual_check "$step"
done

echo ""

# Overall status with warnings.
has_warnings=false
for step in "${ALL_CHECKS[@]}"; do
    if should_run_step "$step" && [[ "${CHECK_RESULT[$step]:-0}" -eq 0 ]] && [[ "${CHECK_DIFF_COUNT[$step]:-0}" -gt 0 ]]; then
        has_warnings=true
        break
    fi
done

if [[ "$job_result" != "fail" ]]; then
    if [[ "$has_warnings" == "true" ]]; then
        echo "OVERALL STATUS: SUCCESS (with warnings)"
    else
        echo "OVERALL STATUS: SUCCESS"
    fi
else
    echo "OVERALL STATUS: FAILED"
fi

echo ""
echo "ARTIFACTS:"
echo "- Reports directory: ${REPORT_DIR}/"

# `|| true` so a find/sort failure here cannot, under set -e + pipefail, override the
# already-computed job verdict with find's exit code.
html_reports=$(find "${REPORT_DIR}" -maxdepth 1 -name "*.html" -type f 2>/dev/null | sort || true)
if [[ -n "$html_reports" && -n "$job" && -n "$buildid" ]]; then
    echo "- HTML reports:"
    while IFS= read -r report; do
        base=$(basename "$report")
        echo "  • https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${job}/${buildid}/artifacts/test/artifacts/rosa-gap-analysis-reports/${base}"
    done <<< "$html_reports"
fi

if [[ -n "$job" && -n "$buildid" ]]; then
    echo "- Build log: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${job}/${buildid}/build-log.txt"
fi

echo "==============================================================================="

if [[ "$job_result" == "fail" ]]; then
    exit 1
fi
exit 0
