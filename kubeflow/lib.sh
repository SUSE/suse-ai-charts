# shellcheck shell=bash
# Shared install steps for install.sh (sourced, not run). Expects SCRIPT_DIR, WORKDIR, RELEASE and NAMESPACE.

CERT_MANAGER_VERSION=1.20.2
ISTIO_CHART_VERSION=1.3.0
ESO_VERSION=2.6.0
MIN_K8S_MINOR=35   # Chart.yaml kubeVersion: >=1.35.0-0

die() { echo "ERROR: $*" >&2; exit 1; }

# Value of a "# <key>: ..." header line in a preset file: preset_meta <file> <key>
preset_meta() {
  sed -n "s/^# $2:[[:space:]]*//p" "$1" | head -1
}

# Fail early on missing tools, an unreachable or too old cluster, or Helm < 4.
check_prerequisites() {
  local bin major
  for bin in kubectl helm awk sed; do
    command -v "$bin" >/dev/null || die "$bin not found in PATH"
  done
  kubectl version >/dev/null 2>&1 || die "cannot reach the cluster (check KUBECONFIG / --kubeconfig)"
  K8S_MINOR="$(kubectl version -o json 2>/dev/null | awk -F'"' '/"serverVersion"/{s=1} s && /"minor"/{gsub(/[^0-9]/,"",$4); print $4; exit}')"
  if [[ -n "$K8S_MINOR" && "$K8S_MINOR" -lt "$MIN_K8S_MINOR" ]]; then
    die "cluster runs Kubernetes 1.${K8S_MINOR}; the chart requires >= 1.${MIN_K8S_MINOR}."
  fi
  echo "  Kubernetes 1.${K8S_MINOR:-?} OK"
  # The install uses --server-side/--force-conflicts (Helm 4) so Helm can take back fields
  # controllers write at runtime (webhook caBundle, aggregated ClusterRole rules).
  major="$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  [[ "${major:-0}" -ge 4 ]] || die "Helm v${major:-?} found; Helm >= 4.0.1 is required."
  echo "  Helm v${major} OK"
}

registry_login() {
  printf '%s' "$APPCO_REGISTRY_TOKEN" | helm registry login "$SUSE_APP_COLLECTION" --username "$APPCO_REGISTRY_USER" --password-stdin
  printf '%s' "$SUSE_AI_REGISTRY_TOKEN" | helm registry login "$SUSE_REGISTRY" --username "$SUSE_AI_REGISTRY_USER" --password-stdin
}

ensure_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

# Let the kubeflow release adopt a namespace created before it: adopt_namespace <namespace>
adopt_namespace() {
  kubectl label namespace "$1" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$1" meta.helm.sh/release-name="$RELEASE" \
    meta.helm.sh/release-namespace="$NAMESPACE" --overwrite
}

