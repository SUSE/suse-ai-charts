#!/usr/bin/env bash
# CI: helm template (notebooks + Trainer preset). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow \
  --set global.demoMode=true -f kubeflow/presets/notebooks-trainer.yaml)"
srcs="$(grep -oE '^# Source: kubeflow/charts/[^/]+' <<<"$out" | sed 's|.*/||' | sort -u | tr '\n' ' ')"
want='admission-webhook central-dashboard dex jupyter-web-app kubeflow-istio-resources kubeflow-namespace kubeflow-roles notebook-controller oauth2-proxy profiles-and-kfam trainer user-namespace '
[ "$srcs" = "$want" ] \
  || { echo "FAIL: notebooks + Trainer preset renders sub-charts '$srcs', want '$want'." >&2; exit 1; }
# The dashboard menu must link only to apps this preset installs.
links="$(grep -oE '"link": "/[^"]*"' <<<"$out" | sort -u | tr '\n' ' ')"
[ "$links" = '"link": "/jupyter/" "link": "/jupyter/new?namespace=kubeflow" ' ] \
  || { echo "FAIL: dashboard links to apps the preset does not install: $links" >&2; exit 1; }
# No KServe or Knative here, so no KServe inference gateway; adding KServe back must re-enable it.
if grep -q 'name: kserve-ingress-gateway$' <<<"$out"; then
  echo "FAIL: notebooks + Trainer preset renders the unused kserve-ingress-gateway." >&2; exit 1
fi
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    -f kubeflow/presets/notebooks-trainer.yaml --set kserve.enabled=true --set knativeServing.enabled=true >/dev/null 2>&1; then
  echo "FAIL: KServe on with global.kserve.gateway.enabled=false rendered." >&2; exit 1
fi
echo "OK: notebooks + Trainer preset renders only its components and dashboard links."
