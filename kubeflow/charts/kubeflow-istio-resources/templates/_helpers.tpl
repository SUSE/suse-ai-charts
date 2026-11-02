{{/*
Expand the name of the chart.
*/}}
{{- define "kubeflow-istio-resources.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kubeflow-istio-resources.fullname" -}}
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
{{- define "kubeflow-istio-resources.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubeflow-istio-resources.labels" -}}
helm.sh/chart: {{ include "kubeflow-istio-resources.chart" . }}
{{ include "kubeflow-istio-resources.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubeflow-istio-resources.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeflow-istio-resources.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kubeflow-istio-resources.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kubeflow-istio-resources.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Dedicated KServe inference gateway reference ("<namespace>/<name>").
Single source of truth is global.kserveGateway.name (umbrella parent); falls back
to the chart-local default for standalone sub-chart installs. Consumed by the
kserve-ingress-gateway Gateway template (split into name/namespace below), and
mirrored by the knative-serving / kserve sub-charts.
*/}}
{{- define "kubeflow-istio-resources.kserveGatewayRef" -}}
{{- $g := .Values.global | default dict -}}
{{- if and $g.kserveGateway $g.kserveGateway.name -}}
{{- $g.kserveGateway.name -}}
{{- else -}}
{{- "kubeflow/kserve-ingress-gateway" -}}
{{- end -}}
{{- end -}}

{{/* Namespace part of the KServe gateway ref. */}}
{{- define "kubeflow-istio-resources.kserveGatewayNamespace" -}}
{{- (splitList "/" (include "kubeflow-istio-resources.kserveGatewayRef" .)) | first -}}
{{- end -}}

{{/* Name part of the KServe gateway ref. */}}
{{- define "kubeflow-istio-resources.kserveGatewayName" -}}
{{- (splitList "/" (include "kubeflow-istio-resources.kserveGatewayRef" .)) | last -}}
{{- end -}}

{{/*
Ingress-gateway workload label selector — SINGLE SOURCE OF TRUTH.
Reads global.istio.ingressGateway.selector (umbrella parent) and falls back to a
concrete {istio: istio} so an absent/null selector NEVER renders empty: this value
drives the istio-system authn EnvoyFilter workloadSelector and the native CUSTOM /
require-jwt AuthorizationPolicies + dex-jwt RequestAuthentication (all patches /
selectors are context: GATEWAY), where an empty selector would attach the auth
chain to EVERY gateway in the mesh. Emit as a YAML map; callers nindent the include.
*/}}
{{- define "kubeflow-istio-resources.ingressGatewaySelector" -}}
{{- $g := .Values.global | default dict -}}
{{- $istio := $g.istio | default dict -}}
{{- $ig := $istio.ingressGateway | default dict -}}
{{- if $ig.selector -}}
{{- toYaml $ig.selector -}}
{{- else -}}
istio: istio
{{- end -}}
{{- end -}}

{{/*
Ingress-gateway authentication mode: "native" (default) or
"envoyfilter". Single source of truth is global.oauth2Proxy.gatewayAuthMode.
*/}}
{{- define "kubeflow-istio-resources.gatewayAuthMode" -}}
{{- $g := .Values.global | default dict -}}
{{- $o := $g.oauth2Proxy | default dict -}}
{{- $o.gatewayAuthMode | default "native" -}}
{{- end -}}
