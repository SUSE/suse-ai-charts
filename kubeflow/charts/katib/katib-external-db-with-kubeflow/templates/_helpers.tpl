{{/*
Expand the name of the chart.
*/}}
{{- define "katib.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "katib.fullname" -}}
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
{{- define "katib.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "katib.labels" -}}
helm.sh/chart: {{ include "katib.chart" . }}
{{ include "katib.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "katib.selectorLabels" -}}
app.kubernetes.io/name: {{ include "katib.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "katib.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "katib.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render a container image string from image values.
If digest is set, renders as: [registry/]repository:tag@digest
*/}}
{{- define "katib.image" -}}
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
