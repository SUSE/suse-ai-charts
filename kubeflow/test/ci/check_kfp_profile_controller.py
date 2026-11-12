#!/usr/bin/env python3
"""Render checks for the KFP per-profile plane owned by the KFP profile controller (run by lint.yml).

Usage: check_kfp_profile_controller.py <rendered.yaml> <profile namespace> [...]
"""
import sys, yaml
p = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
PROFILES = sys.argv[2:]
errors = []
def expect(cond, msg):
    if not cond: errors.append(msg)
def env(docs, kind, name):
    objs = [x for x in docs if x["kind"] == kind and x["metadata"]["name"] == name]
    if not objs:
        errors.append(f"missing {kind}/{name}"); return {}
    c = objs[0]["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e.get("value") for e in c.get("env", [])}

# KFP per-profile plane is owned by the KFP profile controller (as upstream): Helm must
# render none of it into profile namespaces, and the DecoratorController update
# strategies must match upstream (InPlace for deploy/svc/DR/AP, OnDelete for secrets/cm).
KFP = ("ml-pipeline-ui-artifact", "ml-pipeline-visualizationserver",
       "mlpipeline-minio-artifact", "metadata-grpc-configmap", "kfp-launcher")
leaked = sorted({f"{x['kind']} {x['metadata'].get('namespace')}/{x['metadata']['name']}" for x in p
                 if x["metadata"]["name"] in KFP and x["metadata"].get("namespace") in PROFILES})
expect(not leaked, f"perProfile: Helm renders KFP per-profile objects (controller-owned): {leaked}")
dc = [x for x in p if x["kind"] == "DecoratorController" and x["metadata"]["name"] == "kubeflow-pipelines-profile-controller"]
want = {"secrets": "OnDelete", "configmaps": "OnDelete", "deployments": "InPlace",
        "services": "InPlace", "destinationrules": "InPlace", "authorizationpolicies": "InPlace"}
got = {a["resource"]: a["updateStrategy"]["method"] for a in dc[0]["spec"]["attachments"]} if dc else {}
expect(got == want, f"KFP DecoratorController updateStrategy {got} != upstream {want}")
# The hook is upstream's KFP 2.17 sync.py: it mints per-profile SeaweedFS keys via the
# IAM API, so the controller must get the IAM endpoint + admin identity, and the code
# ConfigMap must carry that script (not the pre-2.16 shared-credential one).
pc = env(p, "Deployment", "kubeflow-pipelines-profile-controller")
expect(pc.get("AWS_ENDPOINT_URL") == "http://seaweedfs.kubeflow:8111",
       f"KFP profile controller AWS_ENDPOINT_URL={pc.get('AWS_ENDPOINT_URL')}")
sw = [x for x in p if x["kind"] == "Service" and x["metadata"]["name"] == "seaweedfs" and x["metadata"].get("namespace") == "kubeflow"]
sw_ports = {pt["port"] for pt in sw[0]["spec"]["ports"]} if sw else set()
expect(8111 in sw_ports and 8333 in sw_ports,
       f"seaweedfs Service ports {sorted(sw_ports)} must include 8111 (IAM, per-profile keys) and 8333 (S3)")
code = [x for x in p if x["kind"] == "ConfigMap" and x["metadata"]["name"].startswith("kubeflow-pipelines-profile-controller-code")]
expect(code and "iam.create_access_key" in code[0]["data"]["sync.py"],
       "KFP profile controller code ConfigMap does not carry the per-profile-credential sync.py")

if errors:
    print("FAIL: KFP profile-controller render checks:", *errors, sep="\n  - ", file=sys.stderr)
    sys.exit(1)
print("OK: KFP per-profile plane is controller-owned and wired to the SeaweedFS IAM API.")
