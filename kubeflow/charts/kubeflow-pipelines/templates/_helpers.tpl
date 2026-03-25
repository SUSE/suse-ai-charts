{{/*
Expand the name of the chart.
*/}}
{{- define "kubeflow-pipelines.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kubeflow-pipelines.fullname" -}}
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
{{- define "kubeflow-pipelines.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubeflow-pipelines.labels" -}}
helm.sh/chart: {{ include "kubeflow-pipelines.chart" . }}
{{ include "kubeflow-pipelines.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubeflow-pipelines.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeflow-pipelines.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kubeflow-pipelines.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kubeflow-pipelines.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Build image reference from registry, repository, tag, and optional digest.
If digest is set, renders as: [registry/]repository:tag@digest
This allows SHA256 pinning for supply-chain security without losing human-readable tags.
Usage: {{ include "kubeflow-pipelines.image" .Values.someComponent.image }}
*/}}
{{- define "kubeflow-pipelines.image" -}}
{{- $registry := .registry -}}
{{- if not $registry -}}
{{- $globalRegistry := "" -}}
{{- if hasKey .Values "global" -}}
{{- if hasKey .Values.global "imageRegistry" -}}
{{- $globalRegistry = .Values.global.imageRegistry -}}
{{- end -}}
{{- end -}}
{{- $registry = $globalRegistry -}}
{{- end -}}
{{- $ref := "" -}}
{{- if $registry -}}{{- $ref = printf "%s/%s:%s" $registry .repository .tag -}}{{- else -}}{{- $ref = printf "%s:%s" .repository .tag -}}{{- end -}}
{{- if .digest -}}{{- printf "%s@%s" $ref .digest -}}{{- else -}}{{- $ref -}}{{- end -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "kubeflow-pipelines.imagePullSecrets" -}}
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
