#!/usr/bin/env bash
# CI: helm template (trainer-only preset). Run from anywhere; needs helm and the chart dependencies
# (helm dependency build ./kubeflow). KUBE_VERSION defaults to the CI target.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
: "${KUBE_VERSION:=1.35.0}"
# kubeflow/presets/trainer-only.yaml (used by the trainer-only guide and
# installTrainerOnly.sh) must install on a cluster with no Istio, no
# cert-manager and no Profiles. Render WITHOUT global.demoMode or
# global.kserve.domain: the demo-credential and inference-domain guards must
# stay scoped to their (disabled) components. Then assert only the kubeflow
# Namespace, the trainer sub-chart and the trainer test render.
vals=kubeflow/presets/trainer-only.yaml
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f "$vals")"
if grep -Eq '^apiVersion: (networking\.istio\.io|security\.istio\.io|cert-manager\.io)/' <<<"$out"; then
  echo "FAIL: trainer-only render contains Istio or cert-manager resources." >&2; exit 1
fi
if grep -Eq '^kind: Profile$' <<<"$out"; then
  echo "FAIL: trainer-only render contains a Profile CR (its CRD ships only with profiles-and-kfam)." >&2; exit 1
fi
unexpected="$(grep -E '^# Source: ' <<<"$out" | sed 's/^# Source: //' \
  | grep -Ev '^kubeflow/charts/(kubeflow-namespace|trainer)/|^kubeflow/templates/tests/test-trainer\.yaml$' || true)"
[ -z "$unexpected" ] \
  || { echo "FAIL: trainer-only render contains unexpected templates:" >&2; echo "$unexpected" >&2; exit 1; }
grep -Fq 'kind: ClusterTrainingRuntime' <<<"$out" \
  || { echo "FAIL: trainer-only render has no bundled ClusterTrainingRuntimes." >&2; exit 1; }
# The bundled runtimes must be applied by the server-side-apply Job, never
# rendered as top-level manifests: as Helm hooks (before-hook-creation) they are
# deleted on every upgrade, which hangs on the trainer.kubeflow.org/resource-in-use
# finalizer while any TrainJob uses them; as release resources, runtimes created
# by older chart versions block the upgrade on Helm's ownership check.
if grep -Eq '^kind: ClusterTrainingRuntime$' <<<"$out"; then
  echo "FAIL: a bundled ClusterTrainingRuntime is rendered as a top-level manifest; it must go through files/runtimes/ and the runtimes-applier Job." >&2; exit 1
fi
grep -Fq 'name: kubeflow-trainer-runtimes-applier' <<<"$out" \
  || { echo "FAIL: the runtimes-applier hook Job is missing from the trainer-only render." >&2; exit 1; }
# Inspect the bundled runtimes by parsing the applier ConfigMap with yq (preinstalled
# on ubuntu-latest) rather than by indentation, so a reformat can't break or blind
# these checks. rt_docs prints the runtime documents from the ConfigMap data.
rt_docs() { yq 'select(.kind == "ConfigMap" and .metadata.name == "kubeflow-trainer-runtimes-applier") | .data[] | "---\n" + .' <<<"$1"; }
# The applier prunes runtimes it applied earlier by label, so every bundled
# runtime must carry the label, and its ClusterRole must allow delete.
rts="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f "$vals" \
  --set trainer.runtimes.torchtune.enabled=true)"
n_rt="$(rt_docs "$rts" | yq -N 'select(.kind == "ClusterTrainingRuntime") | .metadata.name' | grep -c . || true)"
unlabelled="$(rt_docs "$rts" | yq -N 'select(.kind == "ClusterTrainingRuntime" and .metadata.labels."app.kubernetes.io/managed-by" != "kubeflow-trainer-runtimes-applier") | .metadata.name')"
[ "$n_rt" -eq 6 ] && [ -z "$unlabelled" ] \
  || { echo "FAIL: expected 6 bundled runtimes (torchtune on), all labelled app.kubernetes.io/managed-by=kubeflow-trainer-runtimes-applier; got $n_rt, unlabelled: ${unlabelled:-none}." >&2; exit 1; }
yq -e 'select(.kind == "ClusterRole" and .metadata.name == "kubeflow-trainer-runtimes-applier") | .rules[].verbs[] | select(. == "delete")' <<<"$rts" >/dev/null \
  || { echo "FAIL: the runtimes-applier ClusterRole cannot delete runtimes (needed for pruning)." >&2; exit 1; }
