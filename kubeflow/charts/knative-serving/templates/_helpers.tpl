{{/*
Expand the name of the chart.
*/}}
{{- define "knative-serving.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "knative-serving.fullname" -}}
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
{{- define "knative-serving.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "knative-serving.labels" -}}
helm.sh/chart: {{ include "knative-serving.chart" . }}
{{ include "knative-serving.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "knative-serving.selectorLabels" -}}
app.kubernetes.io/name: {{ include "knative-serving.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "knative-serving.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "knative-serving.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "knative-serving.imagePullSecrets" -}}
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
{{- define "knative-serving.imagePullPolicy" -}}
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
Return the proper SUSE AI Image Registry
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: {{ include "knative-serving.suseImageRegistry" (dict "ctx" . "registry" .Values.component.image.registry) }}
*/}}
{{- define "knative-serving.suseImageRegistry" -}}
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
Dedicated KServe inference gateway reference ("<namespace>/<name>").
Single source of truth is global.kserveGateway.name (umbrella parent); falls back
to the chart-local default for standalone installs. config-istio derives its
"gateway.<namespace>.<name>" key from the namespace/name parts below.
*/}}
{{- define "knative-serving.kserveGatewayRef" -}}
{{- $g := .Values.global | default dict -}}
{{- if and $g.kserveGateway $g.kserveGateway.name -}}
{{- $g.kserveGateway.name -}}
{{- else -}}
{{- "kubeflow/kserve-ingress-gateway" -}}
{{- end -}}
{{- end -}}

{{- define "knative-serving.kserveGatewayNamespace" -}}
{{- (splitList "/" (include "knative-serving.kserveGatewayRef" .)) | first -}}
{{- end -}}

{{- define "knative-serving.kserveGatewayName" -}}
{{- (splitList "/" (include "knative-serving.kserveGatewayRef" .)) | last -}}
{{- end -}}

{{/*
Return the proper Knative domain template.
If global.kserveExternalHttps is enabled, it returns the flattened single-label
template so a shared "*.{Domain}" wildcard cert covers the route host (Let's
Encrypt cannot issue "*.*.domain"). Otherwise it returns the user-supplied
.Values.domainTemplate (empty = Knative's dotted upstream default).

The template is rendered at runtime by Knative's controller with Go's stdlib
text/template (checkDomainTemplate validates it at ConfigMap load) — NO Sprig —
so we cannot hash here; only .Name/.Namespace/.Domain and stdlib built-ins are
available. We join name and namespace with "-". See the umbrella README for the
cross-tenant naming caveat this single-label form implies.
*/}}
{{- define "knative-serving.domainTemplate" -}}
{{- $template := .Values.domainTemplate -}}
{{- if not $template -}}
  {{- if and .Values.global (hasKey .Values.global "kserveExternalHttps") .Values.global.kserveExternalHttps -}}
    {{- $template = `{{ .Name }}-{{ .Namespace }}.{{ .Domain }}` -}}
  {{- end -}}
{{- end -}}
{{- $template -}}
{{- end -}}

{{/*
Return the Knative Serving base domain (the key of the config-domain ConfigMap).
Driven by global.kserveDomain when set (umbrella single source of truth), falling
back to the chart-local .Values.domain for standalone installs.
*/}}
{{- define "knative-serving.domain" -}}
{{- if and .Values.global .Values.global.kserveDomain -}}
  {{- .Values.global.kserveDomain -}}
{{- else -}}
  {{- .Values.domain -}}
{{- end -}}
{{- end -}}
