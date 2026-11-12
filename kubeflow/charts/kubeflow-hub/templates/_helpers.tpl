{{/*
Expand the name of the chart.
*/}}
{{- define "kubeflow-hub.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kubeflow-hub.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kubeflow-hub.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubeflow-hub.labels" -}}
helm.sh/chart: {{ include "kubeflow-hub.chart" . }}
{{ include "kubeflow-hub.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubeflow-hub.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeflow-hub.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "kubeflow-hub.imagePullSecrets" -}}
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
Return the proper SUSE AI Image Registry.
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: {{ include "kubeflow-hub.suseImageRegistry" (dict "ctx" . "registry" .Values.server.image.registry) }}
*/}}
{{- define "kubeflow-hub.suseImageRegistry" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.global.imageRegistry -}}
  {{- $ctx.Values.global.imageRegistry -}}
{{- else if $ctx.Values.global.suseRegistry -}}
  {{- $ctx.Values.global.suseRegistry -}}
{{- else -}}
  {{- .registry -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper Application Collection Image Registry.
Precedence: global.imageRegistry > global.suseApplicationCollectionRegistry > component image.registry
Usage: {{ include "kubeflow-hub.suseApplicationCollectionRegistry" (dict "ctx" . "registry" .Values.dbInit.image.registry) }}
*/}}
{{- define "kubeflow-hub.suseApplicationCollectionRegistry" -}}
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
Ingress-gateway ServiceAccount principal — single source of truth (umbrella parent
overrides via global.istio.ingressGateway.principal). Nil-guarded the same way as
kubeflow-istio-resources.ingressGatewaySelector so a partially overridden or absent
global.istio never errors the strict AuthorizationPolicies; falls back to the
Rancher/AppCo default. Upstream Istio: override to the upstream SA principal.
*/}}
{{- define "kubeflow-hub.ingressGatewayPrincipal" -}}
{{- $g := .Values.global | default dict -}}
{{- $istio := $g.istio | default dict -}}
{{- $ig := $istio.ingressGateway | default dict -}}
{{- $ig.principal | default "cluster.local/ns/istio-system/sa/istio" -}}
{{- end -}}

{{/* "perProfile" | "shared": global.modelRegistry.mode, else modelRegistry.mode; fails on other values.
     Must agree with the umbrella and user-namespace (test/ci/check_model_registry_consistency.py). */}}
{{- define "kubeflow-hub.modelRegistryMode" -}}
{{- $g := .Values.global | default dict -}}
{{- $gmode := (($g.modelRegistry | default dict).mode | default "") | toString -}}
{{- $mode := $gmode | default ((.Values.modelRegistry | default dict).mode | default "perProfile") | toString -}}
{{- if not (has $mode (list "shared" "perProfile")) -}}
{{- fail (printf "kubeflow-hub: modelRegistry.mode must be \"shared\" or \"perProfile\", got %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* "true" in shared mode (render the kubeflow-namespace server and its wiring). */}}
{{- define "kubeflow-hub.isShared" -}}
{{- if eq (include "kubeflow-hub.modelRegistryMode" .) "shared" -}}true{{- end -}}
{{- end -}}

{{/* Controller REGISTRIES_NAMESPACE; required in perProfile mode when the reconciler is managed. */}}
{{- define "kubeflow-hub.registriesNamespace" -}}
{{- $ns := .Values.controller.env.registriesNamespace | default "" | toString -}}
{{- if $ns -}}
{{- $ns -}}
{{- else if and (not (include "kubeflow-hub.isShared" .)) (eq (include "kubeflow-hub.inferenceServiceController" .) "managed") -}}
{{- fail "kubeflow-hub: per-profile Model Registry mode with the InferenceService reconciler managed (the default in this mode) requires controller.env.registriesNamespace (a profile namespace). No registry runs in `kubeflow` in perProfile mode; label InferenceServices in other profiles with modelregistry.kubeflow.org/namespace=<profile>." -}}
{{- else -}}
kubeflow
{{- end -}}
{{- end -}}

{{/* INFERENCE_SERVICE_CONTROLLER: explicit value, else managed (perProfile) / false (shared). */}}
{{- define "kubeflow-hub.inferenceServiceController" -}}
{{- $raw := .Values.controller.env.inferenceServiceController -}}
{{- $v := "" -}}
{{- if kindIs "bool" $raw -}}{{- $v = toString $raw -}}{{- else if $raw -}}{{- $v = toString $raw -}}{{- end -}}
{{- if $v -}}{{ $v }}{{- else if include "kubeflow-hub.isShared" . -}}false{{- else -}}managed{{- end -}}
{{- end -}}
