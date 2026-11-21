#!/usr/bin/env bash
# Install a Kubeflow preset (presets/<name>.yaml) from this chart checkout or the released chart.
# runMe.sh (--preset full) and installTrainerOnly.sh (--preset trainer-only) call this script.
#
# Usage (credentials from environment variables, so the tokens stay out of `ps` and shell history):
#   export APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token>
#   export SUSE_AI_REGISTRY_USER=regcode SUSE_AI_REGISTRY_TOKEN=<token>
#   ./install.sh --preset <name> [options]
#
#   --preset <name>             preset file presets/<name>.yaml: full, trainer-only, notebooks-trainer, ...
#   -f | --values-file <file>   extra values, applied after the preset (repeatable)
#   --kubeconfig <path>
#   --suse-registry <host> --suse-app-collection <host>   (or --suse-registry=<host>, ...)
#   --oci                       install the released chart (latest version) instead of this checkout
#   --chart-version <v>         install this released chart version (implies --oci)
#   --chart-ref <ref>           released chart reference (implies --oci; default oci://<suse-registry>/ai/charts/kubeflow)
#                               (runs the install.sh shipped with that chart, so script and chart match)
# Presets with Istio:
#   --no-istio-cni              classic istio-init sidecars (sets global.istio.cni=false)
#   --legacy-authz              EnvoyFilter gateway auth instead of native ext_authz (no istiod MeshConfig change)
#   --disable-cert-manager      don't install cert-manager (bring your own)
#   --cloudflare-api-key <key>  create the cloudflare-api-key Secret (external-dns, Let's Encrypt DNS-01)
# Presets with Trainer:
#   --no-runtimes               don't install the bundled ClusterTrainingRuntimes
#   --skip-tests                don't run `helm test`
#   --sample                    run a sample TrainJob on torch-distributed after install
#   --sample-namespace <ns>     namespace for the sample TrainJob (default: trainer-sample)
#
# Credentials can also be positional (<appco-user> <appco-token> <suse-ai-user> <suse-ai-token>), but
# then the tokens are visible in the process list; the script warns.
#
# What the cluster needs first (Istio, cert-manager, ESO, the knative-serving namespace) follows from the
# values, through the chart's component registry (components.yaml). A preset file's header names the
# checks to run afterwards:  # install-checks: trainer helm-test

set -euo pipefail

SUSE_REGISTRY=registry.suse.com
SUSE_APP_COLLECTION=dp.apps.rancher.io
RELEASE=kubeflow       # the namespaces' Helm ownership annotations must match
NAMESPACE=kubeflow     # hardcoded in many sub-chart templates

PRESET=""
POSITIONAL=()
EXTRA_VALUES=()
USE_OCI=0
CHART_VERSION=""
CHART_REF=""
ISTIO_CNI=true
AUTH_MODE=native
INSTALL_CERT_MANAGER=1
CLOUDFLARE_API_KEY="${CLOUDFLARE_API_KEY:-}"
INSTALL_RUNTIMES=1
RUN_TESTS=1
RUN_SAMPLE=0
SAMPLE_NS=trainer-sample

FORWARD=()   # options for the released chart's install.sh (--oci): all but the chart choice and credentials
need_arg() { [ -n "${2-}" ] || { echo "ERROR: $1 needs a value" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --preset)               need_arg "$1" "${2-}"; PRESET="$2"; shift 2 ;;
    -f | --values-file)     need_arg "$1" "${2-}"; EXTRA_VALUES+=(--values "$2"); FORWARD+=(--values-file "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    --kubeconfig)           need_arg "$1" "${2-}"; export KUBECONFIG="$2"; shift 2 ;;
    --suse-registry=*)       SUSE_REGISTRY="${1#*=}"; FORWARD+=("$1"); shift ;;
    --suse-registry)         need_arg "$1" "${2-}"; SUSE_REGISTRY="$2"; FORWARD+=("$1=$2"); shift 2 ;;
    --suse-app-collection=*) SUSE_APP_COLLECTION="${1#*=}"; FORWARD+=("$1"); shift ;;
    --suse-app-collection)   need_arg "$1" "${2-}"; SUSE_APP_COLLECTION="$2"; FORWARD+=("$1=$2"); shift 2 ;;
    --oci)                  USE_OCI=1; shift ;;
    --chart-version)        need_arg "$1" "${2-}"; CHART_VERSION="$2"; USE_OCI=1; shift 2 ;;
    --chart-ref)            need_arg "$1" "${2-}"; CHART_REF="$2"; USE_OCI=1; shift 2 ;;
    --force)                echo "ERROR: --force was removed: an upgrade can't safely remove components. Uninstall and reinstall (README.md#uninstall), or run helm upgrade yourself." >&2; exit 1 ;;
    --no-istio-cni)         ISTIO_CNI=false; FORWARD+=("$1"); shift ;;
    --legacy-authz)         AUTH_MODE=envoyfilter; FORWARD+=("$1"); shift ;;
    --disable-cert-manager) INSTALL_CERT_MANAGER=0; FORWARD+=("$1"); shift ;;
    --cloudflare-api-key)   need_arg "$1" "${2-}"; CLOUDFLARE_API_KEY="$2"; shift 2 ;;
    --no-runtimes)          INSTALL_RUNTIMES=0; FORWARD+=("$1"); shift ;;
    --skip-tests)           RUN_TESTS=0; FORWARD+=("$1"); shift ;;
    --sample)               RUN_SAMPLE=1; FORWARD+=("$1"); shift ;;
    --sample-namespace)     need_arg "$1" "${2-}"; SAMPLE_NS="$2"; RUN_SAMPLE=1; FORWARD+=("$1" "$2"); shift 2 ;;
    -h | --help)            awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    --*)                    echo "ERROR: unknown option $1" >&2; exit 1 ;;
    *)                      POSITIONAL+=("$1"); shift ;;
  esac
