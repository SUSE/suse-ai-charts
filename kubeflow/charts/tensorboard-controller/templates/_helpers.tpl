{{/*
Expand the name of the chart.
*/}}
{{- define "tensorboard-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "tensorboard-controller.fullname" -}}
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
{{- define "tensorboard-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tensorboard-controller.labels" -}}
helm.sh/chart: {{ include "tensorboard-controller.chart" . }}
{{ include "tensorboard-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tensorboard-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tensorboard-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "tensorboard-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tensorboard-controller.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render a container image string from image values.
*/}}
{{- define "tensorboard-controller.image" -}}
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
{{- if $registry -}}{{- printf "%s/%s:%s" $registry .repository .tag -}}{{- else -}}{{- printf "%s:%s" .repository .tag -}}{{- end -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "tensorboard-controller.imagePullSecrets" -}}
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
