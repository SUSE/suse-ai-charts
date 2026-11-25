#!/usr/bin/env bash
# CI: helm template (generated credentials, extra pull-secret namespaces, Profiles uninstall hook). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
# The credentials default to "": generated and kept via lookup. Offline renders without
# demoMode must refuse that (each render would generate new ones) and list every such value.
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow 2>&1)"; then
  echo "FAIL: empty credentials rendered offline instead of failing." >&2; exit 1
fi
for v in auth.oidc.clientSecret auth.oidc.cookieSecret auth.initialUser.passwordHash pipelines.seaweedfs.accessKey pipelines.seaweedfs.secretKey; do
  grep -qF -- "  - $v" <<<"$err" || { echo "FAIL: the offline-generation error does not list $v. Got:" >&2; echo "$err" >&2; exit 1; }
done
# With cluster access (simulated: kubeflow.clusterVisible forced true in a copy) they are generated.
tmp="$(mktemp -d)"; cp -r kubeflow "$tmp/"
sed -i 's|{{- if lookup "v1" "Namespace" "" "kube-system" }}true{{ end -}}|true|' "$tmp/kubeflow/templates/_helpers.tpl"
! grep -q 'lookup "v1" "Namespace" "" "kube-system"' "$tmp/kubeflow/templates/_helpers.tpl" \
  || { echo "FAIL: could not force kubeflow.clusterVisible; update this sed." >&2; exit 1; }
# A real cluster also serves the ESO API (the externalSecrets guard checks it there too).
helm template ci "$tmp/kubeflow" --kube-version "$KUBE_VERSION" -n kubeflow --api-versions external-secrets.io/v1 \
  --set user-namespace.modelRegistry.db.embedded.existingSecret=mr-db > "$tmp/generated.yaml"
python3 - "$tmp/generated.yaml" <<'PY'
import base64, sys, yaml
s = {d["metadata"]["name"]: {**{k: base64.b64decode(v).decode() for k, v in (d.get("data") or {}).items()}, **(d.get("stringData") or {})}
     for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Secret"}
checks = [("kubeflow-oidc-client", "client-secret", 32), ("kubeflow-oidc-client", "cookie-secret", 32),
          ("kubeflow-initial-user", "password", 20), ("mlpipeline-minio-artifact", "accesskey", 20),
          ("mlpipeline-minio-artifact", "secretkey", 40)]
bad = [f"{n}.{k}" for n, k, l in checks if len(s.get(n, {}).get(k, "")) != l]
if not s.get("kubeflow-initial-user", {}).get("hash", "").startswith("$2a$"):
    bad.append("kubeflow-initial-user.hash (bcrypt)")
sys.exit(f"FAIL: not generated as expected: {', '.join(bad)}" if bad else 0)
PY
# With demoMode, empty credentials take the published demo values (no generation, works offline).
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true > "$tmp/demo.yaml"
python3 - "$tmp/demo.yaml" <<'PY'
import base64, sys, yaml
s = {d["metadata"]["name"]: {**{k: base64.b64decode(v).decode() for k, v in (d.get("data") or {}).items()}, **(d.get("stringData") or {})}
     for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Secret"}
want = {("kubeflow-oidc-client", "client-secret"): "pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok",
        ("kubeflow-initial-user", "hash"): "$2y$12$arGZ9p14vTUDsOg/GZ6DRu8UjXxtB60UI3A1Api5/UXjdBz5qTEjm",
        ("mlpipeline-minio-artifact", "accesskey"): "kubeflow"}
bad = [f"{n}.{k}" for (n, k), v in want.items() if s.get(n, {}).get(k) != v]
sys.exit(f"FAIL: demoMode did not fill in the demo value of: {', '.join(bad)}" if bad else 0)
PY
# An explicit demo password hash without demoMode is refused, like the other demo credentials.
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set auth.oidc.clientSecret=ci \
    --set auth.oidc.cookieSecret=ci-cookie-secret-0123456789abcde --set pipelines.seaweedfs.accessKey=ci-ak \
    --set pipelines.seaweedfs.secretKey=ci-sk --set user-namespace.modelRegistry.db.embedded.existingSecret=mr \
    --set-string 'auth.initialUser.passwordHash=$2y$12$arGZ9p14vTUDsOg/GZ6DRu8UjXxtB60UI3A1Api5/UXjdBz5qTEjm' 2>&1)"; then
  echo "FAIL: the demo password hash rendered without demoMode." >&2; exit 1
fi
grep -qF "SECURITY: auth.initialUser.passwordHash" <<<"$err" || { echo "FAIL: wrong error for the demo hash: $err" >&2; exit 1; }
# External identity provider (Dex connector, password login off): no password is generated or
# required, even offline, and the Secret Dex's env var references holds no password.
idp=(--set auth.oidc.clientSecret=ci --set auth.oidc.cookieSecret=ci-cookie-secret-0123456789abcde
     --set pipelines.seaweedfs.accessKey=ci-ak --set pipelines.seaweedfs.secretKey=ci-sk
     --set user-namespace.modelRegistry.db.embedded.existingSecret=mr
     --set dex.config.enablePasswordDB=false --set-json 'dex.config.staticPasswords=[]'
     --set-json 'dex.config.connectors=[{"type":"oidc","id":"corp","name":"Corp","config":{"issuer":"https://idp.example.com","clientID":"kf","clientSecret":"x","redirectURI":"http://kf.example.com/dex/callback"}}]')
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow "${idp[@]}" \
    -s templates/secrets/initial-user-Secret.yaml > "$tmp/idp.yaml" \
  || { echo "FAIL: an external identity provider still requires auth.initialUser.passwordHash." >&2; exit 1; }
grep -q '^  hash: ""$' "$tmp/idp.yaml" && ! grep -q '^  password:' "$tmp/idp.yaml" \
  || { echo "FAIL: kubeflow-initial-user holds a password although Dex's password login is off:" >&2; cat "$tmp/idp.yaml" >&2; exit 1; }
# oauth2-proxy's client is registered with Dex: without Dex it needs auth.oidc.existingSecret.
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    --set dex.enabled=false >/dev/null 2>&1; then
  echo "FAIL: oauth2-proxy without Dex and without auth.oidc.existingSecret rendered." >&2; exit 1
fi
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    --set dex.enabled=false --set auth.oidc.existingSecret=true >/dev/null \
  || { echo "FAIL: oauth2-proxy without Dex but with auth.oidc.existingSecret=true did not render." >&2; exit 1; }
# Dex reads the initial user's hash through an env var; dropping it must fail clearly.
if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    --set-json 'dex.envVars=[{"name":"KUBEFLOW_OIDC_CLIENT_SECRET","valueFrom":{"secretKeyRef":{"name":"kubeflow-oidc-client","key":"client-secret"}}}]' 2>&1)"; then
  echo "FAIL: dex.envVars without KUBEFLOW_INITIAL_USER_HASH rendered." >&2; exit 1
