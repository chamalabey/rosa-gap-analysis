#!/usr/bin/env bash
# step-cleanup.sh - Workflow step 7: cleanup and resource management.
#
# Best-effort removal of temporary directories created by the analyzers:
#   ocp-crs-*     (oc adm release extract scratch dirs: gap-aws-sts / gap-gcp-wif)
#   mcc-checkout-* (managed-cluster-config sparse checkouts: ack_validation)
# Always exits 0 so cleanup never fails the job.
#
# Inputs (env): TMPDIR (optional; defaults to /tmp)
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"

tmp_root="${TMPDIR:-/tmp}"
tmp_root="${tmp_root%/}"

log_info "[cleanup] Removing analyzer temp directories under ${tmp_root}..."

removed=0
for pattern in "ocp-crs-" "mcc-checkout-"; do
    for dir in "${tmp_root}/${pattern}"*; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir" 2>/dev/null && removed=$((removed + 1)) || true
        fi
    done
done

log_success "[cleanup] Done (removed ${removed} temp director$([[ $removed -eq 1 ]] && echo y || echo ies))."
