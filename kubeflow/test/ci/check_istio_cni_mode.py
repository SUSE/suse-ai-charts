#!/usr/bin/env python3
"""Render checks for global.istio.cni (run by .github/workflows/lint.yml).

Usage: check_istio_cni_mode.py <dir>   where <dir> holds cni-true.yaml and cni-false.yaml
(helm template renders of the umbrella chart with global.istio.cni=true / false).
Asserts the profile-namespace labels (istio-injection always; PSS baseline only with CNI), the
profile-controller namespace-labels ConfigMap, and that profiles-config admits the configured
ingress-gateway principal (no rancher-ingressgateway-access workaround).
"""
import sys, yaml
d = sys.argv[1]
errors = []
for mode in ("true", "false"):
    docs = [x for x in yaml.safe_load_all(open(f"{d}/cni-{mode}.yaml")) if x]
    for ns in ("kubeflow-user-example-com", "alice"):
        obj = [x for x in docs if x["kind"] == "Namespace" and x["metadata"]["name"] == ns]
        labels = obj[0]["metadata"].get("labels", {}) if obj else {}
        if labels.get("istio-injection") != "enabled":
            errors.append(f"cni={mode}: Namespace {ns} lacks istio-injection: enabled")
        pss = labels.get("pod-security.kubernetes.io/enforce")
        if (mode == "true") != (pss == "baseline"):
            errors.append(f"cni={mode}: Namespace {ns} pod-security enforce label is {pss!r}")
    cm = [x for x in docs if x["kind"] == "ConfigMap" and x["metadata"]["name"].startswith("namespace-labels-data")]
    nl = yaml.safe_load(cm[0]["data"]["namespace-labels.yaml"]) if cm else {}
    if (mode == "true") != (nl.get("pod-security.kubernetes.io/enforce") == "baseline"):
        errors.append(f"cni={mode}: profile-controller namespace-labels PSS entry is {nl.get('pod-security.kubernetes.io/enforce')!r}")
# Profile gateway access: the profiles controller (v2.0.0) builds ns-owner-access-istio from
# ISTIO_INGRESS_GATEWAY_PRINCIPAL in profiles-config, which must follow the single-sourced
# global.istio.ingressGateway.principal (Rancher gateway SA 'istio'), so the old
# rancher-ingressgateway-access workaround must not come back.
docs = [x for x in yaml.safe_load_all(open(f"{d}/cni-true.yaml")) if x]
pc = [x for x in docs if x["kind"] == "ConfigMap" and x["metadata"]["name"].startswith("profiles-config")]
gw = pc[0]["data"].get("ISTIO_INGRESS_GATEWAY_PRINCIPAL") if pc else None
if gw != "cluster.local/ns/istio-system/sa/istio":
    errors.append(f"profiles-config ISTIO_INGRESS_GATEWAY_PRINCIPAL={gw!r} does not follow global.istio.ingressGateway.principal")
if any(x["metadata"]["name"] == "rancher-ingressgateway-access" for x in docs):
    errors.append("rancher-ingressgateway-access is rendered again (redundant with ns-owner-access-istio)")
if errors:
    print("FAIL: Istio CNI mode render checks:", *errors, sep="\n  - ", file=sys.stderr)
    sys.exit(1)
print("OK: profile namespace labels follow global.istio.cni in both modes; profiles controller admits the configured gateway principal.")
