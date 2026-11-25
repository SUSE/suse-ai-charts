#!/usr/bin/env bash
# Kubeflow deployment script: installs the full platform (install.sh --preset full), with
# cert-manager, Istio and the External Secrets Operator. For other presets use install.sh --preset <name>.
# Takes every install.sh option except --preset (./install.sh --help lists them).
# Usage:
#   ./runMe.sh <appco-registry-username> <appco-registry-token> <suse-ai-registry-username> <suse-ai-registry-token> [--cloudflare-api-token <Cloudflare API token>] [-f | --values-file <path to values.yaml file>] [--kubeconfig <path>] [--disable-cert-manager] [--legacy-authz] [--no-istio-cni] [--oci | --chart-version <v> | --chart-ref <ref>]
#
# Ingress-auth: native Istio ext_authz is the DEFAULT (registers the oauth2-proxy
# provider in istiod MeshConfig via istio-native-authz-values.yaml). Pass
# --legacy-authz to use the self-contained EnvoyFilter instead (BYO-istio; no
# MeshConfig change).
#
# Istio is installed with istio-cni (global.istio.cni=true); --no-istio-cni uses classic istio-init.
# Installs from this checkout; --oci, --chart-version or --chart-ref install the released chart.
# Or set env vars (keeps the tokens out of the process list):
#   APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token> SUSE_AI_REGISTRY_USER=<user> SUSE_AI_REGISTRY_TOKEN=<token> [CLOUDFLARE_API_TOKEN=<Cloudflare API token>] [KUBECONFIG=<path>] ./runMe.sh

set -euo pipefail

args=()
for _a in "$@"; do
  case "$_a" in
    -h | --help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    --preset)
      echo "ERROR: runMe.sh installs the full preset; for other presets run ./install.sh --preset <name> (see ./install.sh --help)" >&2; exit 1 ;;
    --disable-external-dns) ;;   # accepted by earlier versions, never had an effect
    *) args+=("$_a") ;;
  esac
done

# bash: a chart from `helm pull` keeps no execute bits.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --preset full "${args[@]}"