done
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  echo "WARNING: registry tokens given as arguments are visible to other users in the process list" >&2
  echo "  and stay in your shell history. Prefer APPCO_REGISTRY_TOKEN / SUSE_AI_REGISTRY_TOKEN." >&2
fi
APPCO_REGISTRY_USER="${POSITIONAL[0]:-${APPCO_REGISTRY_USER:-}}"
APPCO_REGISTRY_TOKEN="${POSITIONAL[1]:-${APPCO_REGISTRY_TOKEN:-}}"
SUSE_AI_REGISTRY_USER="${POSITIONAL[2]:-${SUSE_AI_REGISTRY_USER:-regcode}}"
SUSE_AI_REGISTRY_TOKEN="${POSITIONAL[3]:-${SUSE_AI_REGISTRY_TOKEN:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[[ -n "$PRESET" ]] || die "--preset is required (one of: $(preset_names "$SCRIPT_DIR"))"
if [[ -z "$APPCO_REGISTRY_USER" || -z "$APPCO_REGISTRY_TOKEN" || -z "$SUSE_AI_REGISTRY_USER" || -z "$SUSE_AI_REGISTRY_TOKEN" ]]; then
  echo "Usage: set APPCO_REGISTRY_USER, APPCO_REGISTRY_TOKEN, SUSE_AI_REGISTRY_USER and SUSE_AI_REGISTRY_TOKEN,"
  echo "  then run $0 --preset <name> [options]. Run $0 --help for options."
  exit 1
fi
[[ -z "$CHART_REF" ]] && CHART_REF="oci://${SUSE_REGISTRY}/ai/charts/kubeflow"

# A released chart is installed by the install.sh it ships, so script and chart always match. That
# script installs from the registry reference given in KUBEFLOW_INSTALL_CHART_REF/_VERSION (keep these
# names: older and newer releases' scripts rely on them).
if [[ $USE_OCI -eq 1 ]]; then
  echo "=== Helm registry login ==="
  registry_login
  echo "=== Pull the released chart ${CHART_REF}${CHART_VERSION:+ (version $CHART_VERSION)} ==="
  VERSION_ARGS=()
  [[ -n "$CHART_VERSION" ]] && VERSION_ARGS=(--version "$CHART_VERSION")
  helm pull "$CHART_REF" "${VERSION_ARGS[@]}" --untar -d "$WORKDIR/pulled"
  PULLED_CHART="$(find "$WORKDIR/pulled" -mindepth 2 -maxdepth 2 -name Chart.yaml 2>/dev/null | head -1 || true)"
  [[ -n "$PULLED_CHART" && -f "$PULLED_CHART" ]] || die "helm pull of ${CHART_REF} produced no chart (no Chart.yaml under $WORKDIR/pulled)."
  PULLED="$(dirname "$PULLED_CHART")"
  PULLED_VERSION="$(awk '/^version:/{gsub(/"/,"",$2); print $2; exit}' "$PULLED/Chart.yaml")"
  export APPCO_REGISTRY_USER APPCO_REGISTRY_TOKEN SUSE_AI_REGISTRY_USER SUSE_AI_REGISTRY_TOKEN CLOUDFLARE_API_KEY
  if grep -q KUBEFLOW_INSTALL_CHART_REF "$PULLED/install.sh" 2>/dev/null; then
    echo "  Running install.sh of chart version $PULLED_VERSION"
    KUBEFLOW_INSTALL_CHART_REF="$CHART_REF" KUBEFLOW_INSTALL_CHART_VERSION="$PULLED_VERSION" \
      bash "$PULLED/install.sh" --preset "$PRESET" "${FORWARD[@]}"
  elif [[ "$PRESET" == trainer-only && -f "$PULLED/installTrainerOnly.sh" ]]; then
    # Charts up to 0.6.x have no install.sh; their installTrainerOnly.sh installs released charts itself.
    echo "  Running installTrainerOnly.sh of chart version $PULLED_VERSION"
    bash "$PULLED/installTrainerOnly.sh" --chart-ref "$CHART_REF" --chart-version "$PULLED_VERSION" "${FORWARD[@]}"
  else
    die "chart version $PULLED_VERSION has no install.sh. Install it with the scripts of that release (a checkout of tag kubeflow-$PULLED_VERSION)."
  fi
  exit 0