# trainer.runtimes.istioSidecar must reach every bundled runtime pod template
# (torchtune included): disabled -> inject "false", native -> nativeSidecar
# "true", default -> neither. A regular sidecar outlives the training
# container, so a template that misses the annotation never completes.
for mode in disabled native default; do
  out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f "$vals" \
    --set trainer.runtimes.torchtune.enabled=true --set trainer.runtimes.istioSidecar="$mode")"
  # One line per pod template: "<inject>/<nativeSidecar>", "-" when unset.
  anns="$(rt_docs "$out" | yq -N '.spec.template.spec.replicatedJobs[].template.spec.template
    | (.metadata.annotations."sidecar.istio.io/inject" // "-") + "/" + (.metadata.annotations."sidecar.istio.io/nativeSidecar" // "-")')"
  case "$mode" in
    disabled) want='false/-' ;;
    native)   want='-/true' ;;
    default)  want='-/-' ;;
  esac
  pods="$(grep -c . <<<"$anns" || true)"
  bad="$(grep -vxF "$want" <<<"$anns" | sort | uniq -c || true)"
  [ "$pods" -ge 14 ] && [ -z "$bad" ] \
    || { echo "FAIL: istioSidecar=$mode: want every runtime pod template to be '$want' (inject/nativeSidecar); $pods templates, mismatches: ${bad:-none}" >&2; exit 1; }
done
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f "$vals" \
  --set trainer.runtimes.enabled=false --set trainer.runtimes.torchtune.enabled=true)"
if grep -Fq 'kind: ClusterTrainingRuntime' <<<"$out"; then
  echo "FAIL: trainer.runtimes.enabled=false still renders ClusterTrainingRuntimes (torchtune.enabled=true must not override it)." >&2; exit 1
fi
# ...and, offline (lookup finds no runtimes to prune), no applier Job either: a
# bring-your-own-runtimes install must not need the kubectl image or the
# application-collection pull secret. On a cluster the Job renders while
# runtimes it applied earlier still exist, and prunes them.
if yq -e 'select(.kind == "Job" and .metadata.name == "kubeflow-trainer-runtimes-applier")' <<<"$out" >/dev/null 2>&1; then
  echo "FAIL: with trainer.runtimes.enabled=false and nothing to prune, the runtimes-applier Job still renders." >&2; exit 1
fi
# Cross-component guards must fail closed when a dependency is re-enabled.
for bad in "profiles.enabled=true:requires kubeflowRoles.enabled=true" \
           "profiles.enabled=true,kubeflowRoles.enabled=true:  - profiles.enabled" \
           "notebooks.webApp.enabled=true:  - notebooks.webApp.enabled" \
           "katib.enabled=true:  - katib.enabled" \
           "tensorboard.controller.enabled=true:  - tensorboard.controller.enabled" \
           "userNamespace.enabled=true:requires profiles.enabled=true"; do
  set_arg="${bad%%:*}"; want="${bad#*:}"
  if err="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow \
      -f "$vals" --set "$set_arg" 2>&1)"; then
    echo "FAIL: trainer-only + --set $set_arg rendered; the cross-component guard should reject it." >&2; exit 1
  fi
  grep -Fq "$want" <<<"$err" \
    || { echo "FAIL: trainer-only + --set $set_arg failed, but not on the expected guard. Got:" >&2; echo "$err" >&2; exit 1; }
done
# externalSecrets is not tied to Profiles: with ESO, trainer-only installs can
# propagate pull secrets to their own namespaces (the guide's example values).
# The ESO-API guard is skipped offline, so this must render.
sel='{"enabled":true,"namespaceSelector":{"matchLabels":{"app.kubernetes.io/part-of":null,"suse.com/trainjob-pull-secrets":"true"}}}'
out="$(helm template ci ./kubeflow --kube-version "$KUBE_VERSION" -n kubeflow -f "$vals" \
  --set-json "externalSecrets=$sel" -s templates/external-secrets/ClusterExternalSecret.yaml)"
grep -Fq 'suse.com/trainjob-pull-secrets: "true"' <<<"$out" && ! grep -Fq 'kubeflow-profile' <<<"$out" \
  || { echo "FAIL: trainer-only + externalSecrets with a custom namespaceSelector did not render the expected selector. Got:" >&2; echo "$out" >&2; exit 1; }
echo "OK: trainer-only preset renders only Namespace + trainer + test-trainer, no Istio/cert-manager/Profile, and its guards fail closed."
