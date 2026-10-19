#!/usr/bin/env bash
# step-ocm-auth.sh - Workflow step 2: OCM authentication and token validation.
#
# Logs in to OCM when credentials are present (OCM_TOKEN, or OCM_CLIENT_ID +
# OCM_CLIENT_SECRET, with optional OCM_URL). When no credentials are provided this
# is a graceful no-op: downstream checks that use OCM degrade gracefully.
#
# Exits non-zero only when an explicit login attempt fails (same behavior as the
# previous monolithic gap-all.sh).
#
# Inputs (env): OCM_TOKEN | OCM_CLIENT_ID + OCM_CLIENT_SECRET, OCM_URL (optional)
# Independently runnable: OCM_TOKEN=... step-ocm-auth.sh
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP_SCRIPTS_DIR="$(cd "${STEP_DIR}/.." && pwd)"
source "${GAP_SCRIPTS_DIR}/lib/logging.sh"
source "${GAP_SCRIPTS_DIR}/lib/ocm_auth.sh"

log_info "[ocm-auth] Authenticating to OCM (if credentials available)..."

if ! ocm_authenticate; then
    log_error "[ocm-auth] OCM authentication failed"
    exit 1
fi

log_success "[ocm-auth] OCM authentication step complete."
