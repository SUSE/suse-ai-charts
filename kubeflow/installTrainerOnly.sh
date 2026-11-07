#!/usr/bin/env bash
# Trainer-only Kubeflow install helper (convenience script, aimed at dev/test clusters).
#
# Installs only Kubeflow Trainer V2 + JobSet, automating the steps of
# docs/use-cases/trainer-only-install.md (see that guide for what it does and why).
# By default it installs from this chart checkout (source). With --oci,
# --chart-version or --chart-ref it installs the released OCI chart instead
# (default oci://<suse-registry>/ai/charts/kubeflow). Unlike runMe.sh, it does NOT install cert-manager,
# Istio or the External Secrets Operator. It installs with the chart's
# trainer-only-overrides.yaml preset (the same file the guide and CI use).
#
# Usage (credentials from environment variables, so the tokens stay out of `ps` and
# shell history):
#   export APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token>
#   export SUSE_AI_REGISTRY_USER=regcode SUSE_AI_REGISTRY_TOKEN=<token>
#   ./installTrainerOnly.sh
#       [-f | --values-file <extra values.yaml>]   (repeatable; applied after the trainer-only values)
#       [--kubeconfig <path>]
#       [--suse-registry=<host>] [--suse-app-collection=<host>]
#       [--no-runtimes]        don't install the bundled ClusterTrainingRuntimes
#       [--skip-tests]         don't run `helm test`
#       [--sample]             run a sample TrainJob on torch-distributed after install
#       [--sample-namespace <ns>]   namespace for the sample TrainJob (default: trainer-sample)
#       [--force]              allow converting an existing non-trainer-only "kubeflow" release
#       [--oci]                install the released OCI chart (latest version) instead of this checkout
#       [--chart-version <v>]  install this released OCI chart version (implies --oci)
#       [--chart-ref <ref>]    OCI chart reference (implies --oci; default oci://<suse-registry>/ai/charts/kubeflow)
#
# OCI installs need a chart release that includes the trainer-only switches
# (istioResources.enabled, ...). The script checks this and aborts on older releases.
#
# The credentials can also be passed as positional arguments (same order as runMe.sh):
#   ./installTrainerOnly.sh <appco-user> <appco-token> <suse-ai-user> <suse-ai-token> [options]
# but then the tokens are visible to other users in the process list; the script warns.

set -euo pipefail

SUSE_REGISTRY=registry.suse.com        # override with --suse-registry=
SUSE_APP_COLLECTION=dp.apps.rancher.io  # override with --suse-app-collection=
RELEASE=kubeflow                        # the namespace's Helm ownership annotation must match
NAMESPACE=kubeflow                      # hardcoded in the trainer templates
MIN_K8S_MINOR=35                        # Chart.yaml kubeVersion: >=1.35.0-0

# ── Arguments ────────────────────────────────────────────────────────────────
POSITIONAL=()
EXTRA_VALUES=()
INSTALL_RUNTIMES=1
RUN_TESTS=1
RUN_SAMPLE=0
SAMPLE_NS=trainer-sample
FORCE=0
USE_OCI=0
CHART_VERSION=""
CHART_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f | --values-file)
      [ -n "${2-}" ] || { echo "ERROR: values file must be specified with $1" >&2; exit 1; }
      EXTRA_VALUES+=(--values "$2"); shift 2 ;;
    --kubeconfig)
      [ -n "${2-}" ] || { echo "ERROR: kubeconfig path must be specified with $1" >&2; exit 1; }
      export KUBECONFIG="$2"; shift 2 ;;
    --suse-registry=*)       SUSE_REGISTRY="${1#*=}"; shift ;;
    --suse-app-collection=*) SUSE_APP_COLLECTION="${1#*=}"; shift ;;
    --no-runtimes)           INSTALL_RUNTIMES=0; shift ;;
    --skip-tests)            RUN_TESTS=0; shift ;;
    --sample)                RUN_SAMPLE=1; shift ;;
    --sample-namespace)
      [ -n "${2-}" ] || { echo "ERROR: namespace must be specified with $1" >&2; exit 1; }
      SAMPLE_NS="$2"; RUN_SAMPLE=1; shift 2 ;;
    --force)                 FORCE=1; shift ;;
    --oci)                   USE_OCI=1; shift ;;
    --chart-version)
      [ -n "${2-}" ] || { echo "ERROR: version must be specified with $1" >&2; exit 1; }
      CHART_VERSION="$2"; USE_OCI=1; shift 2 ;;
    --chart-ref)
      [ -n "${2-}" ] || { echo "ERROR: OCI reference must be specified with $1" >&2; exit 1; }
      CHART_REF="$2"; USE_OCI=1; shift 2 ;;
    -h | --help)             awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    --*)                     echo "ERROR: unknown option $1" >&2; exit 1 ;;
    *)                       POSITIONAL+=("$1"); shift ;;
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

