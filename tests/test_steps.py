"""Tests for the gap-all.sh workflow decomposition (scripts/steps/).

These exercise the orchestration plumbing without network access: step metadata,
the STEPS filter, job-result aggregation, status-file fallback, the thin driver's
dry-run and validation paths, and the set -e command-substitution guard that the
resolve-versions step relies on (the previous monolith's graceful-skip bug).
"""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAP_ALL = ROOT / "scripts" / "gap-all.sh"
STEPS_LIB = ROOT / "scripts" / "steps" / "lib" / "checks-manifest.sh"
LOGGING = ROOT / "scripts" / "lib" / "logging.sh"


def _bash(script: str, cwd: Path = ROOT):
    """Run a bash snippet and return the CompletedProcess."""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=str(cwd),
        capture_output=True,
        text=True,
    )


def _source_manifest(body: str) -> str:
    return (
        f'source "{LOGGING}"\n'
        f'source "{STEPS_LIB}"\n'
        f"{body}\n"
    )


def test_dry_run_explicit_versions(tmp_path):
    """Dry-run with explicit full versions resolves without network and exits 0."""
    result = _bash(
        f'REPORT_DIR="{tmp_path}" "{GAP_ALL}" '
        f"--baseline 4.21.15 --target 4.22.0-rc.3 --dry-run"
    )
    assert result.returncode == 0, result.stderr
    run_env = (tmp_path / "gap-run.env").read_text()
    assert "GAP_SKIP=0" in run_env
    # Values are written with printf %q; simple versions need no quoting.
    assert "BASELINE=4.21.15" in run_env
    assert "TARGET=4.22.0-rc.3" in run_env


def test_resolve_versions_no_shell_injection(tmp_path):
    """A version with shell metacharacters must not execute when gap-run.env is
    sourced; printf %q keeps it a literal. Regression for the gap-run.env injection."""
    canary = tmp_path / "PWNED"
    bad = f"4.21.15'; touch {canary}; echo '"
    env = {
        **os.environ,
        "REPORT_DIR": str(tmp_path),
        "VERSION": "", "OPENSHIFT_VERSION": "",
        "BASE_VERSION": "", "TARGET_VERSION": "",
        "BASELINE": bad, "TARGET": "4.22.0-rc.3",
    }
    subprocess.run(
        [str(ROOT / "scripts" / "steps" / "step-resolve-versions.sh")],
        cwd=str(ROOT), env=env, capture_output=True, text=True,
    )
    # Sourcing the generated file must NOT run the injected command...
    sourced = _bash(f'source "{tmp_path}/gap-run.env"; printf "%s" "$BASELINE"')
    assert not canary.exists(), "injected command executed when gap-run.env was sourced"
    # ...and the value must survive verbatim.
    assert sourced.stdout == bad


def test_invalid_step_rejected():
    """An unknown --steps value is rejected with a non-zero exit."""
    result = _bash(f'"{GAP_ALL}" --version 4.22 --steps bogus')
    assert result.returncode != 0
    assert "Invalid step: bogus" in (result.stdout + result.stderr)


def test_should_run_step_filter():
    """Empty STEPS runs everything; a filter restricts to the listed steps."""
    out = _bash(_source_manifest(
        'STEPS=""; should_run_step aws && echo ALL_AWS;\n'
        'STEPS="aws,gcp"; should_run_step aws && echo FILT_AWS;\n'
        'should_run_step ocp || echo FILT_NO_OCP;'
    )).stdout
    assert "ALL_AWS" in out
    assert "FILT_AWS" in out
    assert "FILT_NO_OCP" in out


def test_aggregate_job_result(tmp_path):
    """Job result is 'fail' iff any executed check recorded a non-zero rc."""
    # Scope to the two checks under test so only their rc files are considered.
    base = f'REPORT_DIR="{tmp_path}"; STEPS="aws,gcp";'
    # All pass.
    (tmp_path / "result-check-aws.rc").write_text("0")
    (tmp_path / "result-check-gcp.rc").write_text("0")
    assert _bash(_source_manifest(f"{base} aggregate_job_result")).stdout.strip() == "pass"
    # One failing check flips the whole job.
    (tmp_path / "result-check-gcp.rc").write_text("1")
    assert _bash(_source_manifest(f"{base} aggregate_job_result")).stdout.strip() == "fail"
    # Any non-zero code counts as failure, not just "1" (e.g. 137 OOM/SIGKILL, 143 timeout).
    (tmp_path / "result-check-gcp.rc").write_text("137")
    assert _bash(_source_manifest(f"{base} aggregate_job_result")).stdout.strip() == "fail"


def test_aggregate_job_result_missing_rc_fails(tmp_path):
    """A should-run check that produced no result file is treated as a failure."""
    base = f'REPORT_DIR="{tmp_path}"; STEPS="aws";'  # no result-check-aws.rc written
    assert _bash(_source_manifest(f"{base} aggregate_job_result")).stdout.strip() == "fail"


def test_read_check_status_fallback(tmp_path):
    """A missing status file fabricates a FAIL status-check-<num>.json."""
    out = _bash(_source_manifest(
        f'REPORT_DIR="{tmp_path}"; STEPS="";\n'
        'read_check_status aws;\n'
        'echo "STATUS=${CHECK_STATUS[aws]}";\n'
        'echo "RESULT=${CHECK_RESULT[aws]}";'
    )).stdout
    assert "STATUS=FAIL" in out
    # No result file -> the check did not complete -> treated as a failure (result 1),
    # consistent with the fabricated FAIL status.
    assert "RESULT=1" in out
    fallback = tmp_path / "status-check-1.json"
    assert fallback.exists()
    assert '"status": "FAIL"' in fallback.read_text()


def test_resolve_versions_setE_guard():
    """Regression for the monolith graceful-skip bug.

    The resolve-versions step captures a failing command substitution with
    `result=$(cmd) || rc=$?` so a non-zero return does NOT trip `set -e` and
    bypass the skip handling. The old `result=$(cmd); rc=$?` pattern aborts first.
    """
    # Fixed pattern: continues and captures rc.
    good = _bash('set -euo pipefail; f(){ return 1; }; rc=0; r=$(f) || rc=$?; echo "after rc=$rc"')
    assert good.returncode == 0
    assert "after rc=1" in good.stdout

    # Old buggy pattern: set -e aborts before the exit-code check.
    bad = _bash('set -euo pipefail; f(){ return 1; }; r=$(f); rc=$?; echo "reached rc=$rc"')
    assert bad.returncode != 0
    assert "reached" not in bad.stdout
