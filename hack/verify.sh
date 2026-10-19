#!/usr/bin/env bash
# Repo-specific static checks for `make lint` (Python/bash equivalent of
# certman-operator go-check + yaml-validate).
# Does not invoke pre-commit; pre-commit calls `make lint` locally.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PYTHON="${PYTHON:-python3}"
FAILED=0

fail() {
    echo "ERROR: $*" >&2
    FAILED=1
}

echo "==> Python syntax (compileall)"
if ! "${PYTHON}" -m compileall -q scripts ci; then
    fail "Python compileall failed"
fi

echo "==> Bash syntax (bash -n)"
while IFS= read -r -d '' file; do
    if ! bash -n "${file}"; then
        fail "Bash syntax error in ${file}"
    fi
done < <(find scripts ci hack -name '*.sh' -type f -print0 | sort -z)

echo "==> Jinja2 template compile"
if ! "${PYTHON}" - <<'PY'
import sys
from pathlib import Path
from jinja2 import TemplateSyntaxError

sys.path.insert(0, str(Path("scripts/lib").resolve()))
from reporters import TEMPLATE_DIR, jinja_env

failed = False
templates = sorted(TEMPLATE_DIR.rglob("*.j2"))
for path in templates:
    name = path.relative_to(TEMPLATE_DIR).as_posix()
    try:
        jinja_env.get_template(name)
    except TemplateSyntaxError as exc:
        print(f"ERROR: Jinja2 syntax error in {path}: {exc}", flush=True)
        failed = True
if failed:
    raise SystemExit(1)
print(f"Compiled {len(templates)} templates")
PY
then
    fail "Jinja2 template compile failed"
fi

echo "==> Gap script HTML templates"
shopt -s nullglob
for script in scripts/gap-*.py; do
    name="$(basename "${script}" .py)"
    name="${name#gap-}"
    template="scripts/templates/${name}.html.j2"
    if [[ ! -f "${template}" ]]; then
        fail "Missing ${template} for ${script}"
    fi
done
if [[ -f scripts/prod/gap-ga-validation.py && ! -f scripts/templates/ga-validation.html.j2 ]]; then
    fail "Missing scripts/templates/ga-validation.html.j2 for scripts/prod/gap-ga-validation.py"
fi

echo "==> CLI --help smoke tests"
help_scripts=(scripts/gap-*.py scripts/generate-combined-report.py)
if [[ -f scripts/prod/gap-ga-validation.py ]]; then
    help_scripts+=(scripts/prod/gap-ga-validation.py)
fi
for script in "${help_scripts[@]}"; do
    if ! "${PYTHON}" "${script}" --help >/dev/null; then
        fail "--help failed for ${script}"
    fi
done

echo "==> checks-manifest.sh references every gap-*.py and feature-gates runs last"
# The workflow steps (scripts/steps/) run each gap-*.py via the CHECK_SCRIPT map in
# the shared manifest, driven by gap-all.sh. Verify the manifest covers every
# gap-*.py and that feature-gates is the last entry in the execution order.
gap_scripts=()
while IFS= read -r _gs_path; do
    gap_scripts+=("$(basename "${_gs_path}")")
done < <(find scripts -maxdepth 1 -name 'gap-*.py' -type f | sort)

# shellcheck source=scripts/steps/lib/checks-manifest.sh disable=SC1091
if ! source scripts/steps/lib/checks-manifest.sh 2>/dev/null; then
    fail "Could not source scripts/steps/lib/checks-manifest.sh"
elif [[ ${#ALL_CHECKS[@]} -eq 0 ]]; then
    fail "ALL_CHECKS is empty in scripts/steps/lib/checks-manifest.sh"
else
    last_step="${ALL_CHECKS[-1]}"
    if [[ "${CHECK_SCRIPT[${last_step}]:-}" != "gap-feature-gates.py" ]]; then
        fail "Feature gates must run last (ALL_CHECKS ends with step '${last_step}' -> ${CHECK_SCRIPT[${last_step}]:-<none>})"
    fi
    for name in "${gap_scripts[@]}"; do
        found=0
        for step in "${ALL_CHECKS[@]}"; do
            if [[ "${CHECK_SCRIPT[${step}]:-}" == "${name}" ]]; then
                found=1
                break
            fi
        done
        if [[ "${found}" -eq 0 ]]; then
            fail "${name} is not referenced in scripts/steps/lib/checks-manifest.sh"
        fi
    done
fi

if [[ "${FAILED}" -ne 0 ]]; then
    echo "verify FAILED" >&2
    exit 1
fi

echo "verify OK"
