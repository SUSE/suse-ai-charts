#!/usr/bin/env python3
"""Standalone render checks for the kubeflow-hub and user-namespace sub-charts (run by lint.yml).

Usage: check_model_registry_subcharts.py <dir>   where <dir> holds the renders named below
(see the lint.yml step for the flags). No registry login is needed, so this runs on fork PRs too.
"""
import sys, yaml
d = sys.argv[1]
NS = "kubeflow-user-example-com"
errors = []
def load(name):
    return [x for x in yaml.safe_load_all(open(f"{d}/{name}.yaml")) if x]
def find(docs, kind, name=None, ns=None):
    return [x for x in docs if x["kind"] == kind and (name is None or x["metadata"]["name"] == name)
            and (ns is None or x["metadata"].get("namespace") == ns)]
def expect(cond, msg):
    if not cond: errors.append(msg)

# kubeflow-hub: unset mode means perProfile (no shared server); mode=shared renders it.
hub = load("hub-default")
expect(not find(hub, "Deployment", "model-registry-deployment"), "hub (mode unset): shared server rendered")
expect(find(hub, "Deployment", "model-registry-ui"), "hub (mode unset): UI missing")
expect(find(load("hub-shared"), "Deployment", "model-registry-deployment"), "hub (shared): shared server missing")

# user-namespace: unset mode means perProfile (same default as hub); enabled=false turns it off.
uns = load("uns-default")
for kind, name in [("Deployment", "model-registry-deployment"), ("Deployment", "model-registry-db"),
                   ("Secret", "model-registry-db-secrets"), ("VirtualService", "model-registry"),
                   ("AuthorizationPolicy", "model-registry-service")]:
    expect(find(uns, kind, name, NS), f"user-namespace (mode unset): {kind}/{name} missing in {NS}")
expect(not find(load("uns-off"), "Deployment", "model-registry-deployment"),
       "user-namespace (modelRegistry.enabled=false): server still rendered")

# profile.enabled=false: nothing of the example profile; the registry follows additionalUsers.
np = load("uns-noprofile")
expect(not [x for x in np if "kubeflow-user-example-com" in (x["metadata"].get("namespace"), x["metadata"]["name"])],
       "profile.enabled=false: example profile objects still rendered")
expect(find(np, "Deployment", "model-registry-deployment", "alice"), "profile.enabled=false: no registry in alice")

# profile.name renames the example profile everywhere.
rn = load("uns-renamed")
expect(not [x for x in rn if NS in (x["metadata"].get("namespace"), x["metadata"]["name"])],
       "profile.name=team-demo: objects still use the default name")
for kind, name, ns in [("Namespace", "team-demo", None), ("Profile", "team-demo", None),
                       ("Deployment", "model-registry-deployment", "team-demo")]:
    expect(find(rn, kind, name, ns), f"profile.name=team-demo: {kind}/{name} missing")

# Variants: non-strict policy, no VirtualService, existing DB Secret.
v = load("uns-variants")
ap = find(v, "AuthorizationPolicy", "model-registry-service", NS)
nss = sorted(n for r in (ap[0]["spec"]["rules"] if ap else []) for f in r.get("from", [])
             for n in f.get("source", {}).get("namespaces", []))
# No istio-system: the ingress gateway runs there and would admit any logged-in user.
expect(nss == sorted(["kubeflow", NS]), f"strict=false: AuthorizationPolicy namespaces {nss}")
expect(not find(v, "VirtualService", "model-registry"), "virtualService.enabled=false: VirtualService rendered")
expect(not find(v, "Secret", "model-registry-db-secrets"), "existingSecret set: generated Secret still rendered")
refs = {e["valueFrom"]["secretKeyRef"]["name"]
        for dep in find(v, "Deployment", None, NS) if dep["metadata"]["name"].startswith("model-registry")
        for c in dep["spec"]["template"]["spec"].get("initContainers", []) + dep["spec"]["template"]["spec"]["containers"]
        for e in c.get("env", []) if e.get("valueFrom", {}).get("secretKeyRef")}
expect(refs == {"my-db"}, f"existingSecret set: deployments reference {sorted(refs)}, want ['my-db']")

if errors:
    print("FAIL: Model Registry sub-chart render checks:", *errors, sep="\n  - ", file=sys.stderr)
    sys.exit(1)
print("OK: kubeflow-hub and user-namespace render standalone in both modes and in the policy/route/Secret variants.")
