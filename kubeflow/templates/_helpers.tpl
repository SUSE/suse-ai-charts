{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "kubeflow.imagePullSecrets" -}}
{{- if and (hasKey .Values "global") .Values.global }}
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
Build image reference from registry, repository, and tag.
If global.imageRegistry is set and image.registry is empty, global is used as fallback.
Usage: {{ include "kubeflow.image" .Values.image }}
*/}}
{{- define "kubeflow.image" -}}
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
