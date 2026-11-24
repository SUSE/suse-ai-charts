#!/usr/bin/env bash
# CI: helm template (default values). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
# A plain `>/dev/null` only proves helm exits 0. It would stay green if the
# wildcard-TLS flattening became UNCONDITIONAL — i.e. the
# `if global.kserve.externalHttps` guard on the knative-serving
# domainTemplate helper were dropped. That single-label
# ({name}-{namespace}.{domain}) route host is only correct under the opt-in;
# on the default path it changes every Knative route's host and breaks
# net-istio readiness for installs that never asked for wildcard TLS. So
# render with DEFAULT values (no opt-in) and assert the flattened form is
# ABSENT — the guard must keep it opt-in only.
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true)"
if grep -Fq '{{ .Name }}-{{ .Namespace }}.{{ .Domain }}' <<<"$out"; then
  echo "FAIL: default (non-opt-in) render contains the flattened Knative domainTemplate — the wildcard-TLS flattening is applied unconditionally instead of being gated on global.kserve.externalHttps." >&2
  exit 1
fi
# config-network should omit domain-template entirely on the default path
# (Knative's dotted upstream default), not carry an empty/flattened one.
if grep -Fq 'domain-template:' <<<"$out"; then
  echo "FAIL: default render sets a Knative 'domain-template' — it must be omitted (upstream dotted default) unless the opt-in is enabled." >&2
  exit 1
fi

# kserve-ingress-gateway on the default path must serve '*.example.com' (not any wildcard like '*')
# to prevent cleartext routing widening regressions.
kserve_gw="$(awk 'BEGIN{RS="---\n"} /kind: Gateway/ && /name: kserve-ingress-gateway/{print}' <<<"$out")"
[ -n "$kserve_gw" ] \
  || { echo "FAIL: could not isolate the kserve-ingress-gateway document in default render." >&2; exit 1; }
grep -Fq '*.example.com' <<<"$kserve_gw" \
  || { echo "FAIL: default (non-opt-in) kserve-ingress-gateway does not scope hosts to '*.example.com'." >&2; exit 1; }

echo "OK: default render succeeds and leaves the Knative domainTemplate un-flattened (flattening stays gated on the opt-in)."

# The dex-jwt refresh hook (native gateway auth): its Role may only touch dex-jwt, and it must
# not render in EnvoyFilter mode, where there is no dex-jwt.
refresh="$(awk 'BEGIN{RS="---\n"} /dex-jwt-refresh/{print "---"; print}' <<<"$out")"
[ "$(grep -c '^kind: ' <<<"$refresh")" -eq 4 ] \
  || { echo "FAIL: expected the dex-jwt-refresh ServiceAccount, Role, RoleBinding and Job in native mode." >&2; exit 1; }
python3 -c '
import sys, yaml
role = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == "Role"][0]
assert role["rules"] == [{"apiGroups": ["security.istio.io"], "resources": ["requestauthentications"],
                          "resourceNames": ["dex-jwt"], "verbs": ["get", "patch"]}], role["rules"]
' <<<"$refresh" || { echo "FAIL: the dex-jwt-refresh Role grants more than get/patch on dex-jwt." >&2; exit 1; }
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
    -f kubeflow/values-envoyfilter-authz.yaml | grep -q 'dex-jwt-refresh'; then
  echo "FAIL: the dex-jwt-refresh hook renders in EnvoyFilter mode." >&2; exit 1
fi
echo "OK: the dex-jwt refresh hook renders only in native mode, with a Role limited to dex-jwt."

# Cookies: oauth2-proxy's session cookie and the web apps' CSRF cookie are Secure exactly when users
# browse over HTTPS (any global.tls.source, including edge); browsers drop Secure cookies on HTTP.
cookies() { python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
o2p = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ci-oauth2-proxy"][0]
e = [x for x in o2p["spec"]["template"]["spec"]["containers"][0]["env"] if x["name"] == "OAUTH2_PROXY_COOKIE_SECURE"]
assert e == [{"name": "OAUTH2_PROXY_COOKIE_SECURE", "value": sys.argv[1]}], e
apps = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] in ("jupyter-web-app-deployment", "volumes-web-app-deployment", "tensorboards-web-app-deployment")]
assert len(apps) == 3, [d["metadata"]["name"] for d in apps]
for d in apps:
    e = [x for x in d["spec"]["template"]["spec"]["containers"][0]["env"] if x["name"] == "APP_SECURE_COOKIES"]
    assert e == [{"name": "APP_SECURE_COOKIES", "value": sys.argv[1]}], (d["metadata"]["name"], e)
