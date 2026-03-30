#!/usr/bin/env bash
# Kubeflow deployment script
# Usage:
#   ./runMe.sh <appco-registry-username> <appco-registry-token> <suse-ai-registry-username> <suse-ai-registry-token> [--cloudflare-api-key <CloudFlare API Key>] [-f | --values-file <path to values.yaml file>] [--kubeconfig <path>]
# Or set env vars:
#   APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token> SUSE_AI_REGISTRY_USER=<user> SUSE_AI_REGISTRY_TOKEN=<token> [CLOUDFLARE_API_KEY=<CloudFlare API Key>] [KUBECONFIG=<path>] ./runMe.sh

set -euo pipefail

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


CUSTOM_VALUES_FILE=
VALUES_ARGUMENT=
while [ $# -gt 0 ] ; do
  case "$1" in
    -f | --values-file)
      if [ -n "${2-}" ]; then
        CUSTOM_VALUES_FILE="$2"
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
    *)
      # for now assume they are AppCo cred args and SUSE registry cred args
      shift
      ;;
  esac
done

if [ -n "$CUSTOM_VALUES_FILE" ]; then
  if [ ! -f $CUSTOM_VALUES_FILE ]; then
    echo "ERROR: unable to access values file $CUSTOM_VALUES_FILE. Please make sure it exist or accessible."
    exit 1
  fi
  VALUES_ARGUMENT="--values $CUSTOM_VALUES_FILE"
fi

if [[ -z "$APPCO_REGISTRY_USER" || -z "$APPCO_REGISTRY_TOKEN" || -z "$SUSE_AI_REGISTRY_USER" || -z "$SUSE_AI_REGISTRY_TOKEN" ]]; then
  echo "Usage: $0 <appco-registry-username> <appco-registry-token> <suse-ai-registry-username> <suse-ai-registry-token>"
  echo "  or set APPCO_REGISTRY_USER, APPCO_REGISTRY_TOKEN, SUSE_AI_REGISTRY_USER, and SUSE_AI_REGISTRY_TOKEN environment variables"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helm registry logins
echo "=== Step 1: Helm registry login ==="
echo "$APPCO_REGISTRY_TOKEN" | helm registry login dp.apps.rancher.io --username "$APPCO_REGISTRY_USER" --password-stdin
echo "$SUSE_AI_REGISTRY_TOKEN" | helm registry login registry.suse.com --username "$SUSE_AI_REGISTRY_USER" --password-stdin

echo "=== Step 2 & 3: Create namespaces and all the required secrets ==="
for ns in cert-manager istio-system kubeflow kubeflow-user-example-com; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry application-collection \
    --docker-server=dp.apps.rancher.io \
    --docker-username="$APPCO_REGISTRY_USER" \
    --docker-password="$APPCO_REGISTRY_TOKEN" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry suse-ai-registry \
    --docker-server=registry.suse.com \
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
for ns in kubeflow kubeflow-user-example-com; do
  kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$ns" \
    meta.helm.sh/release-name=kubeflow \
    meta.helm.sh/release-namespace=kubeflow \
    --overwrite
done

echo "=== Step 5: Install cert-manager ==="
helm upgrade --install cert-manager oci://dp.apps.rancher.io/charts/cert-manager \
  --version 1.19.3 \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m

echo "=== Step 6: Install Istio ==="
helm upgrade --install istio oci://dp.apps.rancher.io/charts/istio \
  --version 1.1.3 \
  --namespace istio-system \
  --set global.imagePullSecrets[0].name=application-collection \
  --set gateway.enabled=true \
  --force-conflicts \
  --server-side \
  --wait --timeout 5m

echo "=== Step 7: Package Kubeflow sub-charts ==="
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

echo "=== Step 8: Install Kubeflow ==="
# --force-conflicts: cert-manager-cainjector and the clusterrole-aggregation-controller
# modify fields (caBundle, aggregated .rules) that Helm's server-side apply tracks.
# --force-conflicts lets Helm reclaim ownership of those fields on each upgrade.
helm upgrade --install kubeflow "$SCRIPT_DIR" \
  -n kubeflow \
  --force-conflicts \
  --server-side \
  --wait --timeout 15m $VALUES_ARGUMENT

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
