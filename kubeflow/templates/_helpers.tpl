{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "kubeflow.imagePullSecrets" -}}
{{- if and (hasKey .Values "global") .Values.global }}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  {{- $imagePullSecrets := list }}
  {{- if kindIs "string" . }}
    {{- $imagePullSecrets = append $imagePullSecrets (dict "name" .) }}
  {{- else }}
    {{- $imagePullSecrets = append $imagePullSecrets . }}
  {{- end }}
  {{- toYaml $imagePullSecrets | nindent 2 }}
{{- end }}
{{- else if .Values.imagePullSecrets }}
imagePullSecrets:
    {{ toYaml .Values.imagePullSecrets }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper Application Collection Image Registry.
Precedence: global.imageRegistry > global.suseApplicationCollectionRegistry > component image.registry
Usage: {{ include "kubeflow.suseApplicationCollectionRegistry" (dict "ctx" . "registry" .Values.component.image.registry) }}
*/}}
{{- define "kubeflow.suseApplicationCollectionRegistry" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.global.imageRegistry -}}
  {{- $ctx.Values.global.imageRegistry -}}
{{- else if $ctx.Values.global.suseApplicationCollectionRegistry -}}
  {{- $ctx.Values.global.suseApplicationCollectionRegistry -}}
{{- else -}}
  {{- .registry -}}
{{- end -}}
{{- end -}}

{{/*
"true" for a trainer-only release: Trainer is enabled and every other component toggle
is off (everything trainer-only-overrides.yaml turns off). Used by NOTES.txt; the
NOTES banner it selects is how installTrainerOnly.sh recognises a trainer-only release.
Add-ons that add no Kubeflow component (certManager.install, externaldns,
externalSecretsOperator, monitoring, networkPolicies) don't count. CI checks this list
against the dependency conditions in Chart.yaml, so add new component toggles here.
*/}}
{{- define "kubeflow.trainerOnly" -}}
{{- $v := .Values -}}
{{- $others := list
      $v.admissionWebhook.enabled $v.centralDashboard.enabled $v.dex.enabled
      $v.global.oauth2Proxy.enabled $v.hub.enabled $v.istioResources.enabled
      $v.katib.enabled $v.knativeEventing.enabled $v.knativeServing.enabled
      $v.kserve.enabled $v.kubeflowRoles.enabled $v.notebooks.controller.enabled
      $v.notebooks.webApp.enabled $v.pipelines.enabled $v.profiles.enabled
      $v.tensorboard.controller.enabled $v.tensorboard.webApp.enabled
      $v.trainingOperator.enabled $v.userNamespace.enabled $v.volumesWebApp.enabled -}}
{{- if and $v.trainer.enabled (not (has true $others)) }}true{{ end -}}
{{- end -}}

{{/*
Gateway TLS source (kubeflow-istio-resources.tls.source), "" when unset. One lookup
for every umbrella template that branches on it.
*/}}
{{- define "kubeflow.tlsSource" -}}
{{- ((index .Values "kubeflow-istio-resources" | default dict).tls | default dict).source | default "" -}}
{{- end -}}

{{/*
"true" when cert-manager is required: a component that ships cert-manager
Issuers/Certificates is enabled, or cert-manager issues the gateway TLS cert (any
tls.source except "" and "secret"). Used by the preflight hook; CI checks that every
component rendering cert-manager resources is covered.
*/}}
{{- define "kubeflow.needsCertManager" -}}
{{- $src := include "kubeflow.tlsSource" . -}}
{{- if or .Values.admissionWebhook.enabled .Values.katib.enabled .Values.kserve.enabled .Values.pipelines.enabled .Values.volumesWebApp.enabled (and $src (ne $src "secret")) }}true{{ end -}}
{{- end -}}

{{/* global.istio.cni as "true"/"false" (default true). Copied per chart; CI keeps the copies equal. */}}
{{- define "kubeflow.istioCni" -}}
{{- ne (toString (dig "istio" "cni" true (.Values.global | default dict))) "false" -}}
{{- end -}}

