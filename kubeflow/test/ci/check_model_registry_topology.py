#!/usr/bin/env python3
"""Render checks for the Model Registry topology (run by lint.yml).

Usage: check_model_registry_topology.py <dir>   where <dir> holds perProfile.yaml, shared.yaml and
external.yaml (helm template renders of the umbrella chart; see the lint.yml step for the flags).
"""
import sys, yaml
d = sys.argv[1]
PROFILES = ["kubeflow-user-example-com", "alice", "team-x"]
errors = []
def load(name):
    return [x for x in yaml.safe_load_all(open(f"{d}/{name}.yaml")) if x]
def find(docs, kind, name, ns=None):
    return [x for x in docs if x["kind"] == kind and x["metadata"]["name"] == name
            and (ns is None or x["metadata"].get("namespace") == ns)]
def nss(docs, kind, name):
    return sorted(x["metadata"].get("namespace", "") for x in find(docs, kind, name))
def env(docs, kind, name):
    objs = find(docs, kind, name)
    if not objs:
        errors.append(f"missing {kind}/{name}"); return {}
    c = objs[0]["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e.get("value") for e in c.get("env", [])}
def expect(cond, msg):
    if not cond: errors.append(msg)
def csi_env(docs, mode):
    csis = find(docs, "ClusterStorageContainer", "model-registry-storage-initializer")
    if len(csis) != 1:
        errors.append(f"{mode}: expected 1 model-registry-storage-initializer CSI, got {len(csis)}"); return {}
    return {e["name"]: e.get("value") for e in csis[0]["spec"]["container"].get("env", [])}
def discovery_label(docs, ns):
    s = find(docs, "Service", "model-registry-service", ns)
    return bool(s) and s[0]["metadata"].get("labels", {}).get("component") == "model-registry"

# perProfile: one registry per profile, none in kubeflow
p = load("perProfile")
for kind, name in [("Deployment", "model-registry-deployment"), ("Service", "model-registry-service"),
                   ("ServiceAccount", "model-registry-server"), ("Deployment", "model-registry-db"),
                   ("PersistentVolumeClaim", "metadata-postgres"), ("Secret", "model-registry-db-secrets"),
                   ("VirtualService", "model-registry"), ("DestinationRule", "model-registry-service"),
                   ("AuthorizationPolicy", "model-registry-service")]:
    expect(nss(p, kind, name) == sorted(PROFILES),
           f"perProfile: {kind}/{name} namespaces {nss(p, kind, name)} != {sorted(PROFILES)}")
for ns in PROFILES:
    expect(discovery_label(p, ns), f"perProfile: {ns}/model-registry-service lacks label component=model-registry (BFF discovery)")
    vs = find(p, "VirtualService", "model-registry", ns)
    if vs:
        h = vs[0]["spec"]["http"][0]
        expect(h["match"][0]["uri"]["prefix"] == f"/api/model_registry/{ns}/",
               f"perProfile: {ns} VirtualService prefix is {h['match'][0]['uri']['prefix']}")
        expect(h["route"][0]["destination"]["host"].startswith(f"model-registry-service.{ns}.svc"),
               f"perProfile: {ns} VirtualService routes to {h['route'][0]['destination']['host']}")
expect(not find(p, "Deployment", "model-registry-deployment", "kubeflow"), "perProfile: shared server still rendered in kubeflow")
for kind in ("VirtualService", "DestinationRule", "AuthorizationPolicy"):
    expect(not find(p, kind, "model-registry", "kubeflow"),
           f"perProfile: hub's shared-server {kind}/model-registry still rendered in kubeflow")
# Per-profile AuthorizationPolicy (strict): only the UI/BFF and controller principals. The server does no authorisation,
# so a gateway rule or an "authorization header present" rule would admit any user or any pod; owners,
# contributors and pods in the profile namespace come in through the profile's own policies.
BFF = "cluster.local/ns/kubeflow/sa/model-registry-ui"
CONTROLLER = "cluster.local/ns/kubeflow/sa/model-registry-controller"
for ns in PROFILES:
    ap = find(p, "AuthorizationPolicy", "model-registry-service", ns)
    if not ap:
        continue
    spec = ap[0]["spec"]
    expect(spec.get("action") == "ALLOW" and spec.get("selector", {}).get("matchLabels") == {"component": "model-registry-server", "app.kubernetes.io/name": "model-registry-server"},
           f"perProfile: {ns} AuthorizationPolicy action/selector changed: {spec.get('action')} {spec.get('selector')}")
    rules = spec.get("rules") or []
    expect(rules == [{"from": [{"source": {"principals": [BFF, CONTROLLER]}}]}],
           f"perProfile: {ns} AuthorizationPolicy must admit only the UI/BFF and controller principals, got rules {rules}")
expect(find(p, "Deployment", "model-registry-ui", "kubeflow"), "perProfile: UI/BFF missing from kubeflow")
csi = csi_env(p, "perProfile")
expect("MODEL_REGISTRY_BASE_URL" not in csi, "perProfile: CSI still pins MODEL_REGISTRY_BASE_URL (would bypass ?namespace= routing)")
ctl = env(p, "Deployment", "model-registry-controller")
expect(ctl.get("INFERENCE_SERVICE_CONTROLLER") == "managed", f"perProfile: controller INFERENCE_SERVICE_CONTROLLER={ctl.get('INFERENCE_SERVICE_CONTROLLER')}, want managed")

# shared: single registry in kubeflow, no per-profile data plane
s = load("shared")
for kind, name in [("Deployment", "model-registry-deployment"), ("Service", "model-registry-service")]:
    expect(nss(s, kind, name) == ["kubeflow"], f"shared: {kind}/{name} namespaces {nss(s, kind, name)} != ['kubeflow']")
expect(discovery_label(s, "kubeflow"), "shared: kubeflow/model-registry-service lacks label component=model-registry")
expect(not find(s, "Deployment", "model-registry-db"), "shared: per-profile Postgres rendered")
scsi = csi_env(s, "shared")
expect((scsi.get("MODEL_REGISTRY_BASE_URL") or "").startswith("model-registry-service.kubeflow.svc"),
       f"shared: CSI MODEL_REGISTRY_BASE_URL={scsi.get('MODEL_REGISTRY_BASE_URL')}")
sctl = env(s, "Deployment", "model-registry-controller")
expect(sctl.get("INFERENCE_SERVICE_CONTROLLER") == "false", f"shared: controller INFERENCE_SERVICE_CONTROLLER={sctl.get('INFERENCE_SERVICE_CONTROLLER')}, want false")

# external DB: servers per profile, no embedded Postgres objects
e = load("external")
expect(nss(e, "Deployment", "model-registry-deployment") == sorted(PROFILES), "external: server not rendered in every profile")
for kind, name in [("Deployment", "model-registry-db"), ("Service", "model-registry-db"),
                   ("PersistentVolumeClaim", "metadata-postgres"), ("Secret", "model-registry-db-secrets")]:
    expect(not find(e, kind, name), f"external: embedded {kind}/{name} still rendered")

if errors:
    print("FAIL: Model Registry topology render checks:", *errors, sep="\n  - ", file=sys.stderr)
    sys.exit(1)
print("OK: perProfile fan-out (3 profiles), shared fallback and external DB render as expected.")
