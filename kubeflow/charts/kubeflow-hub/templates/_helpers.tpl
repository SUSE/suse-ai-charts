{{/*
Return the proper SUSE AI Image Registry
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: include "kubeflow-hub.suseImageRegistry" (dict "ctx" $ "registry" .Values.image.registry)
*/}}
{{- define "kubeflow-hub.suseImageRegistry" -}}
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
Return image pull secrets.
*/}}
{{- define "kubeflow-hub.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end -}}
{{- end -}}
