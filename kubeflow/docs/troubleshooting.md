# Testing, Troubleshooting & Known Limitations

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Upgrade Notes](upgrade-notes.md)

---

## Testing

### Connectivity smoke tests

Runs outside the cluster using `kubectl`. Checks pod health, Deployment readiness, CRDs, Secrets, TCP
service connectivity, SeaweedFS bucket presence, and HTTP health endpoints.

```bash
chmod +x test/smoke/smoke.sh
./test/smoke/smoke.sh [--user-namespace=<ns>] [--suse-registry=<mirror>] [--suse-app-collection=<mirror>]
```

### End-to-end tests

Tests a full KFP pipeline run, a Notebook lifecycle, a PyTorchJob, and a KServe InferenceService
prediction. Requires `kubectl` and `curl`.

```bash
chmod +x test/e2e/e2e.sh
./test/e2e/e2e.sh [--suse-registry=<mirror>] [--suse-app-collection=<mirror>] [--include-gpu-tests]
```

### Helm chart tests

```bash
helm test kubeflow -n kubeflow
```

---

## Troubleshooting

### Pods not starting — too many open files

Run on each cluster node:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512

# Persist across reboots
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-kubeflow.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.d/99-kubeflow.conf
```

### Pods stuck Pending — storage issues

```bash
kubectl get pvc -n kubeflow
kubectl describe pvc -n kubeflow <pvc-name>
kubectl get storageclass          # ensure a default StorageClass exists
```

If none is marked default, patch one:

```bash
kubectl patch storageclass <name> \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### `metadata-grpc` CrashLoopBackOff (MLMD)

The `metadb` database is created by a post-install hook Job. If the Job failed, re-run it:

```bash
kubectl delete job metadb-init -n kubeflow --ignore-not-found
helm template kubeflow charts/kubeflow -n kubeflow \
  --show-only 'charts/pipelines/templates/Job/metadb-init-kubeflow-Job.yaml' \
  | kubectl apply -n kubeflow -f -
```

### Pipeline runs stuck "Pending Execution"

The persistence agent must watch all namespaces. Check its `NAMESPACE` env var:

```bash
kubectl get deploy ml-pipeline-persistenceagent -n kubeflow \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -i namespace
```

The value must be `""` (empty string). A non-empty value (e.g. `kubeflow`) causes the agent to watch
only that namespace and miss workflow updates in user namespaces.

### TensorBoard unavailable / controller CrashLoopBackOff

Check that the `tensorboard-controller-config` ConfigMap contains both required keys:

```bash
kubectl get configmap -n kubeflow -l app=tensorboard-controller -o yaml | grep -A5 'data:'
```

Required keys:
- `ISTIO_HOST: "*"`
- `ISTIO_GATEWAY: kubeflow/kubeflow-gateway` (must be in `namespace/name` format)

If either key is wrong or missing, fix it via `helm upgrade` so the change persists across future
upgrades — either with `--set` flags or by adding the values to your override file:

```yaml
tensorboard-controller:
  configMapData:
    ISTIO_HOST: "*"
    ISTIO_GATEWAY: kubeflow/kubeflow-gateway
```

```bash
# From source
helm upgrade kubeflow . -n kubeflow \
  --reuse-values --force-conflicts \
  --set tensorboard-controller.configMapData.ISTIO_HOST="*" \
  --set tensorboard-controller.configMapData.ISTIO_GATEWAY=kubeflow/kubeflow-gateway

# From OCI registry (production)
helm upgrade kubeflow oci://registry.suse.com/ai/charts/kubeflow \
  --version <version> -n kubeflow \
  --reuse-values --force-conflicts \
  --set tensorboard-controller.configMapData.ISTIO_HOST="*" \
  --set tensorboard-controller.configMapData.ISTIO_GATEWAY=kubeflow/kubeflow-gateway
```

### KServe InferenceService not progressing

Verify the `ClusterStorageContainer` CRD and default object exist:

```bash
kubectl get crd clusterstoragecontainers.serving.kserve.io
kubectl get clusterstoragecontainer default
```

If either is missing, re-run `helm upgrade` — the chart installs them.

