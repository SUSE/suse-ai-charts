{{/*
Expand the name of the chart.
*/}}
{{- define "kserve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kserve.fullname" -}}
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
{{- define "kserve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kserve.labels" -}}
helm.sh/chart: {{ include "kserve.chart" . }}
{{ include "kserve.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kserve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kserve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kserve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kserve.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Build image reference from registry, repository, tag, and optional digest.
If digest is set, renders as: [registry/]repository:tag@digest
Usage: {{ include "kserve.image" .Values.controllerManager.image }}

Supports both flat structure (.registry, .repository, .tag, .digest)
and nested structure (.image.registry, .image.repository, .image.tag, .image.digest)
*/}}
{{- define "kserve.image" -}}
{{- $image := . }}
{{- if hasKey . "image" }}
{{- $image = .image }}
{{- end }}
{{- $registry := $image.registry }}
{{- if not $registry }}
{{- $globalRegistry := "" }}
{{- if hasKey .Values "global" }}
{{- if hasKey .Values.global "imageRegistry" }}
{{- $globalRegistry = .Values.global.imageRegistry }}
{{- end }}
{{- end }}
{{- $registry = $globalRegistry }}
{{- end }}
{{- $ref := "" -}}
{{- if $registry -}}{{- $ref = printf "%s/%s:%s" $registry $image.repository $image.tag -}}{{- else -}}{{- $ref = printf "%s:%s" $image.repository $image.tag -}}{{- end -}}
{{- if $image.digest -}}{{- printf "%s@%s" $ref $image.digest -}}{{- else -}}{{- $ref -}}{{- end -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "kserve.imagePullSecrets" -}}
{{/*
Helm 2.11 supports the assignment of a value to a variable defined in a different scope,
but Helm 2.9 and 2.10 does not support it, so we need to implement this if-else logic.
Also, we can not use a single if because lazy evaluation is not an option
*/}}
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
