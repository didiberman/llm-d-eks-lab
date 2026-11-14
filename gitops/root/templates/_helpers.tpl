{{- /*
  Shared by every child Application:
  - the resources finalizer makes deleting an Application delete what it
    deployed. Without it, pruning a child app (tier -> none) would orphan the
    NodePool and the GPU nodes would keep billing.
  - automated prune + selfHeal: git is the only way to change the cluster.
*/ -}}
{{- define "root.common" }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
{{- end }}

{{- define "root.sync" }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 5m
{{- end }}