### "RBAC: access denied" for user namespace traffic

Rancher Istio uses the `istio` ServiceAccount (not `istio-ingressgateway-service-account`). The
`rancher-ingressgateway-access` AuthorizationPolicy in each user namespace handles this.

If you pre-created the AuthorizationPolicy with `kubectl` before the first Helm install, add Helm
ownership labels/annotations before upgrade:

```bash
kubectl label authorizationpolicy rancher-ingressgateway-access \
  -n kubeflow-user-example-com app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate authorizationpolicy rancher-ingressgateway-access \
  -n kubeflow-user-example-com \
  meta.helm.sh/release-name=kubeflow \
  meta.helm.sh/release-namespace=kubeflow --overwrite
```

### SeaweedFS pod stuck ContainerCreating

On K3s 1.34 + cri-dockerd (Rancher Desktop), a race between the CNI and the container runtime can leave
the SeaweedFS pod stuck. SeaweedFS acquires a LevelDB file lock on startup; if the pod is stuck, the
lock is held and the next pod will also fail to start.

```bash
docker ps | grep seaweedfs                        # find the Docker container ID for the stuck pod
docker kill <container-id>                         # release the lock
kubectl delete pod -n kubeflow -l app=seaweedfs    # a new pod will start cleanly
```

### Dex login loop (infinite redirect)

This usually means oauth2-proxy is receiving a 403 from an Istio AuthorizationPolicy rather than from
oauth2-proxy itself. The Lua-redirect filter only converts 403 → 302 when the response includes a
`set-cookie` header; AuthorizationPolicy 403s do not have one. Check for sidecar-level
AuthorizationPolicy denials:

```bash
kubectl logs -n istio-system -l app=istiod | grep "RBAC"
kubectl get authorizationpolicy -A
```

---

## Known Limitations

- Namespace names are hardcoded in most templates (`kubeflow`, `knative-serving`, `istio-system`).
  Deploying to a non-standard namespace requires template modifications.
- Argo workflow executor image pull secrets must be set via the `workflow-controller-configmap`
  `workflowDefaults` field — they cannot be set via Helm values at runtime because the configmap is
  rendered at pod-create time, not Helm time.
- `knativeServing.enabled` must be `true` for KServe to function. Disabling Knative Serving will cause
  KServe InferenceService resources to remain in a non-Ready state.
- Only the Cloudflare provider is supported for external-dns out of the box. Other providers (AWS
  Route53, Azure, GCP) require additional `externaldns.env` configuration.
- **SeaweedFS is single-node, non-replicated.** Pipeline artifact storage has no HA; a SeaweedFS pod
  restart causes a brief (~10–60s) S3 outage. For production HA, replace SeaweedFS with an external
  S3-compatible store.
- **Not all Kubeflow controllers support multiple replicas.** Leader election is confirmed for
  katib-controller (v0.17+), training-operator, kserve-controller-manager, pvcviewer-controller, and
  model-registry-controller — these are safe to scale via `ha-overrides.yaml`. It is **not** confirmed
  for notebook-controller, profiles-controller, tensorboard-controller, and several KFP background
  workers; setting `replicaCount > 1` for those may cause duplicate reconciliation or data corruption.
- **CRDs are not automatically upgraded by `helm upgrade`.** Kubeflow CRDs are placed in `crds/`
  subdirectories; Helm intentionally skips them on upgrade. After a chart version bump, apply them
  manually — see [Applying CRDs on upgrade](upgrade-notes.md#applying-crds).
- **Dex must be v0.23.0 (dex 2.42.0).** v0.24.0 (dex 2.44.0) uses Go 1.25 which introduced strict IPv6
  URL parsing. Kubernetes API server addresses like `[10.43.0.1]:443` are rejected, crashing Dex on
  startup. The chart pins v0.23.0.
- **SeaweedFS image is pulled from Docker Hub** (`chrislusf/seaweedfs:4.00`). Air-gapped clusters or
  environments with Docker Hub pull-rate limits will fail to start Kubeflow Pipelines. Mirror the image
  to a private registry and set `global.imageRegistry` (or `global.suseRegistry`) to override.
