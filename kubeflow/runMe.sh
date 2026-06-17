#!/usr/bin/env bash
# Kubeflow deployment script
# Usage:
#   ./runMe.sh <appco-registry-username> <appco-registry-token> <suse-ai-registry-username> <suse-ai-registry-token> [--cloudflare-api-key <CloudFlare API Key>] [-f | --values-file <path to values.yaml file>] [--kubeconfig <path>] [--disable-cert-manager]
# Or set env vars:
#   APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token> SUSE_AI_REGISTRY_USER=<user> SUSE_AI_REGISTRY_TOKEN=<token> [CLOUDFLARE_API_KEY=<CloudFlare API Key>] [KUBECONFIG=<path>] ./runMe.sh

set -euo pipefail

SUSE_REGISTRY=registry.suse.com        # override with --suse-registry=
SUSE_APP_COLLECTION=dp.apps.rancher.io  # override with --suse-app-collection=

# ── Credentials ──────────────────────────────────────────────────────────────
# Collect non-flag positional args first so flags like --kubeconfig aren't
# mistakenly treated as the registry username/token.
_pos=(); _skip=false
for _a in "$@"; do
  if $_skip; then _skip=false; continue; fi
  case "$_a" in
    --kubeconfig|--cloudflare-api-key|-f|--values-file) _skip=true ;;
    --*) ;;
    *) _pos+=("$_a") ;;
  esac
done
APPCO_REGISTRY_USER="${_pos[0]:-${APPCO_REGISTRY_USER:-}}"
APPCO_REGISTRY_TOKEN="${_pos[1]:-${APPCO_REGISTRY_TOKEN:-}}"
SUSE_AI_REGISTRY_USER="${_pos[2]:-${SUSE_AI_REGISTRY_USER:-regcode}}"
SUSE_AI_REGISTRY_TOKEN="${_pos[3]:-${SUSE_AI_REGISTRY_TOKEN:-}}"
unset _pos _a _skip

: ${CLOUDFLARE_API_KEY:=""}


VALUES_ARGUMENT=
ENABLE_CERT_MANAGER=1
while [ $# -gt 0 ] ; do
  case "$1" in
    -f | --values-file)
      if [ -n "${2-}" ]; then
        VALUES_ARGUMENT="$VALUES_ARGUMENT --values $2"
	shift
      else
	echo "ERROR: values file must be specified with $1 argument"
	exit 1
      fi
      ;;
    --cloudflare-api-key)
      if [ -n "${2-}" ]; then
        CLOUDFLARE_API_KEY="$2"
        shift
      else
        echo "ERROR: CloudFlare API key must be specified with $1 argument"
        exit 1
      fi
      ;;
    --kubeconfig)
      if [ -n "${2-}" ]; then
        export KUBECONFIG="$2"
        shift
      else
        echo "ERROR: kubeconfig path must be specified with $1 argument"
        exit 1
      fi
      ;;
    --disable-external-dns)
      ENABLE_EXTERNAL_DNS=0
      shift
      ;;
    --disable-cert-manager)
      ENABLE_CERT_MANAGER=0
      shift
      ;;
    --suse-registry=*)
      SUSE_REGISTRY="${1#*=}"
      shift
      ;;
    --suse-app-collection=*)
      SUSE_APP_COLLECTION="${1#*=}"
      shift
      ;;
    *)
      # for now assume they are AppCo cred args and SUSE registry cred args
      shift
      ;;
  esac
done

# kubeflow-user-example-com is intentionally excluded — ESO propagates registry secrets to user namespaces automatically.
NAMESPACES_TO_CREATE=("istio-system" "kubeflow" "knative-serving")
if [[ $ENABLE_CERT_MANAGER -eq 1 ]]; then
  NAMESPACES_TO_CREATE+=("cert-manager")
fi

if [[ -z "$APPCO_REGISTRY_USER" || -z "$APPCO_REGISTRY_TOKEN" || -z "$SUSE_AI_REGISTRY_USER" || -z "$SUSE_AI_REGISTRY_TOKEN" ]]; then
  echo "Usage: $0 <appco-registry-username> <appco-registry-token> <suse-ai-registry-username> <suse-ai-registry-token>"
  echo "  or set APPCO_REGISTRY_USER, APPCO_REGISTRY_TOKEN, SUSE_AI_REGISTRY_USER, and SUSE_AI_REGISTRY_TOKEN environment variables"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helm registry logins
echo "=== Step 1: Helm registry login ==="
echo "$APPCO_REGISTRY_TOKEN" | helm registry login "${SUSE_APP_COLLECTION}" --username "$APPCO_REGISTRY_USER" --password-stdin
echo "$SUSE_AI_REGISTRY_TOKEN" | helm registry login "${SUSE_REGISTRY}" --username "$SUSE_AI_REGISTRY_USER" --password-stdin

