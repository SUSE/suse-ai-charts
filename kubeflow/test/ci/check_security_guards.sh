#!/usr/bin/env bash
# CI: helm template (opt-in security guards fail closed). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
# The external-HTTPS opt-in must be refused when the bundled oauth2-proxy
# (the gateway auth chain) is disabled — otherwise the wildcard server
# publishes the whole Kubeflow surface unauthenticated. Assert it FAILS,
# and that it fails for the RIGHT reason (the oauth2Proxy guard message),
# not some unrelated template error that would mask a regression.
# istioResources.externalAuth=true gets past the gateway-login guard: the opt-out
# must not lift this requirement.
if err="$(helm template ci ./kubeflow \
    --kube-version "$KUBE_VERSION" \
    --set global.demoMode=true \
    --set global.kserve.externalHttps=true \
    --set global.kserve.domain=kubeflow.example.com \
    --set global.oauth2Proxy.enabled=false \
    --set istioResources.externalAuth=true \
    --set global.gateway.hostname=kf.example.com \
    --set global.tls.source=letsEncrypt \
    --set global.tls.letsEncrypt.solver=cloudflare \
    --set global.tls.letsEncrypt.cloudflare.apiTokenSecretRef.name=cf-token \
    2>&1)"; then
  echo "FAIL: kserve.externalHttps with oauth2Proxy.enabled=false rendered" \
       "instead of failing closed." >&2
  exit 1
fi
# here-string (not `echo | grep -q`) to avoid a SIGPIPE/broken-pipe false
# failure under pipefail when grep -q short-circuits on the first match.
grep -q 'global.oauth2Proxy.enabled must be true' <<<"$err" \
  || { echo "FAIL: opt-in failed, but not on the oauth2Proxy guard. Got:" >&2
       echo "$err" >&2; exit 1; }
echo "OK: opt-in fails closed on the oauth2-proxy guard when it is disabled."
# The gateway must not run without login: oauth2-proxy off with Istio resources on
# fails unless istioResources.externalAuth=true says another layer authenticates.
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" \
    --set global.demoMode=true --set global.oauth2Proxy.enabled=false 2>&1)"; then
  echo "FAIL: oauth2Proxy.enabled=false with istioResources rendered instead of failing closed." >&2
  exit 1
fi
grep -qF 'the kubeflow-gateway would serve the Central Dashboard and every app without login' <<<"$err" \
  || { echo "FAIL: render failed, but not on the gateway-login guard. Got:" >&2; echo "$err" >&2; exit 1; }
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
    --set global.oauth2Proxy.enabled=false --set istioResources.externalAuth=true >/dev/null \
  || { echo "FAIL: istioResources.externalAuth=true did not allow oauth2Proxy.enabled=false." >&2; exit 1; }
echo "OK: the gateway-login guard fails closed and honours istioResources.externalAuth."
# externaldns.cloudflare.apiToken reaches external-dns through the default env; a custom
# env without CF_API_TOKEN would drop it silently, so that must fail.
dns=(--set global.demoMode=true --set externaldns.enabled=true --set externaldns.cloudflare.apiToken=ci-token)
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" "${dns[@]}")"
grep -q 'name: cloudflare-api-token$' <<<"$out" && grep -q 'name: CF_API_TOKEN$' <<<"$out" \
  || { echo "FAIL: apiToken did not render the cloudflare-api-token Secret and CF_API_TOKEN env." >&2; exit 1; }
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" "${dns[@]}" \
    --set-json 'externaldns.env=[{"name":"HTTPS_PROXY","value":"http://proxy:3128"}]' 2>&1)"; then
  echo "FAIL: apiToken with an env lacking CF_API_TOKEN rendered instead of failing." >&2; exit 1
fi
grep -qF 'has no CF_API_TOKEN' <<<"$err" \
  || { echo "FAIL: render failed, but not on the CF_API_TOKEN guard. Got:" >&2; echo "$err" >&2; exit 1; }
echo "OK: apiToken reaches external-dns, and a custom env that drops it is refused."
