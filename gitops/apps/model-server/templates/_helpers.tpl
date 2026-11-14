{{- define "ms.nodepool" -}}{{ .Values.project }}-{{ .Values.tier }}{{- end -}}
{{- define "ms.decode" -}}{{ .Values.release }}-vllm-decode{{- end -}}

{{- define "ms.selectorLabels" -}}
llm-d.ai/inference-pool: {{ .Values.release }}
llm-d.ai/role: decode
{{- end -}}

{{- define "ms.labels" -}}
{{ include "ms.selectorLabels" . }}
llm-d-eks-lab/tier: {{ .Values.tier }}
app.kubernetes.io/part-of: llm-d-eks-lab
{{- end -}}
