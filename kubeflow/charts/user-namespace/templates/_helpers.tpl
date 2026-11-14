{{/*
Expand the name of the chart.
*/}}
{{- define "user-namespace.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "user-namespace.fullname" -}}
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
{{- define "user-namespace.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "user-namespace.labels" -}}
helm.sh/chart: {{ include "user-namespace.chart" . }}
{{ include "user-namespace.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "user-namespace.selectorLabels" -}}
app.kubernetes.io/name: {{ include "user-namespace.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "user-namespace.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "user-namespace.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "user-namespace.imagePullSecrets" -}}
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
Labels for chart-created profile namespaces. The profiles controller only adds istio-injection to
namespaces it creates itself, so set it here; Pod Security baseline only with global.istio.cni.
*/}}
{{- define "user-namespace.profileNamespaceLabels" -}}
app.kubernetes.io/part-of: kubeflow-profile
istio-injection: enabled
{{- if eq (include "user-namespace.istioCni" .) "true" }}
pod-security.kubernetes.io/enforce: baseline
{{- end }}
{{- end -}}

{{/*
Return the proper SUSE AI Image Registry.
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: {{ include "user-namespace.suseImageRegistry" (dict "ctx" . "registry" .Values.modelRegistry.server.image.registry) }}
*/}}
{{- define "user-namespace.suseImageRegistry" -}}
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
Namespace of an additionalUsers[] entry: .namespace, else the email slug ("@" → "--", "." → "-").
Emails differing only in "." vs "-" collide; set .namespace for those. The umbrella's
kubeflow.modelRegistryFirstNamespace repeats this rule (test/ci/check_model_registry_consistency.py).
*/}}
{{- define "user-namespace.profileNamespace" -}}
{{- .namespace | default (.email | lower | replace "." "-" | replace "@" "--") -}}
{{- end -}}

{{/* Fails unless .ns is a valid, non-system namespace name; .what names the value in the error. */}}
{{- define "user-namespace.checkProfileNamespace" -}}
{{- $n := toString .ns -}}
{{- if or (has $n (list "kubeflow" "istio-system")) (hasPrefix "kube-" $n) (hasPrefix "knative-" $n) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $n)) -}}
{{- fail (printf "user-namespace: %s %q is not a profile namespace (system namespace or invalid name)" .what $n) -}}
{{- end -}}
{{- end -}}

{{/* JSON list of {"namespace","owner"}: the example profile (if profile.enabled) plus every additionalUsers[] entry. */}}
{{- define "user-namespace.profiles" -}}
{{- $out := list -}}
{{- if .Values.profile.enabled }}{{ $out = append $out (dict "namespace" .Values.profile.name "owner" .Values.profile.owner.name) }}{{ end -}}
{{- range .Values.additionalUsers -}}
{{- $out = append $out (dict "namespace" (include "user-namespace.profileNamespace" .) "owner" .email) -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/* Registry namespaces: the profiles above plus modelRegistry.extraNamespaces; fails on duplicates. */}}
{{- define "user-namespace.modelRegistry.namespaces" -}}
{{- $out := include "user-namespace.profiles" . | fromJsonArray -}}
{{- range ((.Values.modelRegistry).extraNamespaces | default list) -}}
{{- $out = append $out (dict "namespace" (toString .) "owner" "") -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $out -}}
{{- if hasKey $seen .namespace -}}
{{- fail (printf "user-namespace: namespace %q is listed more than once across the example profile, additionalUsers[] and modelRegistry.extraNamespaces" .namespace) -}}
{{- end -}}
{{- $_ := set $seen .namespace true -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
Application Collection image registry (precedence: global.imageRegistry >
global.suseApplicationCollectionRegistry > component registry).
*/}}
{{- define "user-namespace.suseApplicationCollectionRegistry" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.global.imageRegistry -}}
  {{- $ctx.Values.global.imageRegistry -}}
{{- else if $ctx.Values.global.suseApplicationCollectionRegistry -}}
  {{- $ctx.Values.global.suseApplicationCollectionRegistry -}}
{{- else -}}
  {{- .registry -}}
{{- end -}}
{{- end -}}

{{/* Fully qualified image reference. Usage: include "user-namespace.image" (dict "registry" $r "image" $img) */}}
{{- define "user-namespace.image" -}}
{{- if .registry }}{{ .registry }}/{{ end }}{{ .image.repository }}{{- if .image.digest }}@{{ .image.digest }}{{- else }}:{{ .image.tag }}{{- end }}
{{- end -}}

{{/* Model Registry common labels (per-profile data plane). */}}
{{- define "user-namespace.modelRegistry.labels" -}}
app.kubernetes.io/part-of: model-registry
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "user-namespace.chart" . }}
{{- end -}}

