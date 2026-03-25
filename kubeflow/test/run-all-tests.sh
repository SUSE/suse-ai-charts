#!/usr/bin/env bash
# Run all test tiers for the Kubeflow Helm chart.
#
# Usage:
#   chmod +x test/run-all-tests.sh
#   ./test/run-all-tests.sh [options]
#
# Options:
#   --skip-tier1             Skip Tier 1 (helm test)
#   --skip-tier2             Skip Tier 2 (smoke tests)
#   --skip-tier3             Skip Tier 3 (e2e tests)
#   --release=<name>         Helm release name (default: kubeflow)
#   --namespace=<ns>         Helm release namespace (default: kubeflow)
#   --include-gpu-tests      Pass --include-gpu-tests to e2e.sh (opt-in GPU tests)

set -uo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
RELEASE=kubeflow
NAMESPACE=kubeflow
SKIP_TIER1=false
SKIP_TIER2=false
SKIP_TIER3=false
INCLUDE_GPU=false

# ── Parse args ─────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --skip-tier1)              SKIP_TIER1=true ;;
    --skip-tier2)              SKIP_TIER2=true ;;
    --skip-tier3)              SKIP_TIER3=true ;;
    --release=*)               RELEASE="${arg#*=}" ;;
    --namespace=*)             NAMESPACE="${arg#*=}" ;;
    --include-gpu-tests=true)  INCLUDE_GPU=true ;;
    --include-gpu-tests)       INCLUDE_GPU=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Locate this script's directory so relative paths always work ───────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ─────────────────────────────────────────────────────────────
green()  { printf '\033[32m  ✓  %s\033[0m\n' "$*"; }
red()    { printf '\033[31m  ✗  %s\033[0m\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info()   { printf '      %s\n' "$*"; }

T1_STATUS="SKIPPED"
T2_STATUS="SKIPPED"
T3_STATUS="SKIPPED"
OVERALL=0

# ── Tier 1: helm test ──────────────────────────────────────────────────────────
header "━━━ Tier 1 — helm test ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $SKIP_TIER1; then
  info "Skipped (--skip-tier1)"
else
  if helm test "$RELEASE" -n "$NAMESPACE"; then
    T1_STATUS="PASSED"
  else
    T1_STATUS="FAILED"
    OVERALL=1
  fi
fi

# ── Tier 2: smoke tests ────────────────────────────────────────────────────────
header "━━━ Tier 2 — smoke tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $SKIP_TIER2; then
  info "Skipped (--skip-tier2)"
else
  if bash "$SCRIPT_DIR/smoke/smoke.sh"; then
    T2_STATUS="PASSED"
  else
    T2_STATUS="FAILED"
    OVERALL=1
  fi
fi

# ── Tier 3: e2e tests ──────────────────────────────────────────────────────────
header "━━━ Tier 3 — e2e tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $SKIP_TIER3; then
  info "Skipped (--skip-tier3)"
else
  E2E_ARGS=()
  $INCLUDE_GPU && E2E_ARGS+=(--include-gpu-tests)
  if bash "$SCRIPT_DIR/e2e/e2e.sh" "${E2E_ARGS[@]}"; then
    T3_STATUS="PASSED"
  else
    T3_STATUS="FAILED"
    OVERALL=1
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
header "━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-12s %s\n" "Tier 1 (helm):"  "$T1_STATUS"
printf "  %-12s %s\n" "Tier 2 (smoke):" "$T2_STATUS"
printf "  %-12s %s\n" "Tier 3 (e2e):"   "$T3_STATUS"
echo ""

if [[ $OVERALL -eq 0 ]]; then
  green "ALL TIERS PASSED"
else
  red "ONE OR MORE TIERS FAILED"
fi

exit $OVERALL
