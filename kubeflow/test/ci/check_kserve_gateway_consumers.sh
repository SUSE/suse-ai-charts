#!/usr/bin/env bash
# CI: helm template (assert global.kserve.gateway.name consumers stay in sync). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
# Assert that when global.kserve.gateway.name is overridden, all three consumers
# (kubeflow-istio-resources, knative-serving, and kserve) receive the same overridden values.
custom_ns="custom-namespace"
custom_name="custom-gateway-name"
out="$(helm template ci ./kubeflow \
  --kube-version "$KUBE_VERSION" \
  --set global.demoMode=true \
  --set global.kserve.domain=kubeflow.example.com \
  --set global.kserve.gateway.name="${custom_ns}/${custom_name}")"

# 1. kubeflow-istio-resources Gateway CRD metadata
# Extract metadata from the Gateway document named custom-name in custom-namespace
gw_doc="$(awk 'BEGIN{RS="---\n"} /kind: Gateway/ && /name: '"$custom_name"'/{print}' <<<"$out")"
[ -n "$gw_doc" ] \
  || { echo "FAIL: Gateway CRD with name '$custom_name' was not rendered." >&2; exit 1; }
grep -Eq 'namespace:[[:space:]]*'"$custom_ns" <<<"$gw_doc" \
  || { echo "FAIL: Gateway CRD namespace does not match overridden namespace '$custom_ns'." >&2; exit 1; }

# 2. knative-serving config-istio key "gateway.<namespace>.<name>"
grep -Fq "gateway.${custom_ns}.${custom_name}" <<<"$out" \
  || { echo "FAIL: knative-serving config-istio key is not 'gateway.${custom_ns}.${custom_name}'." >&2; exit 1; }

# 3. kserve inferenceservice-config "ingressGateway": "<namespace>/<name>"
grep -Fq "\"ingressGateway\":\"${custom_ns}/${custom_name}\"" <<<"$out" \
  || { echo "FAIL: kserve inferenceservice-config ingressGateway is not '${custom_ns}/${custom_name}'." >&2; exit 1; }

echo "OK: all three consumers of global.kserve.gateway.name are in sync under override ($custom_ns/$custom_name)."
