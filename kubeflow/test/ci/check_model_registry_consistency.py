#!/usr/bin/env python3
"""The Model Registry mode and namespace rules are written in three charts that cannot share
templates: kubeflow.modelRegistryMode/DataPlane/FirstNamespace (umbrella), kubeflow-hub.modelRegistryMode
and user-namespace.modelRegistry.enabled / profileNamespace. Render the umbrella across value variants
and check they agree, using what each chart renders:

  - umbrella: the helm test's target (kubeflow = shared, a profile namespace = perProfile data plane)
  - hub:      its shared server (Deployment/model-registry-deployment in kubeflow)
  - user-namespace: the per-profile servers (same Deployment name, profile namespaces), in its own order

Usage: check_model_registry_consistency.py <chart dir> [extra helm args...]   (run by lint.yml)
"""
import re, subprocess, sys, yaml

chart, base = sys.argv[1], sys.argv[2:]
MODES = {
    "default": [],
    "shared": ["global.modelRegistry.mode=shared"],
    "hub-local-shared": ["hub.modelRegistry.mode=shared"],          # standalone fallback; global wins
    "global-empty+hub-local-shared": ["global.modelRegistry.mode=", "hub.modelRegistry.mode=shared"],
    "un-mr-disabled": ["user-namespace.modelRegistry.enabled=false"],
    "un-disabled": ["userNamespace.enabled=false"],
    "hub-disabled": ["hub.enabled=false", "user-namespace.modelRegistry.enabled=false"],
}
NAMESPACES = {  # exercises user-namespace.profileNamespace vs kubeflow.modelRegistryFirstNamespace
    "example-profile": [],
    "renamed-profile": ["user-namespace.profile.name=team-alpha"],
    "email-slug": ["user-namespace.profile.enabled=false",
                   "user-namespace.additionalUsers[0].email=First.Last@Example.COM"],
    "explicit-namespace": ["user-namespace.profile.enabled=false",
                           "user-namespace.additionalUsers[0].email=a.b@x.io",
                           "user-namespace.additionalUsers[0].namespace=custom-ns"],
    "users-then-extra": ["user-namespace.profile.enabled=false",
                         "user-namespace.additionalUsers[0].email=bob.smith@corp.example.com",
                         "user-namespace.modelRegistry.extraNamespaces[0]=team-x"],
    "extra-only": ["user-namespace.profile.enabled=false",
                   "user-namespace.modelRegistry.extraNamespaces[0]=team-x"],
}
GUARD = re.compile(r"templates/validations\.yaml|don't meet the specifications of the schema")

def render(sets):
    args = ["helm", "template", "ci", chart, *base]
    for s in sets:
        args += ["--set", s]
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode:
        return None, p.stderr
    return [d for d in yaml.safe_load_all(p.stdout) if d], ""

def observe(docs):
    def deps(name):
        return [d["metadata"].get("namespace") for d in docs
                if d["kind"] == "Deployment" and d["metadata"]["name"] == name]
    test_ns = None
    for d in docs:
        if d["kind"] == "Pod" and d["metadata"]["name"].endswith("test-model-registry"):
            m = re.search(r"model-registry-service\.([^.\s]+)\.svc", " ".join(d["spec"]["containers"][0]["command"]))
            test_ns = m.group(1) if m else "?"
    servers = deps("model-registry-deployment")
    return test_ns, "kubeflow" in servers, [n for n in servers if n != "kubeflow"]

errors, checked, rejected = [], 0, 0
for mname, mset in MODES.items():
    for nname, nset in NAMESPACES.items():
        label = f"{mname} / {nname}"
        docs, err = render(mset + nset)
        if docs is None:
            if GUARD.search(err):
                rejected += 1
                continue
            errors.append(f"{label}: render failed outside the guards:\n{err.strip()[-400:]}")
            continue
        checked += 1
        test_ns, hub_shared, per_profile = observe(docs)
        umbrella_shared = test_ns == "kubeflow"
        if umbrella_shared != hub_shared:
            errors.append(f"{label}: umbrella mode {'shared' if umbrella_shared else 'perProfile'} "
                          f"but the hub {'renders' if hub_shared else 'does not render'} its shared server")
        if hub_shared and per_profile:
            errors.append(f"{label}: shared server and per-profile servers ({per_profile}) both rendered")
        if not umbrella_shared and test_ns is not None and test_ns not in (per_profile[:1] or [None]):
            errors.append(f"{label}: helm test targets {test_ns!r} but user-namespace's first registry "
                          f"namespace is {per_profile[:1] or 'none'}")
        if test_ns is None and per_profile and "hub.enabled=false" not in mset:
            errors.append(f"{label}: user-namespace renders registries in {per_profile} but the umbrella "
                          f"sees no per-profile data plane (no helm test target)")

if errors:
    print("FAIL: Model Registry mode/namespace rules disagree between charts:", *errors, sep="\n  - ")
    sys.exit(1)
print(f"OK: umbrella, kubeflow-hub and user-namespace agree on mode and first namespace "
      f"({checked} renders checked, {rejected} rejected by guards as intended).")
