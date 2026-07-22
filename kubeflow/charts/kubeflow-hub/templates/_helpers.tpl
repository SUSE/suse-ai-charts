{{/*
Return the proper SUSE AI Image Registry.
Precedence: global.imageRegistry > global.suseRegistry > image.registry
*/}}
{{- define "kubeflow-hub.suseImageRegistry" -}}
{{- if .Values.global.imageRegistry -}}
  {{- .Values.global.imageRegistry -}}
{{- else if .Values.global.suseRegistry -}}
  {{- .Values.global.suseRegistry -}}
{{- else -}}
  {{- .Values.image.registry -}}
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