# Create or update a docker-registry secret: create_pull_secret <name> <server> <user> <token> <namespace>
# The credentials go through a 0600 file, not kubectl arguments, so they never show up in `ps`.
create_pull_secret() {
  local cfg="$WORKDIR/dockerconfig-$1.json" auth
  auth="$(printf '%s:%s' "$3" "$4" | base64 | tr -d '\n')"
  (umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$2" "$auth" > "$cfg")
  kubectl create secret generic "$1" --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$cfg" -n "$5" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$cfg"
}

# Both registry pull secrets in a namespace: create_pull_secrets <namespace>
create_pull_secrets() {
  create_pull_secret application-collection "$SUSE_APP_COLLECTION" "$APPCO_REGISTRY_USER" "$APPCO_REGISTRY_TOKEN" "$1"
  create_pull_secret suse-ai-registry "$SUSE_REGISTRY" "$SUSE_AI_REGISTRY_USER" "$SUSE_AI_REGISTRY_TOKEN" "$1"
}

# Generic secret with one key, value via a 0600 file: create_key_secret <name> <key> <value> <namespace>
create_key_secret() {
  local f="$WORKDIR/secret-$1"
  (umask 077; printf '%s' "$3" > "$f")
  kubectl create secret generic "$1" --from-file="$2=$f" -n "$4" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$f"
}

# Add a pull secret to a namespace's default ServiceAccount, keeping existing entries.
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

install_cert_manager() {
  helm upgrade --install cert-manager "oci://${SUSE_APP_COLLECTION}/charts/cert-manager" \
    --version "$CERT_MANAGER_VERSION" --namespace cert-manager \
    --set crds.enabled=true --set crds.keep=true \
    --set 'global.imagePullSecrets[0].name=application-collection' \
    --wait --timeout 5m
}

# install_istio <native|envoyfilter> <true|false (istio-cni)>
install_istio() {
  local args=()
  # native ext_authz needs the oauth2-proxy provider in istiod MeshConfig; envoyfilter doesn't.
  [[ "$1" == native ]] && args+=(--values "$SCRIPT_DIR/istio-native-authz-values.yaml")
  if [[ "$2" == true ]]; then
    args+=(--values "$SCRIPT_DIR/istio-cni-values.yaml")
    # K3s (also Rancher Desktop) keeps CNI binaries/config under /var/lib/rancher/k3s.
    if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | grep -q '+k3s'; then
      echo "  K3s detected: installing istio-cni with --set global.platform=k3s"
      args+=(--set global.platform=k3s)
    fi
  fi
  helm upgrade --install istio "oci://${SUSE_APP_COLLECTION}/charts/istio" \
    --version "$ISTIO_CHART_VERSION" --namespace istio-system \
    --set 'global.imagePullSecrets[0].name=application-collection' --set gateway.enabled=true \
    "${args[@]}" --force-conflicts --server-side=true --wait --timeout 5m
}

install_eso() {
  helm upgrade --install external-secrets-operator "oci://${SUSE_APP_COLLECTION}/charts/external-secrets-operator" \
    --version "$ESO_VERSION" --namespace "$NAMESPACE" --set installCRDs=true \
    --set 'global.imagePullSecrets[0].name=application-collection' --wait --timeout 5m
  # The chart's ESO checks need the CRDs in the API server's discovery cache.
  kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io \
    crd/clusterexternalsecrets.external-secrets.io crd/externalsecrets.external-secrets.io --timeout=60s
}

# Package the local (file://) sub-charts of a checkout and fetch what Chart.lock pins.
# `dependency build` fails if Chart.yaml drifted from Chart.lock instead of rewriting the lock.
build_chart_dependencies() {
  grep -B2 'repository:.*file://' "$1/Chart.yaml" | grep '^\s*-\s*name:\|^\s*name:' \
    | awk '{print $NF}' | tr -d '"' \
    | while read -r chart_name; do rm -f "$1/charts/${chart_name}"-*.tgz; done || true
  helm dependency build "$1"
}

# Names of the presets in <chart-dir>/presets, space-separated: preset_names <chart-dir>
preset_names() {
  local f out=()
  for f in "$1"/presets/*.yaml; do out+=("$(basename "$f" .yaml)"); done
  echo "${out[*]}"
}

# Probe chart: the component registry (components.yaml) and its helpers (templates/_helpers.tpl) of
# <chart-dir> with its values.yaml, no sub-charts and no checks, so it evaluates any values offline.
# make_probe_chart <chart-dir>
make_probe_chart() {
  local probe="$WORKDIR/probe"
  mkdir -p "$probe/templates"
  printf 'apiVersion: v2\nname: kubeflow\nversion: 0.0.0\n' > "$probe/Chart.yaml"
  cp "$1/values.yaml" "$1/components.yaml" "$probe/"
  cp "$1/templates/_helpers.tpl" "$probe/templates/"
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: probe}' 'data:' \
    '  components: {{ include "kubeflow.enabledComponents" . | fromJsonArray | join "," | quote }}' \
    '  prerequisites: {{ include "kubeflow.clusterPrerequisites" . | quote }}' \
    > "$probe/templates/plan.yaml"
}

# Render the probe chart with these values into <file>; stop with helm's message if it fails.
# probe <file> [helm values args]...
probe() {
  local file="$1"; shift
  helm template "$RELEASE" "$WORKDIR/probe" -n "$NAMESPACE" "$@" > "$file" 2> "$WORKDIR/probe.err" \
    || die "cannot work out the components for these values:"$'\n'"$(cat "$WORKDIR/probe.err")"
}

# One field of a probe render: probe_field <file> <components|prerequisites>
probe_field() {
  sed -n "s/^  $2: \"\(.*\)\"$/\1/p" "$1"
}

# Items of comma list $1 that are not in comma list $2, space-separated.
missing_from() {
  local x out=()
  for x in ${1//,/ }; do [[ ",$2," == *",$x,"* ]] || out+=("$x"); done
  echo "${out[*]}"
}

# Version of a running controller, from its image tag (or digest): image_version <deployment>
image_version() {
  local img
  img="$(kubectl get deploy "$1" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -z "$img" ]]; then echo "not deployed by this release"
  elif [[ "$img" == *@* ]]; then echo "${img##*@}"
  else echo "${img##*:}"
  fi
}

verify_trainer() {
  kubectl rollout status deploy/kubeflow-trainer-controller-manager -n "$NAMESPACE" --timeout=5m
  kubectl rollout status deploy/jobset-controller-manager -n "$NAMESPACE" --timeout=5m 2>/dev/null \
    || echo "  (jobset-controller-manager not found; trainer.jobset.controller.enabled=false?)"
  kubectl get crd trainjobs.trainer.kubeflow.org trainingruntimes.trainer.kubeflow.org \
    clustertrainingruntimes.trainer.kubeflow.org jobsets.jobset.x-k8s.io
  echo "ClusterTrainingRuntimes:"
  kubectl get clustertrainingruntimes 2>/dev/null || true
}

# Run the torch-hello sample TrainJob: run_sample <namespace> <manifest>
run_sample() {
  local ns="$1" manifest="$2" result="" complete failed
  if ! kubectl get clustertrainingruntime torch-distributed >/dev/null 2>&1; then
    echo "  SKIPPED: ClusterTrainingRuntime torch-distributed is not installed (--no-runtimes?)."; return 0
  elif [[ ! -f "$manifest" ]]; then
    echo "  SKIPPED: sample manifest not found: $manifest"; return 0
  fi
  ensure_namespace "$ns"
  create_pull_secret suse-ai-registry "$SUSE_REGISTRY" "$SUSE_AI_REGISTRY_USER" "$SUSE_AI_REGISTRY_TOKEN" "$ns"
  add_sa_pull_secret "$ns" suse-ai-registry
  kubectl delete trainjob torch-hello -n "$ns" --ignore-not-found --wait=true
  # Same manifest as Step 7 of docs/use-cases/trainer-only-install.md.
  kubectl apply -n "$ns" -f "$manifest"
  echo "  Waiting up to 15m for TrainJob torch-hello (the PyTorch image is large)..."
  for _ in $(seq 1 180); do
    complete="$(kubectl get trainjob torch-hello -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(kubectl get trainjob torch-hello -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [[ "$complete" == "True" ]]; then result=Complete; break; fi
    if [[ "$failed" == "True" ]]; then result=Failed; break; fi
    sleep 5
  done
  kubectl get trainjob,jobset,pods -n "$ns" || true
  echo "--- sample logs ---"
  kubectl logs -n "$ns" -l jobset.sigs.k8s.io/jobset-name=torch-hello --tail=20 2>/dev/null || true
  case "$result" in
    Complete)
      # Remove the finished sample so nothing keeps referencing the bundled runtime.
      kubectl delete trainjob torch-hello -n "$ns" --wait=false >/dev/null
      echo "  Sample TrainJob completed and was deleted. Remove the namespace with: kubectl delete namespace $ns" ;;
    Failed) die "sample TrainJob failed (see above); left in $ns for debugging." ;;
    *)      die "sample TrainJob did not finish within 15m (see above); left in $ns for debugging." ;;
  esac
}

# How to reach the dashboard through the Istio gateway.
print_access() {
  local http_port node_ip
  echo "Access:"
  # Rancher Desktop / WSL2: NodePorts are not reachable from Windows.
  if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}' 2>/dev/null | grep -qi 'WSL\|microsoft'; then
    echo "  Rancher Desktop detected — NodePorts are not directly reachable from Windows."
    echo "  Use port-forward (run in a separate terminal, keep it open):"
    echo ""
    echo "    kubectl port-forward svc/istio -n istio-system 8080:80"
    echo "    Open http://localhost:8080"
    echo ""
    echo "  Or use Rancher Desktop GUI → Port Forwarding → forward istio:80 in istio-system"
  else
    http_port="$(kubectl get svc istio -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
    if [[ -n "$http_port" ]]; then
      node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
      echo "  NodePort (HTTP):  http://${node_ip}:${http_port}"
    else
      echo "  kubectl port-forward svc/istio -n istio-system 8080:80"
      echo "  Open http://localhost:8080"
    fi
  fi
  echo "  (for named hostname + TLS, see README External Access section)"
  echo ""
  print_login
}

# How to log in, from the kubeflow-initial-user Secret: the demo password, the command that reads a
# generated one (never the password itself), or the identity provider when Dex's password login is off.
print_login() {
  local email hash has_password
  email="$(kubectl get secret kubeflow-initial-user -n "$NAMESPACE" -o jsonpath='{.data.email}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  hash="$(kubectl get secret kubeflow-initial-user -n "$NAMESPACE" -o jsonpath='{.data.hash}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  has_password="$(kubectl get secret kubeflow-initial-user -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  echo "Login:"
  if [[ -z "$hash" ]]; then
    echo "  Through your identity provider (Dex connectors)."
    return
  fi
  echo "  Email:    ${email:-user@example.com}"
  if [[ "$hash" == '$2y$12$arGZ9p14vTUDsOg/GZ6DRu8UjXxtB60UI3A1Api5/UXjdBz5qTEjm' ]]; then
    echo "  Password: 12341234  (demo password; never use it in production)"
  elif [[ -n "$has_password" ]]; then
    echo "  Password: kubectl -n $NAMESPACE get secret kubeflow-initial-user -o jsonpath='{.data.password}' | base64 -d"
  else
    echo "  Password: the one whose hash you set in auth.initialUser.passwordHash"
  fi
}
