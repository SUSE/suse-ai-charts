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
Return the proper Application Collection Image Registry.
Precedence: global.imageRegistry > global.suseApplicationCollection > appCollection.registry
*/}}
{{- define "kubeflow.suseApplicationCollectionRegistry" -}}
{{- if .Values.global.imageRegistry -}}
  {{- .Values.global.imageRegistry -}}
{{- else if .Values.global.suseApplicationCollection -}}
  {{- .Values.global.suseApplicationCollection -}}
{{- else -}}
  {{- .Values.appCollection.registry -}}
{{- end -}}
{{- end -}}