echo "=== Step 2 & 3: Create namespaces and all the required secrets ==="
for ns in "${NAMESPACES_TO_CREATE[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry application-collection \
    --docker-server="${SUSE_APP_COLLECTION}" \
    --docker-username="$APPCO_REGISTRY_USER" \
    --docker-password="$APPCO_REGISTRY_TOKEN" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry suse-ai-registry \
    --docker-server="${SUSE_REGISTRY}" \
    --docker-username="$SUSE_AI_REGISTRY_USER" \
    --docker-password="$SUSE_AI_REGISTRY_TOKEN" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# Create the CloudFlare API key secret for external-dns
if [ -n "$CLOUDFLARE_API_KEY" ]; then
  kubectl create secret generic cloudflare-api-key --from-literal=apiKey="$CLOUDFLARE_API_KEY" -n kubeflow \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflare-api-key --from-literal=apiKey="$CLOUDFLARE_API_KEY" -n cert-manager \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "=== Step 4: Label kubeflow namespaces for Helm ==="
for ns in kubeflow knative-serving; do
  kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$ns" \
    meta.helm.sh/release-name=kubeflow \
    meta.helm.sh/release-namespace=kubeflow \
    --overwrite
done

echo "=== Step 5: Optionally install cert-manager ==="
if [[ $ENABLE_CERT_MANAGER -eq 1 ]]; then
  helm upgrade --install cert-manager oci://${SUSE_APP_COLLECTION}/charts/cert-manager \
    --version 1.19.3 \
    --namespace cert-manager \
    --set crds.enabled=true \
    --set crds.keep=true \
    --set global.imagePullSecrets[0].name=application-collection \
    --wait --timeout 5m
fi

echo "=== Step 6: Install Istio ==="
helm upgrade --install istio oci://${SUSE_APP_COLLECTION}/charts/istio \
  --version 1.1.3 \
  --namespace istio-system \
  --set global.imagePullSecrets[0].name=application-collection \
  --set gateway.enabled=true \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 5m

echo "=== Step 7: Install External Secrets Operator ==="
helm upgrade --install external-secrets-operator oci://${SUSE_APP_COLLECTION}/charts/external-secrets-operator \
  --version 2.3.0 \
  --namespace kubeflow \
  --set installCRDs=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m

# Wait for ESO CRDs to be fully established in the API server discovery cache
# before the Kubeflow chart validates ClusterSecretStore / ClusterExternalSecret.
kubectl wait --for=condition=Established \
  crd/clustersecretstores.external-secrets.io \
  crd/clusterexternalsecrets.external-secrets.io \
  crd/externalsecrets.external-secrets.io \
  --timeout=60s

echo "=== Step 8: Package Kubeflow sub-charts ==="
# Remove stale tarballs for local (file://) sub-charts so helm dependency update
# always repackages them from source. External OCI/repo charts are left in place
# and redownloaded only when their version changes.
grep -B2 'repository:.*file://' "$SCRIPT_DIR/Chart.yaml" \
  | grep '^\s*-\s*name:\|^\s*name:' \
  | awk '{print $NF}' \
  | tr -d '"' \
  | while read -r chart_name; do
      rm -f "$SCRIPT_DIR/charts/${chart_name}"-*.tgz
    done || true

helm dependency update "$SCRIPT_DIR"

echo "=== Step 9: Install Kubeflow ==="
# --force-conflicts: cert-manager-cainjector and the clusterrole-aggregation-controller
# modify fields (caBundle, aggregated .rules) that Helm's server-side apply tracks.
# --force-conflicts lets Helm reclaim ownership of those fields on each upgrade.
helm upgrade --install kubeflow "$SCRIPT_DIR" \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m \
  --set global.suseRegistry="${SUSE_REGISTRY}" \
  --set global.suseApplicationCollection="${SUSE_APP_COLLECTION}" \
  $VALUES_ARGUMENT

echo ""
echo ""
echo "=== Kubeflow installed successfully! ==="
echo ""
echo "Access:"
# Detect Rancher Desktop / WSL2 (node name contains 'rancher' or kernel contains 'WSL')
IS_RANCHER_DESKTOP=false
if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}' 2>/dev/null | grep -qi 'WSL\|microsoft'; then
  IS_RANCHER_DESKTOP=true
fi
HTTP_PORT=$(kubectl get svc istio -n istio-system \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)
if [[ "$IS_RANCHER_DESKTOP" == "true" ]]; then
  echo "  Rancher Desktop detected — NodePorts are not directly reachable from Windows."
  echo "  Use port-forward (run in a separate terminal, keep it open):"
  echo ""
  echo "    kubectl port-forward svc/istio -n istio-system 8080:80"
  echo "    Open http://localhost:8080"
  echo ""
  echo "  Or use Rancher Desktop GUI → Port Forwarding → forward istio:80 in istio-system"
elif [[ -n "$HTTP_PORT" ]]; then
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  echo "  NodePort (HTTP):  http://${NODE_IP}:${HTTP_PORT}"
else
  echo "  kubectl port-forward svc/istio -n istio-system 8080:80"
  echo "  Open http://localhost:8080"
fi
echo "  (for named hostname + TLS, see README External Access section)"
echo ""
echo "Default credentials (CHANGE IN PRODUCTION):"
echo "  Email:    user@example.com"
echo "  Password: 12341234"