fi
grep -qF "keep the KUBEFLOW_INITIAL_USER_HASH entry" <<<"$err" || { echo "FAIL: wrong error for missing Dex env var: $err" >&2; exit 1; }
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    --set auth.initialUser.email=admin@example.org >/dev/null 2>&1; then
  echo "FAIL: auth.initialUser.email differing from Dex's staticPasswords email rendered." >&2; exit 1
fi
# externalSecrets.extraNamespaces adds name-matched namespaces; without it the selector is unchanged.
ces="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
  --set-json 'externalSecrets.extraNamespaces=["knative-serving"]' -s templates/external-secrets/ClusterExternalSecret.yaml)"
grep -q 'namespaceSelectors:' <<<"$ces" && grep -q -- '- knative-serving' <<<"$ces" \
  || { echo "FAIL: extraNamespaces did not add knative-serving to namespaceSelectors:" >&2; echo "$ces" >&2; exit 1; }
# An empty namespaceSelector must not join namespaceSelectors (it would match every namespace).
ces="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
  --set-json 'externalSecrets.extraNamespaces=["knative-serving"]' --set-json 'externalSecrets.namespaceSelector.matchLabels=null' \
  -s templates/external-secrets/ClusterExternalSecret.yaml)"
python3 - "$ces" <<'PY'
import base64, sys, yaml
for d in yaml.safe_load_all(sys.argv[1]):
    if d and d.get("kind") == "ClusterExternalSecret" and any(not sel for sel in d["spec"]["namespaceSelectors"]):
        sys.exit("FAIL: an empty selector in namespaceSelectors matches every namespace")
PY
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true \
    -s templates/external-secrets/ClusterExternalSecret.yaml | grep -q '^  namespaceSelector:$' \
  || { echo "FAIL: the default ClusterExternalSecret no longer uses namespaceSelector." >&2; exit 1; }
# The pre-delete hook renders only with the release's Profiles, which carry the labels it selects by.
helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow --set global.demoMode=true > "$tmp/full.yaml"
[ "$(grep -c 'name: profiles-cleanup$' "$tmp/full.yaml")" -ge 2 ] || { echo "FAIL: the Profiles pre-delete hook is missing." >&2; exit 1; }
python3 - "$tmp/full.yaml" <<'PY'
import base64, sys, yaml
ps = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Profile"]
bad = [p["metadata"]["name"] for p in ps if (p["metadata"].get("labels") or {}).get("app.kubernetes.io/instance") != "ci"]
sys.exit(f"FAIL: Profiles without the release label the hook selects by: {bad}" if bad or not ps else 0)
PY
if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f kubeflow/presets/trainer-only.yaml | grep -q 'name: profiles-cleanup$'; then
  echo "FAIL: the Profiles pre-delete hook renders without Profiles (trainer-only)." >&2; exit 1
fi
echo "OK: credentials generate with cluster access, refuse offline and take the demo values in demoMode; external identity providers need no password; Dex wiring is checked; extraNamespaces and the uninstall hook render as intended."
# values.schema.json rejects typos and bad names under externalSecrets.
for bad in 'externalSecrets.extraNamespace=["team-a"]' 'externalSecrets.extraNamespaces=["Team_A"]'; do
  if helm template ci ./kubeflow --kube-version "$KUBE_VERSION" --set global.demoMode=true --set-json "$bad" >/dev/null 2>&1; then
    echo "FAIL: values.schema.json accepted $bad" >&2; exit 1
  fi
done
echo "OK: the schema rejects misspelled externalSecrets keys and invalid namespace names."
