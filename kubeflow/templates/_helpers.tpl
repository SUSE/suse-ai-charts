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
