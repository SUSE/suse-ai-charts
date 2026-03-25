{{/*
Expand the name of the chart.
*/}}
{{- define "knative-eventing.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "knative-eventing.fullname" -}}
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
{{- define "knative-eventing.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "knative-eventing.labels" -}}
helm.sh/chart: {{ include "knative-eventing.chart" . }}
{{ include "knative-eventing.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "knative-eventing.selectorLabels" -}}
app.kubernetes.io/name: {{ include "knative-eventing.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "knative-eventing.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "knative-eventing.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "knative-eventing.imagePullSecrets" -}}
{{- if .Values.global }}
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
Return the proper image pull policy.
Uses the chart-level image.pullPolicy as primary, falling back to global.imagePullPolicy.
*/}}
{{- define "knative-eventing.imagePullPolicy" -}}
{{- $image := . }}
{{- if hasKey . "image" }}
{{- $image = .image }}
{{- end }}
{{- $policy := $image.pullPolicy }}
{{- if not $policy }}
{{- $globalPolicy := "" }}
{{- if hasKey . "context" }}
{{- $ctx := .context }}
{{- if hasKey $ctx.Values "global" }}
{{- if hasKey $ctx.Values.global "imagePullPolicy" }}
{{- $globalPolicy = $ctx.Values.global.imagePullPolicy }}
{{- end }}
{{- end }}
{{- end }}
{{- $policy = $globalPolicy }}
{{- end }}
{{- $policy -}}
{{- end -}}

{{/*
Build image reference from registry, repository, tag, and digest.
If global.imageRegistry is set, it is used as fallback.
If digest is provided, image uses @sha256:... format; otherwise uses :tag format.
Usage: {{ include "knative-eventing.image" (dict "image" .Values.controller.image "context" .) }}

Supports both flat structure (.registry, .repository, .tag, .digest)
and nested structure (.image.registry, .image.repository, .image.tag, .image.digest)
*/}}
{{- define "knative-eventing.image" -}}
{{- $image := . }}
{{- if hasKey . "image" }}
{{- $image = .image }}
{{- end }}
{{- $registry := $image.registry }}
{{- if not $registry }}
{{- $globalRegistry := "" }}
{{- if hasKey . "context" }}
{{- $ctx := .context }}
{{- if hasKey $ctx.Values "global" }}
{{- if hasKey $ctx.Values.global "imageRegistry" }}
{{- $globalRegistry = $ctx.Values.global.imageRegistry }}
{{- end }}
{{- end }}
{{- end }}
{{- $registry = $globalRegistry }}
{{- end }}
{{- $ref := "" -}}
{{- if $image.digest -}}
{{- if $registry -}}{{- $ref = printf "%s/%s@%s" $registry $image.repository $image.digest -}}{{- else -}}{{- $ref = printf "%s@%s" $image.repository $image.digest -}}{{- end -}}
{{- else if $image.tag -}}
{{- if $registry -}}{{- $ref = printf "%s/%s:%s" $registry $image.repository $image.tag -}}{{- else -}}{{- $ref = printf "%s:%s" $image.repository $image.tag -}}{{- end -}}
{{- end -}}
{{- $ref -}}
{{- end -}}