{{/* DB connection for namespace .ns as JSON {"host","port","database","secret","sslMode"}. */}}
{{- define "user-namespace.modelRegistry.db" -}}
{{- $db := .root.Values.modelRegistry.db -}}
{{- if eq $db.mode "external" -}}
{{- $name := printf "%s%s" $db.external.databasePrefix (.ns | replace "-" "_") -}}
{{- toJson (dict "host" $db.external.host "port" (toString $db.external.port) "database" $name "secret" $db.external.existingSecret "sslMode" $db.external.sslMode) -}}
{{- else -}}
{{- toJson (dict "host" "model-registry-db" "port" "5432" "database" $db.embedded.database "secret" ($db.embedded.existingSecret | default "model-registry-db-secrets") "sslMode" "disable") -}}
{{- end -}}
{{- end -}}

{{/* "true" when the registries render: modelRegistry.enabled if set, else global.modelRegistry.mode (unset → perProfile).
     Must agree with the umbrella and kubeflow-hub (test/ci/check_model_registry_consistency.py). */}}
{{- define "user-namespace.modelRegistry.enabled" -}}
{{- $mr := .Values.modelRegistry | default dict -}}
{{- if kindIs "bool" $mr.enabled -}}
{{- if $mr.enabled -}}true{{- end -}}
{{- else -}}
{{- $mode := dig "modelRegistry" "mode" "" (.Values.global | default dict) | default "perProfile" | toString -}}
{{- if not (has $mode (list "shared" "perProfile")) -}}
{{- fail (printf "user-namespace: global.modelRegistry.mode must be \"shared\" or \"perProfile\", got %q" $mode) -}}
{{- end -}}
{{- if eq $mode "perProfile" -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* Validate modelRegistry values once (fail closed). */}}
{{- define "user-namespace.modelRegistry.validate" -}}
{{- $db := .Values.modelRegistry.db -}}
{{- range ((.Values.modelRegistry).extraNamespaces | default list) -}}
{{- include "user-namespace.checkProfileNamespace" (dict "what" "modelRegistry.extraNamespaces entry" "ns" .) -}}
{{- end -}}
{{- if not (has $db.mode (list "embedded" "external")) -}}
{{- fail (printf "user-namespace: modelRegistry.db.mode must be \"embedded\" or \"external\", got %q" $db.mode) -}}
{{- end -}}
{{- if and (eq $db.mode "external") (or (not $db.external.host) (not $db.external.existingSecret)) -}}
{{- fail "user-namespace: modelRegistry.db.mode=external requires modelRegistry.db.external.host and modelRegistry.db.external.existingSecret (Secret with POSTGRES_USER/POSTGRES_PASSWORD keys, present in every profile namespace)" -}}
{{- end -}}
{{- if eq $db.mode "external" -}}
{{- range (include "user-namespace.modelRegistry.namespaces" . | fromJsonArray) -}}
{{- $name := (include "user-namespace.modelRegistry.db" (dict "root" $ "ns" .namespace) | fromJson).database -}}
{{- if gt (len $name) 63 -}}
{{- fail (printf "user-namespace: external database name %q for namespace %q is %d bytes; Postgres truncates identifiers to 63, which would break restarts and can make two namespaces share one database. Shorten modelRegistry.db.external.databasePrefix or the namespace name." $name .namespace (len $name)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* global.istio.cni as "true"/"false" (default true). Copied per chart; CI keeps the copies equal. */}}
{{- define "user-namespace.istioCni" -}}
{{- ne (toString (dig "istio" "cni" true (.Values.global | default dict))) "false" -}}
{{- end -}}