if [[ -z "$APPCO_REGISTRY_USER" || -z "$APPCO_REGISTRY_TOKEN" || -z "$SUSE_AI_REGISTRY_USER" || -z "$SUSE_AI_REGISTRY_TOKEN" ]]; then
  echo "Usage: set APPCO_REGISTRY_USER, APPCO_REGISTRY_TOKEN, SUSE_AI_REGISTRY_USER and SUSE_AI_REGISTRY_TOKEN,"
  echo "  then run $0 [options]"
  echo "  Run $0 --help for options."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/trainer-only-overrides.yaml"
SAMPLE_FILE="$SCRIPT_DIR/tutorial/trainer/trainjob_torch_hello.yaml"
[[ -z "$CHART_REF" ]] && CHART_REF="oci://${SUSE_REGISTRY}/ai/charts/kubeflow"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Create or update a docker-registry secret: create_pull_secret <name> <server> <user> <token> <namespace>
# The credentials go through a 0600 file in $WORKDIR, not kubectl arguments, so they
# never show up in `ps` output or shell audit logs.
create_pull_secret() {
  local cfg="$WORKDIR/dockerconfig-$1.json" auth
  auth="$(printf '%s:%s' "$3" "$4" | base64 | tr -d '\n')"
  (umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$2" "$auth" > "$cfg")
  kubectl create secret generic "$1" --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$cfg" \
    -n "$5" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$cfg"
}

# Add a pull secret to a namespace's default ServiceAccount without dropping existing
# entries: add_sa_pull_secret <namespace> <secret>
add_sa_pull_secret() {
  local current
  current="$(kubectl get serviceaccount default -n "$1" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)"
  if [[ " $current " == *" $2 "* ]]; then
    return 0
  elif [[ -z "$current" ]]; then
    kubectl patch serviceaccount default -n "$1" -p "{\"imagePullSecrets\":[{\"name\":\"$2\"}]}" >/dev/null
  else
    kubectl patch serviceaccount default -n "$1" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"$2\"}}]" >/dev/null
  fi
}

# ── Step 0: Preflight ────────────────────────────────────────────────────────
echo "=== Step 0: Preflight checks ==="
for bin in kubectl helm awk; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done

kubectl version >/dev/null 2>&1 || { echo "ERROR: cannot reach the cluster (check KUBECONFIG / --kubeconfig)" >&2; exit 1; }
K8S_MINOR="$(kubectl version -o json 2>/dev/null | awk -F'"' '/"serverVersion"/{s=1} s && /"minor"/{gsub(/[^0-9]/,"",$4); print $4; exit}')"
if [[ -n "$K8S_MINOR" && "$K8S_MINOR" -lt "$MIN_K8S_MINOR" ]]; then
  echo "ERROR: cluster runs Kubernetes 1.${K8S_MINOR}; the chart requires >= 1.${MIN_K8S_MINOR} (even for trainer-only)." >&2
  exit 1
fi
echo "  Kubernetes 1.${K8S_MINOR:-?} OK"

# Helm 4 is required: the install uses --server-side/--force-conflicts so Helm can take
# back fields the Trainer/JobSet controllers write at runtime (webhook caBundle). A
# release installed without server-side apply hits field-ownership conflicts when it
# is later upgraded with it.
HELM_MAJOR="$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
if [[ "${HELM_MAJOR:-0}" -lt 4 ]]; then
  echo "ERROR: Helm v${HELM_MAJOR:-?} found; Helm >= 4.0.1 is required." >&2
  exit 1
fi
SSA_ARGS=(--force-conflicts --server-side=true)
echo "  Helm v${HELM_MAJOR} OK"

# Refuse to turn an existing full-platform "kubeflow" release into trainer-only:
# the upgrade would delete every other component.
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  # The chart prints this banner only for trainer-only releases (kubeflow.trainerOnly
  # in templates/_helpers.tpl). Releases from charts without the trainer-only switches
  # never print it, and they are full-platform installs.
  if ! helm get notes "$RELEASE" -n "$NAMESPACE" 2>/dev/null | grep -Fq 'Kubeflow Trainer has been installed!'; then
    if [[ $FORCE -eq 1 ]]; then
      echo "  WARNING: release '$RELEASE' is not trainer-only; --force given, it will be converted (all other components are REMOVED)."
    else
      echo "ERROR: release '$RELEASE' in namespace '$NAMESPACE' exists and is not a trainer-only install." >&2
      echo "  Upgrading it with the trainer-only values would delete every other Kubeflow component." >&2
      echo "  Re-run with --force if that is really what you want." >&2
      exit 1
    fi
  else
    echo "  Existing trainer-only release '$RELEASE' found; it will be upgraded."
  fi
fi

# ── Step 1: Registry login ───────────────────────────────────────────────────
echo "=== Step 1: Helm registry login ==="
echo "$APPCO_REGISTRY_TOKEN" | helm registry login "${SUSE_APP_COLLECTION}" --username "$APPCO_REGISTRY_USER" --password-stdin
echo "$SUSE_AI_REGISTRY_TOKEN" | helm registry login "${SUSE_REGISTRY}" --username "$SUSE_AI_REGISTRY_USER" --password-stdin

# ── Step 2: Namespace (created up front and labelled so Helm can adopt it) ───
echo "=== Step 2: Create and label the $NAMESPACE namespace ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

# ── Step 3: Image pull secrets ───────────────────────────────────────────────
echo "=== Step 3: Create image pull secrets in $NAMESPACE ==="
create_pull_secret application-collection "$SUSE_APP_COLLECTION" "$APPCO_REGISTRY_USER" "$APPCO_REGISTRY_TOKEN" "$NAMESPACE"
create_pull_secret suse-ai-registry "$SUSE_REGISTRY" "$SUSE_AI_REGISTRY_USER" "$SUSE_AI_REGISTRY_TOKEN" "$NAMESPACE"

# ── Step 4: Prepare the chart ────────────────────────────────────────────────
if [[ $USE_OCI -eq 1 ]]; then
  echo "=== Step 4: Pull the released chart ${CHART_REF}${CHART_VERSION:+ (version $CHART_VERSION)} ==="
  VERSION_ARGS=()
  [[ -n "$CHART_VERSION" ]] && VERSION_ARGS=(--version "$CHART_VERSION")
  helm pull "$CHART_REF" "${VERSION_ARGS[@]}" --untar -d "$WORKDIR/pulled"
  PULLED_DIR="$(dirname "$(ls -d "$WORKDIR"/pulled/*/Chart.yaml | head -1)")"
  # Pin the install to exactly the version that was pulled and checked.
  CHART_VERSION="$(awk '/^version:/{gsub(/"/,"",$2); print $2; exit}' "$PULLED_DIR/Chart.yaml")"
  if ! grep -q '^istioResources:' "$PULLED_DIR/values.yaml"; then
    echo "ERROR: chart version $CHART_VERSION does not support trainer-only installs (no istioResources.enabled switch)." >&2
    echo "  Use a newer release, or install from this checkout (run without --oci/--chart-version/--chart-ref)." >&2
    exit 1
  fi
  # Use the preset shipped with that chart version, so the values match the release.
  VALUES_FILE="$PULLED_DIR/trainer-only-overrides.yaml"
  SAMPLE_FILE="$PULLED_DIR/tutorial/trainer/trainjob_torch_hello.yaml"
  CHART_ARGS=("$CHART_REF" --version "$CHART_VERSION")
  echo "  Using released chart version $CHART_VERSION"
else
  echo "=== Step 4: Package Kubeflow sub-charts (source checkout) ==="
  # Remove stale tarballs of local (file://) sub-charts so they are repackaged from
  # source. `dependency build` installs exactly what Chart.lock pins (and fails if
  # Chart.yaml drifted from it) instead of rewriting the lock like `update` does.
  grep -B2 'repository:.*file://' "$SCRIPT_DIR/Chart.yaml" \
    | grep '^\s*-\s*name:\|^\s*name:' \
    | awk '{print $NF}' | tr -d '"' \
    | while read -r chart_name; do rm -f "$SCRIPT_DIR/charts/${chart_name}"-*.tgz; done || true
  helm dependency build "$SCRIPT_DIR"
  CHART_ARGS=("$SCRIPT_DIR")
fi

[[ -f "$VALUES_FILE" ]] \
  || { echo "ERROR: trainer-only preset not found: $VALUES_FILE" >&2; exit 1; }
echo "  Using trainer-only values from $VALUES_FILE"

# ── Step 5: Install ──────────────────────────────────────────────────────────
echo "=== Step 5: Install Kubeflow Trainer (trainer-only) ==="
RUNTIME_ARGS=()
[[ $INSTALL_RUNTIMES -eq 0 ]] && RUNTIME_ARGS=(--set trainer.runtimes.enabled=false)
helm upgrade --install "$RELEASE" "${CHART_ARGS[@]}" \
  -n "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --set global.suseRegistry="${SUSE_REGISTRY}" \
  --set global.suseApplicationCollectionRegistry="${SUSE_APP_COLLECTION}" \
  "${RUNTIME_ARGS[@]}" \
  "${EXTRA_VALUES[@]}" \
  "${SSA_ARGS[@]}" \
  --wait --timeout 10m

# ── Step 6: Verify ───────────────────────────────────────────────────────────
echo "=== Step 6: Verify ==="
kubectl rollout status deploy/kubeflow-trainer-controller-manager -n "$NAMESPACE" --timeout=5m
kubectl rollout status deploy/jobset-controller-manager -n "$NAMESPACE" --timeout=5m 2>/dev/null \
  || echo "  (jobset-controller-manager not found; trainer.jobset.controller.enabled=false?)"
kubectl get crd trainjobs.trainer.kubeflow.org trainingruntimes.trainer.kubeflow.org \
  clustertrainingruntimes.trainer.kubeflow.org jobsets.jobset.x-k8s.io
echo "ClusterTrainingRuntimes:"
kubectl get clustertrainingruntimes 2>/dev/null || true
if [[ $RUN_TESTS -eq 1 ]]; then
  helm test "$RELEASE" -n "$NAMESPACE" --timeout 5m
fi

# ── Step 7: Sample TrainJob (optional) ───────────────────────────────────────
if [[ $RUN_SAMPLE -eq 1 ]]; then
  echo "=== Step 7: Sample TrainJob in namespace $SAMPLE_NS ==="
  if ! kubectl get clustertrainingruntime torch-distributed >/dev/null 2>&1; then
    echo "  SKIPPED: ClusterTrainingRuntime torch-distributed is not installed (--no-runtimes?)."
  elif [[ ! -f "$SAMPLE_FILE" ]]; then
    echo "  SKIPPED: sample manifest not found: $SAMPLE_FILE"
  else
    kubectl create namespace "$SAMPLE_NS" --dry-run=client -o yaml | kubectl apply -f -
    create_pull_secret suse-ai-registry "$SUSE_REGISTRY" "$SUSE_AI_REGISTRY_USER" "$SUSE_AI_REGISTRY_TOKEN" "$SAMPLE_NS"
    add_sa_pull_secret "$SAMPLE_NS" suse-ai-registry
    kubectl delete trainjob torch-hello -n "$SAMPLE_NS" --ignore-not-found --wait=true
    # Same manifest as Step 7 of docs/use-cases/trainer-only-install.md.
    kubectl apply -n "$SAMPLE_NS" -f "$SAMPLE_FILE"
    echo "  Waiting up to 15m for TrainJob torch-hello (the PyTorch image is large)..."
    RESULT=""
    for _ in $(seq 1 180); do
      COMPLETE="$(kubectl get trainjob torch-hello -n "$SAMPLE_NS" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
      FAILED="$(kubectl get trainjob torch-hello -n "$SAMPLE_NS" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
      if [[ "$COMPLETE" == "True" ]]; then RESULT=Complete; break; fi
      if [[ "$FAILED" == "True" ]]; then RESULT=Failed; break; fi
      sleep 5
    done
    kubectl get trainjob,jobset,pods -n "$SAMPLE_NS" || true
    echo "--- sample logs ---"
    kubectl logs -n "$SAMPLE_NS" -l jobset.sigs.k8s.io/jobset-name=torch-hello --tail=20 2>/dev/null || true
    case "$RESULT" in
      Complete)
        # Remove the finished sample so nothing keeps referencing the bundled runtime.
        kubectl delete trainjob torch-hello -n "$SAMPLE_NS" --wait=false >/dev/null
        echo "  Sample TrainJob completed and was deleted. Remove the namespace with: kubectl delete namespace $SAMPLE_NS" ;;
      Failed)   echo "ERROR: sample TrainJob failed (see above); left in $SAMPLE_NS for debugging." >&2; exit 1 ;;
      *)        echo "ERROR: sample TrainJob did not finish within 15m (see above); left in $SAMPLE_NS for debugging." >&2; exit 1 ;;
    esac
  fi
fi

echo ""
# Version of a running controller, from its image tag (or digest): image_version <deployment>
image_version() {
  local img
  img="$(kubectl get deploy "$1" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -z "$img" ]]; then echo "not deployed by this release"
  elif [[ "$img" == *@* ]]; then echo "${img##*@}"
  else echo "${img##*:}"
  fi
}

echo "=== Kubeflow Trainer installed successfully! ==="
echo ""
echo "  Trainer:    $(image_version kubeflow-trainer-controller-manager)"
echo "  JobSet:     $(image_version jobset-controller-manager)"
echo "  Release:    $RELEASE (namespace $NAMESPACE)"
if [[ $USE_OCI -eq 1 ]]; then
  echo "  Chart:      $CHART_REF version $CHART_VERSION"
else
  echo "  Chart:      $SCRIPT_DIR (source checkout)"
fi
echo "  Runtimes:   kubectl get clustertrainingruntimes"
echo "  TrainJobs run in any namespace; each needs a registry.suse.com pull secret on its"
echo "  default ServiceAccount. See docs/use-cases/trainer-only-install.md, Step 7."
echo ""
echo "  Uninstalling ('helm uninstall $RELEASE -n $NAMESPACE') keeps the Trainer and JobSet CRDs (and any TrainJobs/JobSets)."