' "$1"; }
cookies false <<<"$out" || { echo "FAIL: a plain-HTTP render must leave both cookies without Secure." >&2; exit 1; }
for src in selfSigned edge; do
  helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
      --set global.tls.source=$src --set global.gateway.hostname=kf.example.com \
    | cookies true || { echo "FAIL: tls.source=$src must mark both cookies Secure." >&2; exit 1; }
done
# Standalone, the web apps can't know TLS: they must leave APP_SECURE_COOKIES unset (the app's
# own default is secure) rather than default it off.
for c in jupyter-web-app volumes-web-app tensorboards-web-app; do
  if helm template x ./kubeflow/charts/$c --set global.gateway.name=kubeflow/kubeflow-gateway | grep -q 'name: APP_SECURE_COOKIES'; then
    echo "FAIL: $c rendered standalone sets APP_SECURE_COOKIES; it must stay unset." >&2; exit 1
  fi
done
echo "OK: both cookies are Secure exactly with HTTPS (incl. edge); standalone web apps keep their secure default."
# The cookie setting lives in the pod spec (so a change rolls oauth2-proxy); a custom extraEnv without it is refused.
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
    --set-json 'oauth2-proxy.extraEnv=[{"name":"X","value":"y"}]' >/dev/null 2>&1; then
  echo "FAIL: an oauth2-proxy.extraEnv without OAUTH2_PROXY_COOKIE_SECURE rendered." >&2; exit 1
fi
# An extraEnv copied from 0.4-0.6 still reads the removed oauth2-proxy-dynamic-config ConfigMap: refused.
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
    --set-json 'oauth2-proxy.extraEnv=[{"name":"OAUTH2_PROXY_COOKIE_SECURE","valueFrom":{"configMapKeyRef":{"name":"oauth2-proxy-dynamic-config","key":"cookie-secure"}}}]' >/dev/null 2>&1; then
  echo "FAIL: an oauth2-proxy.extraEnv reading the removed oauth2-proxy-dynamic-config rendered." >&2; exit 1
fi
echo "OK: oauth2-proxy's cookie setting follows TLS in its pod spec; dropping it, or keeping the old ConfigMap entry, is refused."

# tls.source edge: TLS ends in front of the gateway, which serves plain HTTP and never redirects;
# no gateway Certificate or issuer.
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true \
    --set global.tls.source=edge --set global.gateway.hostname=kf.example.com | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
gw = [d for d in docs if d["kind"] == "Gateway" and d["metadata"]["name"] == "kubeflow-gateway"][0]
servers = [(s["port"]["number"], s["port"]["protocol"], s.get("tls")) for s in gw["spec"]["servers"]]
assert servers == [(80, "HTTP", None)], servers
own = [d["kind"] + "/" + d["metadata"]["name"] for d in docs if d["kind"] in ("Certificate", "Issuer", "ClusterIssuer")
       and d["metadata"]["name"] in ("kubeflow-gateway-tls", "kserve-wildcard-tls", "kubeflow-selfsigned", "kubeflow-letsencrypt")]
assert not own, own
' || { echo "FAIL: tls.source=edge must render a plain-HTTP gateway with no redirect and no gateway certificate." >&2; exit 1; }
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true --set global.tls.source=edge \
    --set global.gateway.hostname=kf.example.com --set global.kserve.externalHttps=true --set global.kserve.domain=models.example.com 2>&1)"; then
  echo "FAIL: tls.source=edge with kserve.externalHttps rendered; it is not supported yet." >&2; exit 1
fi
grep -qF 'is not supported with global.tls.source "edge"' <<<"$err" \
  || { echo "FAIL: edge + kserve.externalHttps failed, but not with the unsupported-combination error. Got:" >&2; echo "$err" >&2; exit 1; }
echo "OK: tls.source=edge serves plain HTTP without redirect or certificate, and refuses kserve.externalHttps."

# Moved values: every old key fails and names its new location (Helm accepts any key under global,
# so without the guard an old values file would silently fall back to defaults).
for kv in kubeflow-istio-resources.hostname=kf.example.com:global.gateway.hostname \
          kubeflow-istio-resources.externalDNSEnabled=true:global.gateway.externalDNS \
          kubeflow-istio-resources.tls.source=selfSigned:global.tls \
          kubeflow-istio-resources.kserveGateway.enabled=false:global.kserve.gateway.enabled \
          kubeflow-istio-resources.gateway.hosts[0]=x:removed \
          global.kserveDomain=models.example.com:global.kserve.domain \
          global.kserveExternalHttps=true:global.kserve.externalHttps \
          global.kserveGateway.name=a/b:global.kserve.gateway.name; do
  old="${kv%%:*}"; new="${kv##*:}"
  if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true --set "$old" 2>&1)"; then
    echo "FAIL: the removed key $old was accepted." >&2; exit 1
  fi
  grep -qF -- "-> $new" <<<"$err" || { echo "FAIL: $old failed without naming $new. Got:" >&2; echo "$err" >&2; exit 1; }
