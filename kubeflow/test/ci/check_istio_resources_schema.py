#!/usr/bin/env python3
"""kubeflow-istio-resources global schema matches the umbrella. Run from anywhere; CI runs it from the repository root."""
import os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
import json, sys
umb = json.load(open("kubeflow/values.schema.json"))["properties"]["global"]["properties"]
sub = json.load(open("kubeflow/charts/kubeflow-istio-resources/values.schema.json"))["properties"]["global"]["properties"]
def strip(x):
    if isinstance(x, dict): return {k: strip(v) for k, v in x.items() if k != "description"}
    if isinstance(x, list): return [strip(v) for v in x]
    return x
bad = [k for k in ("gateway", "tls", "kserve") if umb.get(k) is None or umb.get(k) != sub.get(k)]
bad += [k for k in sub if k not in ("gateway", "tls", "kserve") and strip(umb.get(k)) != strip(sub[k])]
sys.exit(f"FAIL: global.{', global.'.join(bad)} in kubeflow/charts/kubeflow-istio-resources/values.schema.json "
         "differs from kubeflow/values.schema.json; align it with the umbrella's." if bad else 0)
