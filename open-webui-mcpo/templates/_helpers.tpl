{{- define "open-webui-mcpo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "open-webui-mcpo.fullname" -}}
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

{{- define "open-webui-mcpo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "open-webui-mcpo.labels" -}}
helm.sh/chart: {{ include "open-webui-mcpo.chart" . }}
{{ include "open-webui-mcpo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "open-webui-mcpo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "open-webui-mcpo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "open-webui-mcpo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "open-webui-mcpo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Render open-webui-mcpo configuration as pretty JSON */}}
{{- define "open-webui-mcpo.config" -}}
{{- .Values.config | toPrettyJson }}
{{- end }}

{{- define "open-webui-mcpo.ingressPath" -}}
{{- if and .Values.ingress.path (ne .Values.ingress.path "/") -}}
{{ printf "%s(/|$)(.*)" .Values.ingress.path }}
{{- else -}}
/
{{- end -}}
{{- end }}

{{- define "open-webui-mcpo.ingressUseRegex" -}}
{{- if and (ne .Values.ingress.path "/") (not (hasKey .Values.ingress.annotations "nginx.ingress.kubernetes.io/use-regex")) -}}
{{- $_ := set .Values.ingress.annotations "nginx.ingress.kubernetes.io/use-regex" "true" -}}
{{- end -}}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "open-webui-mcpo.imagePullSecrets" -}}
{{/*
Helm 2.11 supports the assignment of a value to a variable defined in a different scope,
but Helm 2.9 and 2.10 does not support it, so we need to implement this if-else logic.
Also, we can not use a single if because lazy evaluation is not an option
*/}}
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
