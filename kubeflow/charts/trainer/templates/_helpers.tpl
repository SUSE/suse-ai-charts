{{/*
Expand the name of the chart.
*/}}
{{- define "trainer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "trainer.fullname" -}}
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
{{- define "trainer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "trainer.labels" -}}
helm.sh/chart: {{ include "trainer.chart" . }}
{{ include "trainer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "trainer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trainer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "trainer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "trainer.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "trainer.imagePullSecrets" -}}
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
Usage: {{ include "trainer.suseImageRegistry" (dict "ctx" . "registry" <SIBLING>.registry) }}
*/}}
{{- define "trainer.suseImageRegistry" -}}
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
Return the SUSE Application Collection registry (dp.apps.rancher.io images such as kubectl).
Precedence: global.imageRegistry > global.suseApplicationCollectionRegistry > component image.registry
Usage: {{ include "trainer.suseApplicationCollectionRegistry" (dict "ctx" . "registry" <SIBLING>.registry) }}
*/}}
{{- define "trainer.suseApplicationCollectionRegistry" -}}
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
Pod-template metadata for the bundled runtimes: the Istio sidecar mode
(runtimes.istioSidecar) plus runtimes.podAnnotations, which win on conflicts.
  disabled: sidecar.istio.io/inject "false". Training pods leave the mesh: a regular
            sidecar outlives the training container, so pods would never complete.
  native:   sidecar.istio.io/nativeSidecar "true". The sidecar runs as a native
            (init) sidecar that stops with the pod, so pods complete inside the mesh
            (mTLS, AuthorizationPolicies); same pattern as the chart's test pods.
  default:  no Istio annotation; the namespace's injection setting applies.
Renders nothing when there are no annotations.
*/}}
{{- define "trainer.runtimePodMetadata" -}}
{{- $mode := .Values.runtimes.istioSidecar | default "disabled" -}}
{{- $a := dict -}}
{{- if eq $mode "disabled" -}}
{{-   $_ := set $a "sidecar.istio.io/inject" "false" -}}
{{- else if eq $mode "native" -}}
{{-   $_ := set $a "sidecar.istio.io/nativeSidecar" "true" -}}
{{- else if ne $mode "default" -}}
{{-   fail (printf "trainer.runtimes.istioSidecar must be one of disabled, native, default (got %q)" $mode) -}}
{{- end -}}
{{- $a = merge (deepCopy (.Values.runtimes.podAnnotations | default dict)) $a -}}
{{- if $a -}}
metadata:
  annotations:
    {{- toYaml $a | nindent 4 }}
{{- end }}
{{- end -}}

{{/*
Labels on the bundled ClusterTrainingRuntimes. The runtimes applier Job selects on
managed-by + instance to prune runtimes that are no longer in the chart (renamed,
dropped, or switched off such as torchtune.enabled=false).
*/}}
{{- define "trainer.runtimeLabels" -}}
app.kubernetes.io/managed-by: kubeflow-trainer-runtimes-applier
app.kubernetes.io/instance: {{ .Release.Name }}
{{- /* Not helm.sh/chart: Helm doesn't own these objects. */}}
trainer.kubeflow.org/bundled-runtime-version: {{ .Chart.Version | replace "+" "_" | quote }}
{{- end -}}
