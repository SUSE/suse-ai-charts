{{/*
Expand the name of the chart.
*/}}
{{- define "profiles-and-kfam.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "profiles-and-kfam.fullname" -}}
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
{{- define "profiles-and-kfam.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "profiles-and-kfam.labels" -}}
helm.sh/chart: {{ include "profiles-and-kfam.chart" . }}
{{ include "profiles-and-kfam.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "profiles-and-kfam.selectorLabels" -}}
app.kubernetes.io/name: {{ include "profiles-and-kfam.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "profiles-and-kfam.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "profiles-and-kfam.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "profiles-and-kfam.imagePullSecrets" -}}
{{- if and .Values.global (hasKey .Values "global") }}
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
Return the proper SUSE AI Image Registry
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: {{ include "profiles-and-kfam.suseImageRegistry" (dict "ctx" . "registry" .Values.kfam.image.registry) }}
*/}}
{{- define "profiles-and-kfam.suseImageRegistry" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.global.imageRegistry -}}
  {{- $ctx.Values.global.imageRegistry -}}
{{- else if $ctx.Values.global.suseRegistry -}}
  {{- $ctx.Values.global.suseRegistry -}}
{{- else -}}
  {{- .registry -}}
{{- end -}}
{{- end -}}
