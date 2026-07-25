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
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "kubeflow-hub.imagePullSecrets" -}}
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