{{/* "true" when cni=true and profile namespaces exist (they get Pod Security baseline). */}}
{{- define "kubeflow.istioCniCheckNeeded" -}}
{{- if and (eq (include "kubeflow.istioCni" .) "true") (or .Values.profiles.enabled .Values.userNamespace.enabled) }}true{{ end -}}
{{- end -}}

{{/* Istio CNI check rules, shared by validations.yaml (Helm lookup) and the preflight Job (kubectl).
     Names also match revisioned "<name>-<rev>" objects; the injector fails only on an explicit false. */}}
{{- define "kubeflow.istioCniProbe" -}}
istiod: istiod                    # Deployment in istio-system
cniDaemonSet: istio-cni-node      # DaemonSet, any namespace
injector: istio-sidecar-injector  # ConfigMap in istio-system, key "values" (JSON)
injectorField: [pilot, cni, enabled]
{{- end -}}

{{- define "kubeflow.istioCniMissingMsg" -}}
global.istio.cni=true (the default) but Istio in istio-system runs WITHOUT the istio-cni plugin (no istio-cni-node DaemonSet in any namespace). Profile namespaces would enforce Pod Security Standards 'baseline', which rejects pods using the istio-init container. Either install Istio with CNI (runMe.sh default; -f istio-cni-values.yaml) and restart meshed workloads, or set global.istio.cni=false. See docs/upgrade-notes.md#istio-cni.
{{- end -}}

{{/* Takes the injector ConfigMap name(s). */}}
{{- define "kubeflow.istioCniInjectorMsg" -}}
global.istio.cni=true (the default) but istiod's sidecar injector (ConfigMap istio-system/{{ . }}) has pilot.cni.enabled=false, so pods still get the istio-init container, which Pod Security Standards 'baseline' rejects. Install Istio with -f istio-cni-values.yaml (it sets both cni.enabled and istiod.pilot.cni.enabled) and restart meshed workloads, or set global.istio.cni=false. See docs/upgrade-notes.md#istio-cni.
{{- end -}}

{{/* global.modelRegistry.mode, "perProfile" when unset. Also resolved in kubeflow-hub and user-namespace;
     test/ci/check_model_registry_consistency.py keeps the three in agreement. */}}
{{- define "kubeflow.modelRegistryMode" -}}
{{- dig "modelRegistry" "mode" "" (.Values.global | default dict) | default "perProfile" | toString -}}
{{- end -}}

{{/* "true" when the per-profile registries render (mode, user-namespace.modelRegistry.enabled, userNamespace.enabled). */}}
{{- define "kubeflow.modelRegistryDataPlane" -}}
{{- $on := eq (include "kubeflow.modelRegistryMode" .) "perProfile" -}}
{{- $unMR := dig "modelRegistry" (dict) (index .Values "user-namespace" | default dict) -}}
{{- if kindIs "bool" $unMR.enabled }}{{ $on = $unMR.enabled }}{{ end -}}
{{- if and $on .Values.userNamespace.enabled }}true{{ end -}}
{{- end -}}

{{/* First per-profile registry namespace, "" when none. Mirrors user-namespace.profileNamespace and
     .modelRegistry.namespaces; test/ci/check_model_registry_consistency.py keeps them in agreement. */}}
{{- define "kubeflow.modelRegistryFirstNamespace" -}}
{{- if include "kubeflow.modelRegistryDataPlane" . -}}
{{- $uns := index .Values "user-namespace" | default dict -}}
{{- $users := $uns.additionalUsers | default list -}}
{{- $extra := dig "modelRegistry" "extraNamespaces" list $uns -}}
{{- if ne (toString (dig "profile" "enabled" true $uns)) "false" -}}{{ dig "profile" "name" "kubeflow-user-example-com" $uns }}
{{- else if $users -}}{{ $u := first $users }}{{ $u.namespace | default ($u.email | lower | replace "." "-" | replace "@" "--") }}
{{- else if $extra -}}{{ first $extra }}
{{- end -}}
{{- end -}}
{{- end -}}