fi

VALUES_FILE="$SCRIPT_DIR/presets/$PRESET.yaml"
[[ -f "$VALUES_FILE" ]] || die "unknown preset '$PRESET' (one of: $(preset_names "$SCRIPT_DIR"))"
PRESET_ARGS=(--values "$VALUES_FILE")
CHECKS=" $(preset_meta "$VALUES_FILE" install-checks) "
has() { [[ "$1" == *" $2 "* ]]; }
CHART_VERSION="$(awk '/^version:/{gsub(/"/,"",$2); print $2; exit}' "$SCRIPT_DIR/Chart.yaml")"
echo "Preset: $PRESET"

echo "=== Preflight checks ==="
check_prerequisites
echo "=== Helm registry login ==="
registry_login
if [[ -n "${KUBEFLOW_INSTALL_CHART_REF:-}" ]]; then
  # Run from a pulled released chart (see --oci above): install that chart from the registry.
  CHART_ARGS=("$KUBEFLOW_INSTALL_CHART_REF" --version "$KUBEFLOW_INSTALL_CHART_VERSION")
  echo "  Using released chart $KUBEFLOW_INSTALL_CHART_REF version $KUBEFLOW_INSTALL_CHART_VERSION"
else
  echo "=== Package Kubeflow sub-charts (source checkout) ==="
  build_chart_dependencies "$SCRIPT_DIR"
  CHART_ARGS=("$SCRIPT_DIR")
fi

# The plan, from the chart's component registry rendered offline with these values: which components
# the release will have and what the cluster needs first. (The settings this script adds below don't
# change either.)
make_probe_chart "$SCRIPT_DIR"
probe "$WORKDIR/plan.yaml" "${PRESET_ARGS[@]}" "${EXTRA_VALUES[@]}"
TARGET="$(probe_field "$WORKDIR/plan.yaml" components)"
REQUIRES=" $(probe_field "$WORKDIR/plan.yaml" prerequisites) "
echo "  Components: ${TARGET//,/ }"
NEEDS="$(probe_field "$WORKDIR/plan.yaml" prerequisites)"
echo "  Needs first: ${NEEDS:-nothing}"

# Values of the Kubeflow release, in the order helm upgrade applies them.
INSTALL_ARGS=(--set global.suseRegistry="$SUSE_REGISTRY" --set global.suseApplicationCollectionRegistry="$SUSE_APP_COLLECTION")
if has "$REQUIRES" istio; then
  INSTALL_ARGS+=(--set global.istio.cni="$ISTIO_CNI")
  [[ "$AUTH_MODE" == envoyfilter ]] && INSTALL_ARGS+=(--values "$SCRIPT_DIR/values-envoyfilter-authz.yaml")
fi
[[ $INSTALL_RUNTIMES -eq 0 ]] && INSTALL_ARGS+=(--set trainer.runtimes.enabled=false)
VALUE_ARGS=("${PRESET_ARGS[@]}" "${INSTALL_ARGS[@]}" "${EXTRA_VALUES[@]}")

# An upgrade removes every component the new values don't enable, with its data (Pipelines runs,
# databases, models), and removing a controller together with its resources can strand them on
# finalizers; refuse it. Adding components needs no confirmation. The release's components come from
# its values (helm get values --all, as installed), through the same registry.
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  (umask 077; helm get values "$RELEASE" -n "$NAMESPACE" --all -o yaml > "$WORKDIR/release-values.yaml")
  probe "$WORKDIR/release-plan.yaml" --values "$WORKDIR/release-values.yaml"
  CURRENT="$(probe_field "$WORKDIR/release-plan.yaml" components)"
  REMOVED="$(missing_from "$CURRENT" "$TARGET")"
  if [[ -z "$REMOVED" ]]; then
    echo "  Existing release '$RELEASE' found; the upgrade keeps all its components."
  else
    echo "ERROR: upgrading release '$RELEASE' with preset '$PRESET' and these values would remove these components and their data:" >&2
    echo "  $REMOVED" >&2
    echo "  If a values file that kept them on is missing, add it back. To change presets, uninstall and" >&2
    echo "  reinstall: that deletes every component's data, including notebooks and profile namespaces" >&2
    echo "  (README.md#uninstall: delete the chart's Profiles first). To remove a single component and keep" >&2
    echo "  the rest, run helm upgrade with the chart yourself." >&2
    exit 1
  fi
