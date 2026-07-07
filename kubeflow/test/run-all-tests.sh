#!/usr/bin/env bash
# Run all test tiers for the Kubeflow Helm chart.
#
# Usage:
#   chmod +x test/run-all-tests.sh
#   ./test/run-all-tests.sh [options]
#
# Options:
#   --skip-tier1                       Skip Tier 1 (helm test)
#   --skip-tier2                       Skip Tier 2 (smoke tests)
#   --skip-tier3                       Skip Tier 3 (e2e tests)
#   --release=<name>                   Helm release name (default: kubeflow)
#   --namespace=<ns>                   Helm release namespace (default: kubeflow)
#   --include-gpu-tests                Pass --include-gpu-tests to e2e.sh (opt-in GPU tests)
#   --additional-user-namespace=<ns>   Also run Tier 2+3 against this extra profile namespace
#   --additional-user-email=<email>    Email for the extra profile (used by e2e KFP tests)
#   --suse-registry=<mirror>           SUSE AI registry mirror (default: stgregistry.suse.com)
#   --suse-app-collection=<mirror>     Application Collection registry mirror (default: dp.apps.rancher.io)

set -uo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
RELEASE=kubeflow
NAMESPACE=kubeflow
SKIP_TIER1=false
SKIP_TIER2=false
SKIP_TIER3=false
INCLUDE_GPU=false
ADDITIONAL_USER_NS=""
ADDITIONAL_USER_EMAIL=""
SUSE_REGISTRY=stgregistry.suse.com
SUSE_APP_COLLECTION=dp.apps.rancher.io

# ── Parse args ─────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --skip-tier1)                      SKIP_TIER1=true ;;
    --skip-tier2)                      SKIP_TIER2=true ;;
    --skip-tier3)                      SKIP_TIER3=true ;;
    --release=*)                       RELEASE="${arg#*=}" ;;
    --namespace=*)                     NAMESPACE="${arg#*=}" ;;
    --include-gpu-tests=true)          INCLUDE_GPU=true ;;
    --include-gpu-tests)               INCLUDE_GPU=true ;;
    --additional-user-namespace=*)     ADDITIONAL_USER_NS="${arg#*=}" ;;
    --additional-user-email=*)         ADDITIONAL_USER_EMAIL="${arg#*=}" ;;
    --suse-registry=*)                 SUSE_REGISTRY="${arg#*=}" ;;
    --suse-app-collection=*)           SUSE_APP_COLLECTION="${arg#*=}" ;;
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
T2_ADD_STATUS="SKIPPED"
T3_ADD_STATUS="SKIPPED"
OVERALL=0

# ── Pre-test: wait for all deployments to be available ────────────────────────
# helm test pods (profiles, seaweedfs, etc.) connect to services that take time
# to start after install/upgrade. Wait here so that all tiers benefit.
header "━━━ Pre-test readiness wait ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Waiting for all Deployments in $NAMESPACE to be Available (up to 5 minutes)..."
if kubectl wait deploy --all -n "$NAMESPACE" \
    --for=condition=available --timeout=300s 2>/dev/null; then
  info "All Deployments available."
else
  info "WARNING: some Deployments not yet Available after 300s — tests may still pass."
fi

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

# ── Tier 2: smoke tests (default profile) ─────────────────────────────────────
header "━━━ Tier 2 — smoke tests (default profile) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $SKIP_TIER2; then
  info "Skipped (--skip-tier2)"
else
  if bash "$SCRIPT_DIR/smoke/smoke.sh" \
      "--suse-registry=${SUSE_REGISTRY}" \
      "--suse-app-collection=${SUSE_APP_COLLECTION}"; then
    T2_STATUS="PASSED"
  else
    T2_STATUS="FAILED"
    OVERALL=1
  fi
fi

# ── Tier 3: e2e tests (default profile) ───────────────────────────────────────
header "━━━ Tier 3 — e2e tests (default profile) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $SKIP_TIER3; then
  info "Skipped (--skip-tier3)"
else
  E2E_ARGS=("--suse-registry=${SUSE_REGISTRY}" "--suse-app-collection=${SUSE_APP_COLLECTION}")
  $INCLUDE_GPU && E2E_ARGS+=(--include-gpu-tests)
  if bash "$SCRIPT_DIR/e2e/e2e.sh" "${E2E_ARGS[@]}"; then
    T3_STATUS="PASSED"
  else
    T3_STATUS="FAILED"
    OVERALL=1
  fi
fi

# ── Additional profile tests ───────────────────────────────────────────────────
if [[ -n "$ADDITIONAL_USER_NS" ]]; then

  header "━━━ Tier 2 — smoke tests (additional profile: $ADDITIONAL_USER_NS) ━━━━━━"
  if $SKIP_TIER2; then
    info "Skipped (--skip-tier2)"
  else
    if bash "$SCRIPT_DIR/smoke/smoke.sh" \
        "--suse-registry=${SUSE_REGISTRY}" \
        "--suse-app-collection=${SUSE_APP_COLLECTION}" \
        "--user-namespace=${ADDITIONAL_USER_NS}"; then
      T2_ADD_STATUS="PASSED"
    else
      T2_ADD_STATUS="FAILED"
      OVERALL=1
    fi
  fi

  header "━━━ Tier 3 — e2e tests (additional profile: $ADDITIONAL_USER_NS) ━━━━━━━"
  if $SKIP_TIER3; then
    info "Skipped (--skip-tier3)"
  else
    E2E_ARGS=("--suse-registry=${SUSE_REGISTRY}" "--suse-app-collection=${SUSE_APP_COLLECTION}")
    $INCLUDE_GPU && E2E_ARGS+=(--include-gpu-tests)
    E2E_ARGS+=("--user-namespace=${ADDITIONAL_USER_NS}")
    [[ -n "$ADDITIONAL_USER_EMAIL" ]] && E2E_ARGS+=("--user-email=${ADDITIONAL_USER_EMAIL}")
    if bash "$SCRIPT_DIR/e2e/e2e.sh" "${E2E_ARGS[@]}"; then
      T3_ADD_STATUS="PASSED"
    else
      T3_ADD_STATUS="FAILED"
      OVERALL=1
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
header "━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-40s %s\n" "Tier 1 (helm):"                          "$T1_STATUS"
printf "  %-40s %s\n" "Tier 2 (smoke, default profile):"        "$T2_STATUS"
printf "  %-40s %s\n" "Tier 3 (e2e, default profile):"          "$T3_STATUS"
if [[ -n "$ADDITIONAL_USER_NS" ]]; then
  printf "  %-40s %s\n" "Tier 2 (smoke, ${ADDITIONAL_USER_NS}):" "$T2_ADD_STATUS"
  printf "  %-40s %s\n" "Tier 3 (e2e, ${ADDITIONAL_USER_NS}):"   "$T3_ADD_STATUS"
fi
echo ""

if [[ $OVERALL -eq 0 ]]; then
  green "ALL TIERS PASSED"
else
  red "ONE OR MORE TIERS FAILED"
fi

exit $OVERALL
