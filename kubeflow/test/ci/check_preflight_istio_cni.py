#!/usr/bin/env python3
"""Run the preflight Job's Istio CNI check (Check 3) against fake cluster states (run by lint.yml).

The Job's shell logic only runs in a cluster, and validations.yaml's lookup twin does not run under
helm template, so neither would catch a broken script. This renders the Job, extracts Check 3 and
runs it with a stub kubectl that serves fixtures; `kubectl label --local` (the exact
pilot.cni.enabled read) goes to the real kubectl, which must be on PATH.

Usage: check_preflight_istio_cni.py <chart dir> [extra helm args...]
"""
import os, re, shutil, subprocess, sys, tempfile, yaml

chart, base = sys.argv[1], sys.argv[2:]
real_kubectl = shutil.which("kubectl")
if not real_kubectl:
    sys.exit("FAIL: kubectl not found on PATH (needed for `kubectl label --local`)")

ON = '{"global":{"hub":"x"},"pilot":{"cni":{"cniBinDir":"/x","enabled":true,"provider":"default"}}}'
OFF_LATE = '{"pilot":{"cni":{"cniBinDir":"/x","provider":"default","enabled":false}}}'  # enabled not first
OFF_MULTILINE = '{\n  "pilot": { "cni": { "enabled": false } }, "istio_cni": {"enabled": true}\n}'
# (name, cni value, istiod deployments, daemonsets, injector configmaps, injector values, exit, output)
CASES = [
    ("CNI on, injector enabled", "true", "istiod", "istio-cni-node kube-proxy", "istio-sidecar-injector", ON, 0, "present — OK"),
    ("revisioned istiod and injector", "true", "istiod-1-24", "istio-cni-node", "istio-sidecar-injector-1-24", ON, 0, "present — OK"),
    ("injector without pilot.cni", "true", "istiod", "istio-cni-node", "istio-sidecar-injector", '{"global":{}}', 0, "present — OK"),
    ("no istiod", "true", "", "", "", "", 0, "skipped (no istiod"),
    ("injector disabled, field not first", "true", "istiod", "istio-cni-node", "istio-sidecar-injector", OFF_LATE, 1, "pilot.cni.enabled=false"),
    ("injector disabled, multi-line JSON", "true", "istiod", "istio-cni-node", "istio-sidecar-injector", OFF_MULTILINE, 1, "pilot.cni.enabled=false"),
    ("no istio-cni-node DaemonSet", "true", "istiod", "kube-proxy", "istio-sidecar-injector", ON, 1, "WITHOUT the istio-cni plugin"),
    ("cni=false, CNI installed", "false", "istiod", "istio-cni-node", "istio-sidecar-injector", ON, 0, "NOTE:"),
    ("cni=false, no CNI", "false", "istiod", "kube-proxy", "istio-sidecar-injector", ON, 0, "classic istio-init"),
]
STUB = f"""#!/bin/sh
case "$*" in
  label*) exec {real_kubectl} "$@" ;;
  *"get deployment"*) echo "$FX_ISTIOD" ;;
  *"get daemonset"*) echo "$FX_DS" ;;
  *"get configmap -n istio-system -o"*) echo "$FX_CMS" ;;
  *"get configmap -n istio-system "*) printf '%s' "$FX_VALUES" ;;
  *) echo "stub kubectl: unexpected call: $*" >&2; exit 99 ;;
esac
"""

def check3(cni):
    out = subprocess.run(["helm", "template", "ci", chart, *base, "--set", "preflightChecks.enabled=true",
                          "--set", f"global.istio.cni={cni}", "--show-only",
                          "templates/hooks/pre-install-preflight-Job.yaml"],
                         capture_output=True, text=True, check=True).stdout
    script = yaml.safe_load(out)["spec"]["template"]["spec"]["containers"][0]["command"][2]
    m = re.search(r'^echo "Check 3.*?(?=^echo "=== PREFLIGHT: OK)', script, re.S | re.M)
    if not m:
        sys.exit("FAIL: Check 3 not found in the rendered preflight script")
    return m.group(0)

errors = []
with tempfile.TemporaryDirectory() as tmp:
    stub = os.path.join(tmp, "kubectl")
    with open(stub, "w") as f:
        f.write(STUB)
    os.chmod(stub, 0o755)
    scripts = {cni: check3(cni) for cni in ("true", "false")}
    for name, cni, istiod, ds, cms, values, want_rc, want_out in CASES:
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", FX_ISTIOD=istiod, FX_DS=ds,
                   FX_CMS=cms, FX_VALUES=values)
        p = subprocess.run(["sh", "-e", "-c", scripts[cni]], env=env, capture_output=True, text=True)
        out = p.stdout + p.stderr
        if p.returncode != want_rc or want_out not in out:
            errors.append(f"{name}: exit {p.returncode} (want {want_rc}), output lacks {want_out!r}:\n{out.strip()[-300:]}")

if errors:
    print("FAIL: preflight Istio CNI check:", *errors, sep="\n  - ")
    sys.exit(1)
print(f"OK: preflight Istio CNI check behaves as expected in {len(CASES)} cluster states.")
