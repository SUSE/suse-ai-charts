{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "pvcviewer-controller.imagePullSecrets" -}}
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
Return the proper SUSE AI Image Registry
Precedence: global.imageRegistry > global.suseRegistry > component image.registry
Usage: include "pvcviewer-controller.suseImageRegistry" (dict "ctx" $ "registry" .Values.<component>.registry)
*/}}
{{- define "pvcviewer-controller.suseImageRegistry" -}}
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
Return the viewer image (injected into PVCViewer pods), SUSE AI family.
Precedence: global.imageRegistry > global.suseRegistry > viewerImage.registry
*/}}
{{- define "pvcviewer-controller.viewerImage" -}}
{{- $reg := "" -}}
{{- if .Values.global.imageRegistry -}}{{- $reg = .Values.global.imageRegistry -}}
{{- else if .Values.global.suseRegistry -}}{{- $reg = .Values.global.suseRegistry -}}
{{- else -}}{{- $reg = .Values.viewerImage.registry -}}{{- end -}}
{{- $reg -}}/{{ .Values.viewerImage.repository }}{{- if .Values.viewerImage.digest }}@{{ .Values.viewerImage.digest }}{{- else }}:{{ .Values.viewerImage.tag }}{{- end }}
{{- end -}}
