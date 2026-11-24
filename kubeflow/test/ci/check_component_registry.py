#!/usr/bin/env python3
"""Check the component registry (components.yaml) and the presets against the chart.

Usage: check_component_registry.py <chart-dir> [--fix-presets | --offline] [helm template args, e.g. --kube-version 1.35.0]

--offline runs checks 1, 2 and 4, which need only the probe chart (no sub-chart dependencies, so no
registry access): CI runs it on every PR, including forks.

1. Every dependency condition in Chart.yaml is the toggle of a registry entry, and back.
2. Each preset with a "# components:" header ends with a generated block that turns every other
   component off. --fix-presets (re)writes those blocks and stops; without it, a stale block fails.
   The hand-written part must not set a top-level key the generated block sets.
3. What each component renders matches what it declares: rendered with Istio resources off,
   a component that needs Istio is refused and one that doesn't renders no Istio resources;
   rendered with Istio on, a component that renders cert-manager resources is covered by the
   preflight's cert-manager check (kubeflow.needsCertManager). Prerequisites come from
   kubeflow.unmetRequirements, read from the probe chart.
4. Each preset enables its "# components:" (plus at most its "# optional:" ones), and
   kubeflow.trainerOnly (the NOTES banner) is true for trainer-only, with or without add-ons.
5. The probe chart (components.yaml, templates/_helpers.tpl and values.yaml only, as install.sh
   uses it) gives the same components, prerequisites, trainerOnly and unmet requirements as the
   real chart, and evaluates the requires.when of enabled components the same way (the real chart
   sees sub-chart defaults; one case turns every toggle on).
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# conditions: the "when" of every enabled component's requirements, met or not, so a registry default
# (when.default, or a helper's fallback) that no longer matches a sub-chart default shows up. Only
# enabled components: Helm doesn't merge a disabled sub-chart's defaults into the parent's values.
CONDITIONS = """{{- define "ci.conditions" -}}
{{- $out := dict -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- range $name := include "kubeflow.enabledComponents" . | fromJsonArray -}}
{{-   range $i, $r := (index $reg $name).requires | default list -}}
{{-     if $r.when }}{{ $_ := set $out (printf "%s.requires[%d]" $name $i) (eq (include "kubeflow.conditionMet" (dict "ctx" $ "cond" $r.when)) "true") }}{{ end -}}
{{-   end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
"""
FIELDS = """  components: {{ include "kubeflow.enabledComponents" . | quote }}
  prerequisites: {{ include "kubeflow.clusterPrerequisites" . | quote }}
  trainerOnly: {{ include "kubeflow.trainerOnly" . | quote }}
  unmet: {{ include "kubeflow.unmetRequirements" . | quote }}
  conditions: {{ include "ci.conditions" . | quote }}
"""
PROBE_TEMPLATE = CONDITIONS + """apiVersion: v1
kind: ConfigMap
metadata: {name: ci-registry}
data:
  registry: {{ include "kubeflow.components" . | fromYaml | toJson | quote }}
""" + FIELDS
REAL_TEMPLATE = CONDITIONS + """apiVersion: v1
kind: ConfigMap
metadata: {name: ci-real}
data:
""" + FIELDS
ISTIO_HEADER = "istioResources.enabled=false is meant for installs without Istio"
ISTIO_KIND = re.compile(r"^apiVersion: [a-z.]*istio\.io/", re.M)
CERT_KIND = re.compile(r"^apiVersion: cert-manager\.io/", re.M)
BLOCK_BEGIN = "# ---- Generated: every component not in \"# components:\" is off. Regenerate with"
BLOCK_BEGIN2 = "# ---- test/ci/check_component_registry.py <chart-dir> --fix-presets; don't edit by hand."
BLOCK_END = "# ---- End of generated block"

failures = []


def fail(msg):
    failures.append(msg)
    print(f"FAIL: {msg}", file=sys.stderr)


def helm(chart, helm_args, sets, files=(), only=None):
    cmd = ["helm", "template", "ci", str(chart), "-n", "kubeflow", *helm_args]
    for f in files:
        cmd += ["-f", str(f)]
    for s in sets:
        cmd += ["--set", s]
    if only:
        cmd += ["-s", only]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, r.stdout if r.returncode == 0 else r.stderr


def fields(out):
    data = {k: json.loads(v) for k, v in re.findall(r'^  (\w+): (".*")$', out, re.M)}
    for k in ("registry", "unmet", "components", "conditions"):
        if k in data:
            data[k] = json.loads(data[k])  # JSON inside a quoted string
    return data


def probe(probe_chart, sets=(), files=()):
    """Registry, unmet requirements, components, prerequisites and trainerOnly from the probe chart."""
    ok, out = helm(probe_chart, [], sets, files)
    if not ok:
        raise RuntimeError(f"probe render failed ({' '.join(sets)} {' '.join(map(str, files))}):\n{out}")
    return fields(out)


def render_with_prereqs(chart, probe_chart, helm_args, base_files, sets, reg):
    """Enable what kubeflow.unmetRequirements asks for, then render; returns (ok, out, sets)."""
    sets = list(sets)
    for _ in range(10):
        new = []
        for u in probe(probe_chart, sets, base_files)["unmet"]:
            dep = u["requires"]
            s = "istioResources.externalAuth=true" if dep == "login" else (
                f"{reg[dep]['toggle']}=true" if reg[dep].get("toggle") else None)
            if s and s not in sets and s not in new:
                new.append(s)
        if not new:
            break
        sets += new
    ok, out = helm(chart, helm_args, sets, base_files)
    return ok, out, sets


# ---- presets ---------------------------------------------------------------------------------

def preset_header(text, key):
    m = re.search(rf"^# {key}:[ \t]*(.*)$", text, re.M)
    return m.group(1).split() if m else None


def split_block(text):
    """(hand-written text, generated block or None)."""
    lines = text.splitlines(keepends=True)
    try:
        b = next(i for i, l in enumerate(lines) if l.startswith(BLOCK_BEGIN))
        e = next(i for i, l in enumerate(lines) if i > b and l.startswith(BLOCK_END))
    except StopIteration:
        return text, None
    return "".join(lines[:b]).rstrip("\n") + "\n", "".join(lines[b:e + 1])


def generate_block(reg, components):
    tree = {}
    for name, e in sorted(reg.items()):
        t = e.get("toggle")
        if not t or e.get("addon") or name in components:
            continue
        node = tree
        *parents, leaf = t.split(".")
        for k in parents:
            node = node.setdefault(k, {})
        node[leaf] = False

    def emit(node, indent):
        out = []
        for k in sorted(node):
            v = node[k]
            if isinstance(v, dict):
                out.append(f"{'  ' * indent}{k}:\n")
                out += emit(v, indent + 1)
            else:
                out.append(f"{'  ' * indent}{k}: {'true' if v else 'false'}\n")
        return out

    return tree, BLOCK_BEGIN + "\n" + BLOCK_BEGIN2 + "\n" + "".join(emit(tree, 0)) + BLOCK_END + " ----\n"


def top_level_keys(text):
    return {m.group(1) for m in re.finditer(r"^([A-Za-z0-9_.-]+):", text, re.M)}


def check_presets(src, reg, fix):
    for f in sorted((src / "presets").glob("*.yaml")):
        text = f.read_text()
        comps = preset_header(text, "components")
        hand, block = split_block(text)
        if comps is None:
            if block:
                fail(f"presets/{f.name} has a generated block but no \"# components:\" header.")
            continue
        unknown = [c for c in comps + (preset_header(text, "optional") or []) if c not in reg]
        if unknown:
            fail(f"presets/{f.name} names components that aren't in components.yaml: {' '.join(unknown)}")
            continue
        tree, want = generate_block(reg, comps)
        clash = top_level_keys(hand) & set(tree)
        if clash:
            fail(f"presets/{f.name}: the hand-written part sets {', '.join(sorted(clash))}, which the generated block "
                 "also sets. Move those settings out of the hand-written part (components listed in \"# components:\" stay on).")
        if block != want:
            if fix:
                f.write_text(hand + "\n" + want)
                print(f"wrote the generated block of presets/{f.name}")
            else:
                fail(f"presets/{f.name}: the generated block is missing or out of date. Run "
                     f"test/ci/check_component_registry.py {src} --fix-presets.")


# ---- main ------------------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    fix = "--fix-presets" in args
    offline = "--offline" in args
    args = [a for a in args if a not in ("--fix-presets", "--offline")]
    src = pathlib.Path(args[0])
    helm_args = args[1:]
    with tempfile.TemporaryDirectory() as tmp:
        probe_chart = pathlib.Path(tmp) / "probe" / "kubeflow"
        (probe_chart / "templates").mkdir(parents=True)
        (probe_chart / "Chart.yaml").write_text("apiVersion: v2\nname: kubeflow\nversion: 0.0.0\n")
        for name in ("values.yaml", "components.yaml"):
            shutil.copy(src / name, probe_chart / name)
        shutil.copy(src / "templates" / "_helpers.tpl", probe_chart / "templates" / "_helpers.tpl")
        (probe_chart / "templates" / "zz-ci-registry.yaml").write_text(PROBE_TEMPLATE)
        reg = probe(probe_chart)["registry"]

        # 2. Generated preset blocks (first, so --fix-presets is quick).
        check_presets(src, reg, fix)
        if fix:
            sys.exit(1 if failures else 0)

        # 1. Chart.yaml conditions <-> registry toggles.
        conditions = set(re.findall(r"^\s*condition:\s*(\S+)", (src / "Chart.yaml").read_text(), re.M))
        toggles = {e["toggle"] for e in reg.values() if e.get("toggle")}
        for c in sorted(conditions - toggles):
            fail(f"Chart.yaml condition {c} has no entry in components.yaml.")
        for t in sorted(toggles - conditions):
            fail(f"components.yaml toggle {t} is not a dependency condition in Chart.yaml.")

        # 3. Rendered output matches the declarations (needs the sub-chart dependencies).
        base = [src / "presets" / "trainer-only.yaml"]
        demo = ["global.demoMode=true"]
        for name, e in ([] if offline else sorted(reg.items())):
            t = e.get("toggle")
            if not t or t in ("istioResources.enabled", "certManager.install"):
                continue
            label = e.get("istioHint") or t
            ok, out, _ = render_with_prereqs(src, probe_chart, helm_args, base, demo + [f"{t}=true"], reg)
            if ok:
                if ISTIO_KIND.search(out):
                    fail(f"{t}=true renders Istio resources but {name} does not declare istio: true.")
                if e.get("istio") and not e.get("istioOptional"):
                    fail(f"{name} declares istio: true but {t}=true renders with istioResources.enabled=false.")
            elif ISTIO_HEADER in out:
                if e.get("istio") and f"  - {label}" not in out:
                    fail(f"{name} declares istio: true but the Istio error does not list {label}.")
            else:
                fail(f"{t}=true with istioResources.enabled=false failed for a reason other than a chart guard:\n{out[-800:]}")
            ok, out, sets = render_with_prereqs(
                src, probe_chart, helm_args, base,
                demo + ["istioResources.enabled=true", "preflightChecks.enabled=true", f"{t}=true"], reg)
            if not ok:
                fail(f"{t}=true does not render even with the prerequisites the chart asked for ({' '.join(sets)}):\n{out[-800:]}")
            elif CERT_KIND.search(out) and "cert-manager CRDs... skipped" in out:
                fail(f"{t}=true renders cert-manager resources but {name} does not declare certManager: true.")
        print(f"OK: {len(reg)} registry entries match Chart.yaml" + ("." if offline else " and what their components render."))

        # 4. Presets enable what their headers say; the Trainer-only banner.
        for f in sorted((src / "presets").glob("*.yaml")):
            text = f.read_text()
            comps = preset_header(text, "components")
            if comps is None:
                continue
            optional = preset_header(text, "optional") or []
            on = {c for c in probe(probe_chart, files=[f])["components"] if not reg[c].get("addon")}
            missing, extra = sorted(set(comps) - on), sorted(on - set(comps) - set(optional))
            if missing:
                fail(f"presets/{f.name} does not enable {' '.join(missing)}, listed in its \"# components:\".")
            if extra:
                fail(f"presets/{f.name} also enables {' '.join(extra)}: add them to its \"# components:\" or "
                     "\"# optional:\", or regenerate its block (--fix-presets).")
        trainer = src / "presets" / "trainer-only.yaml"
        for want, sets, files in [
            ("true", [], [trainer]),
            ("true", ["networkPolicies.enabled=true", "network-policies.knativeServingPolicies.enabled=false",
                      "monitoring.enabled=true"], [trainer]),
            ("", ["notebooks.controller.enabled=true", "notebook-controller.configMapData.USE_ISTIO=false"], [trainer]),
            ("", ["trainer.enabled=false"], [trainer]),
            ("", [], []),
        ]:
            got = probe(probe_chart, sets, files)["trainerOnly"]
            if got != want:
                fail(f"kubeflow.trainerOnly for {' '.join(map(str, files))} {' '.join(sets)} is '{got}', want '{want}'.")
        print("OK: every preset enables what its header lists; the Trainer-only banner shows only for Trainer alone.")

        # 5. The probe chart agrees with the real chart (needs the sub-chart dependencies).
        if offline:
            print("Skipped (--offline): checks 3 and 5, which render the chart with its sub-chart dependencies.")
            sys.exit(1 if failures else 0)
        real = pathlib.Path(tmp) / "real" / "kubeflow"
        shutil.copytree(src, real)
        (real / "templates" / "zz-ci-real.yaml").write_text(REAL_TEMPLATE)
        cases = [([], [])] + [([], [f]) for f in sorted((src / "presets").glob("*.yaml"))] + [
            (["externalSecrets.enabled=true", "monitoring.enabled=true"], [trainer]),
            (["knativeServing.enabled=false", "kserve.enabled=false", "global.modelRegistry.mode=shared"], []),
            # Every toggle on, so every requires.when is compared at least once.
            (sorted({f"{c['toggle']}=true" for c in reg.values() if c.get("toggle")}), []),
        ]
        for sets, files in cases:
            ok, out = helm(real, helm_args, demo + sets, files, "templates/zz-ci-real.yaml")
            if not ok:
                fail(f"real chart does not render for the probe comparison ({' '.join(sets)} {' '.join(map(str, files))}):\n{out[-800:]}")
                continue
            got_real = fields(out)
            got_probe = probe(probe_chart, sets, files)
            for k in ("components", "prerequisites", "trainerOnly", "unmet", "conditions"):
                if got_real[k] != got_probe[k]:
                    hint = ("A requires.when default (or its helper's fallback) no longer matches the sub-chart's "
                            "default: update components.yaml or the helper." if k == "conditions" else
                            "Registry helpers may read only .Values (see components.yaml).")
                    fail(f"probe chart and real chart disagree on {k} for {' '.join(sets)} {' '.join(map(str, files))}: "
                         f"probe {got_probe[k]!r}, chart {got_real[k]!r}. {hint}")
        print(f"OK: the probe chart matches the real chart for {len(cases)} sets of values.")
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
