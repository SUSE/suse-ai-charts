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
Precedence: global.imageRegistry > global.suseRegistry > image.registry
*/}}
{{- define "pvcviewer-controller.suseImageRegistry" -}}
{{- if .Values.global.imageRegistry -}}
  {{- .Values.global.imageRegistry -}}
{{- else if .Values.global.suseRegistry -}}
  {{- .Values.global.suseRegistry -}}
{{- else -}}
  {{- .Values.image.registry -}}
{{- end -}}
{{- end -}}

{{/*
Return the viewer image (injected into PVCViewer pods) with registry override support
*/}}
{{- define "pvcviewer-controller.viewerImage" -}}
{{- if .Values.global.imageRegistry -}}
  {{- .Values.global.imageRegistry -}}/{{ .Values.viewerImage.repository }}{{- if .Values.viewerImage.digest }}@{{ .Values.viewerImage.digest }}{{- else }}:{{ .Values.viewerImage.tag }}{{- end }}
{{- else if .Values.global.suseRegistry -}}
  {{- .Values.global.suseRegistry -}}/{{ .Values.viewerImage.repository }}{{- if .Values.viewerImage.digest }}@{{ .Values.viewerImage.digest }}{{- else }}:{{ .Values.viewerImage.tag }}{{- end }}
{{- else -}}
  {{- .Values.viewerImage.registry -}}/{{ .Values.viewerImage.repository }}{{- if .Values.viewerImage.digest }}@{{ .Values.viewerImage.digest }}{{- else }}:{{ .Values.viewerImage.tag }}{{- end }}
{{- end -}}
{{- end -}}