fi

echo "=== Namespaces and image pull secrets ==="
NAMESPACES=("$NAMESPACE")
has "$REQUIRES" istio && NAMESPACES+=(istio-system)
has "$REQUIRES" knative-namespace && NAMESPACES+=(knative-serving)
has "$REQUIRES" cert-manager && [[ $INSTALL_CERT_MANAGER -eq 1 ]] && NAMESPACES+=(cert-manager)
for ns in "${NAMESPACES[@]}"; do
  ensure_namespace "$ns"
  create_pull_secrets "$ns"
done
# Created before the release, so the release must be allowed to adopt them.
adopt_namespace "$NAMESPACE"
has "$REQUIRES" knative-namespace && adopt_namespace knative-serving
if [[ -n "$CLOUDFLARE_API_KEY" ]]; then
  for ns in "$NAMESPACE" cert-manager; do
    kubectl get namespace "$ns" >/dev/null 2>&1 && create_key_secret cloudflare-api-key apiKey "$CLOUDFLARE_API_KEY" "$ns"
  done
fi

if has "$REQUIRES" cert-manager && [[ $INSTALL_CERT_MANAGER -eq 1 ]]; then
  echo "=== Install cert-manager ==="
  install_cert_manager
fi
if has "$REQUIRES" istio; then
  echo "=== Install Istio (gateway auth: $AUTH_MODE, istio-cni: $ISTIO_CNI) ==="
  install_istio "$AUTH_MODE" "$ISTIO_CNI"
fi
if has "$REQUIRES" eso; then
  echo "=== Install External Secrets Operator ==="
  install_eso
fi

echo "=== Install Kubeflow (preset $PRESET) ==="
TIMEOUT=10m
has "$REQUIRES" istio && TIMEOUT=15m
# --force-conflicts: cert-manager-cainjector and the clusterrole-aggregation-controller modify
# fields (caBundle, aggregated .rules) that Helm's server-side apply tracks; this reclaims them.
helm upgrade --install "$RELEASE" "${CHART_ARGS[@]}" -n "$NAMESPACE" \
  "${VALUE_ARGS[@]}" \
  --force-conflicts --server-side=true --wait --timeout "$TIMEOUT"

if has "$CHECKS" trainer; then
  echo "=== Verify Kubeflow Trainer ==="
  verify_trainer
fi
if has "$CHECKS" helm-test && [[ $RUN_TESTS -eq 1 ]]; then
  helm test "$RELEASE" -n "$NAMESPACE" --timeout 5m
fi
if [[ $RUN_SAMPLE -eq 1 ]]; then
  if has "$CHECKS" trainer; then
    echo "=== Sample TrainJob in namespace $SAMPLE_NS ==="
    run_sample "$SAMPLE_NS" "$SCRIPT_DIR/tutorial/trainer/trainjob_torch_hello.yaml"
  else
    echo "  --sample ignored: preset $PRESET runs no Trainer checks."
  fi
fi

echo ""
echo "=== Kubeflow installed successfully (preset $PRESET)! ==="
echo ""
if has "$CHECKS" trainer; then
  echo "  Trainer:    $(image_version kubeflow-trainer-controller-manager)"
  echo "  JobSet:     $(image_version jobset-controller-manager)"
fi
echo "  Release:    $RELEASE (namespace $NAMESPACE)"
if [[ -n "${KUBEFLOW_INSTALL_CHART_REF:-}" ]]; then
  echo "  Chart:      $KUBEFLOW_INSTALL_CHART_REF version $CHART_VERSION"
else
  echo "  Chart:      $SCRIPT_DIR (source checkout)"
fi
if has "$CHECKS" trainer; then
  echo "  Runtimes:   kubectl get clustertrainingruntimes"
fi
if [[ "$PRESET" == trainer-only ]]; then
  echo "  TrainJobs run in any namespace; each needs a registry.suse.com pull secret on its"
  echo "  default ServiceAccount. See docs/use-cases/trainer-only-install.md, Step 7."
  echo ""
  echo "  Uninstalling ('helm uninstall $RELEASE -n $NAMESPACE') keeps the Trainer and JobSet CRDs (and any TrainJobs/JobSets)."
fi
if has "$REQUIRES" istio; then
  echo ""
  print_access
fi