done
echo "OK: every moved key fails with its new location."

# No user-facing text may still point at a moved key (an error hint or doc telling users to set
# one would make their next upgrade fail). Allowed: the removed-key guard and the upgrade notes.
old='global\.kserveDomain|global\.kserveExternalHttps|global\.kserveGateway|kubeflow-istio-resources\.(hostname|externalDNSEnabled|tls\.|kserveGateway\.)|tls\.kserveExistingSecret|app-secure-cookies'
if hits="$(grep -rnE "$old" kubeflow/templates kubeflow/charts/*/templates kubeflow/values.yaml kubeflow/charts/*/values.yaml \
      kubeflow/values.schema.json kubeflow/charts/*/values.schema.json kubeflow/README.md.gotmpl kubeflow/docs kubeflow/tutorial.md \
    | grep -v -e 'kubeflow/docs/upgrade-notes.md' -e '\$moved = append \$moved')"; then
  echo "FAIL: moved keys are still referenced (use the global.gateway / global.tls / global.kserve names):" >&2; echo "$hits" >&2; exit 1
fi
echo "OK: no template, value or doc refers to a moved key."

# Bundled Trainer runtimes: every pod template lists global.imagePullSecrets, the Secrets ESO
# copies into profile namespaces (no ServiceAccount patching needed).
python3 -c '
import sys, yaml
def pods(o):
    if isinstance(o, dict):
        if "containers" in o: yield o
        for v in o.values(): yield from pods(v)
    elif isinstance(o, list):
        for x in o: yield from pods(x)
rts = []
for d in yaml.safe_load_all(sys.stdin):
    for v in ((d or {}).get("data") or {}).values():
        if isinstance(v, str) and "kind: ClusterTrainingRuntime" in v:
            rts += [x for x in yaml.safe_load_all(v) if x and x.get("kind") == "ClusterTrainingRuntime"]
assert rts, "no bundled runtimes found"
want = [{"name": "application-collection"}, {"name": "suse-ai-registry"}]
bad = [r["metadata"]["name"] for r in rts for p in pods(r) if p.get("imagePullSecrets") != want]
assert not bad, bad
print(len(rts), "runtimes")
' <<<"$out" || { echo "FAIL: a bundled Trainer runtime pod template lacks global.imagePullSecrets." >&2; exit 1; }
echo "OK: bundled Trainer runtimes reference the pull secrets."

# Hooks that warn and exit 0 instead of failing (profiles-cleanup, dex-jwt-refresh) must end within
# helm's default --timeout (5m, per hook; helm uninstall is documented without --timeout), or Helm
# gives up first and fails the operation anyway.
python3 -c '
import sys, yaml
jobs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Job"}
for name in ("profiles-cleanup", "dex-jwt-refresh"):
    assert name in jobs, name + " not rendered"
    t = jobs[name]["spec"].get("activeDeadlineSeconds")
    assert t and t < 300, f"{name} activeDeadlineSeconds={t}"
' <<<"$out" || { echo "FAIL: a never-fail hook may outlast helm default --timeout (5m)." >&2; exit 1; }
echo "OK: the never-fail hooks end within helm default --timeout."

# dex-jwt-refresh patches /spec/jwtRules/0 of dex-jwt (guarded by a test on the issuer): keep the
# rendered dex-jwt matching that (rule 0 = Dex issuer, no timeout) and the hook on the same issuer.
python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
ra = [d for d in docs if d["kind"] == "RequestAuthentication" and d["metadata"]["name"] == "dex-jwt"][0]
rule = ra["spec"]["jwtRules"][0]
job = [d for d in docs if d["kind"] == "Job" and d["metadata"]["name"] == "dex-jwt-refresh"][0]
script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
assert "timeout" not in rule, "dex-jwt rule 0 sets timeout"
assert "issuer=" + rule["issuer"] + "\n" in script, "hook issuer != dex-jwt rule 0 issuer " + rule["issuer"]
' <<<"$out" || { echo "FAIL: dex-jwt no longer matches what the dex-jwt-refresh hook patches." >&2; exit 1; }
echo "OK: dex-jwt matches the dex-jwt-refresh hook (rule 0 = Dex issuer, no timeout)."
