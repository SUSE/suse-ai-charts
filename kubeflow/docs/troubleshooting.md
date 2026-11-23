# Testing, Troubleshooting & Known Limitations

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Upgrade Notes](upgrade-notes.md)

---

## Testing

### Connectivity smoke tests

Runs outside the cluster using `kubectl`. Checks pod health, Deployment readiness, CRDs, Secrets, TCP
service connectivity, SeaweedFS bucket presence, HTTP health endpoints, and the active
[ingress gateway auth mode](access-and-tls.md#ingress-gateway-authentication-mode) (asserts the native
CRs and the legacy EnvoyFilter are never both present, and that native mode's istiod extension
provider is registered).

```bash
chmod +x test/smoke/smoke.sh
./test/smoke/smoke.sh [--user-namespace=<ns>] [--suse-registry=<mirror>] [--suse-app-collection=<mirror>]
```

### End-to-end tests

Tests a full KFP pipeline run, a Notebook lifecycle, a PyTorchJob, a KServe InferenceService
prediction, and the ingress gateway auth deny path (an unauthenticated request through the shared
gateway is denied while `/dex/` stays allowlisted). Requires `kubectl` and `curl`.

```bash
chmod +x test/e2e/e2e.sh
./test/e2e/e2e.sh [--suse-registry=<mirror>] [--suse-app-collection=<mirror>] [--include-gpu-tests] [--include-gateway-tests]
```

`--include-gateway-tests` adds two calls through the gateway with a Dex login: KServe (403 without a
per-model AuthorizationPolicy, 200 with one) and the per-profile Model Registry (200 for the owner,
403 on another profile; that check needs a second profile with a registry, e.g. from
`user-namespace.additionalUsers`). They log in as `E2E_DEX_USER` / `E2E_DEX_PASSWORD` (default: the
demo user), which must be a Dex password login rather than an external OIDC connector, and fail if
that login fails.

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

Rancher Istio runs the ingress gateway as the `istio` ServiceAccount (not upstream's
`istio-ingressgateway-service-account`). The profiles controller admits whatever
`global.istio.ingressGateway.principal` is set to in each profile's `ns-owner-access-istio`
AuthorizationPolicy. Check that it matches your gateway and that the policy carries it:

```bash
kubectl get pod -n istio-system -l app=istio -o jsonpath='{.items[0].spec.serviceAccountName}'
kubectl get authorizationpolicy ns-owner-access-istio -n <profile> \
  -o jsonpath='{.spec.rules[0].from[0].source.principals}'
```

If the policy still shows the upstream ServiceAccount, restart the profiles controller so it
re-reconciles every profile: `kubectl rollout restart deploy/profiles-deployment -n kubeflow`.

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

### "Could not find CSRF cookie" when creating a notebook

The browser dropped the web app's CSRF cookie because it is marked `Secure` and the page was served
over plain HTTP. The chart sets `Secure` only when `kubeflow-istio-resources.tls.source` is set; so
either open the HTTPS URL, or, if TLS was turned on or off recently, restart the web apps
(`kubectl -n kubeflow rollout restart deploy/jupyter-web-app-deployment deploy/volumes-web-app-deployment
deploy/tensorboards-web-app-deployment`). An explicit `env.APP_SECURE_COOKIES: "true"` on a web app
also forces it; remove it for HTTP access.

### "Trainer control-plane version info is not available" (Kubeflow SDK)

The SDK's `TrainerClient` looks for the `kubeflow-trainer-public` ConfigMap in `kubeflow-system`, where
upstream installs Trainer; this chart installs Trainer in `kubeflow`. The warning is harmless (the client
keeps working). To silence it, set the namespace before creating the client:

```python
import os
os.environ["KUBEFLOW_SYSTEM_NAMESPACE"] = "kubeflow"
```

### "Jwt verification fails" after login

The Dex login succeeds, then the gateway answers `Jwt verification fails`.
Try clearing the cookies. If the login still fails after clearing the cookies:

istiod may have fetched Dex's signing keys while Dex wasn't serving them; it then keeps a placeholder
key that rejects every token. The chart refreshes the keys after every install and upgrade (the
`dex-jwt-refresh` Job), but this can still happen after an istiod restart, or if that Job couldn't
update `dex-jwt` (see `kubectl -n kubeflow logs job/dex-jwt-refresh`). istiod's log shows it:

```bash
kubectl -n istio-system logs deploy/istiod | grep "JWKS fetch failed"
# ... using public-only JWKS with discarded private key - JWT requests will be rejected
```

Restart istiod once Dex is running, then log in again:

```bash
kubectl -n kubeflow rollout status deploy/kubeflow-dex
kubectl -n istio-system rollout restart deploy/istiod
```

`Jwks doesn't have key to match kid` instead means the browser still holds a token from an earlier
install: clear the cookies for the dashboard host, or use a private window.

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
- **Native ingress-auth denies cookie-less external KServe inference on the shared gateway.** In the
  default native mode (`global.oauth2Proxy.gatewayAuthMode: native`), the `require-jwt` `DENY` policy
  denies any request without a verified JWT request-principal on all paths except `/dex/*` and
  `/oauth2/*`, so an unauthenticated external inference `POST` to a KServe `InferenceService` on the
  **shared** ingress gateway returns `403`. KServe in-cluster traffic (dedicated `kserve-ingress-gateway`)
  is unaffected. Serve external inference via the dedicated KServe gateway / wildcard-TLS opt-in, or use
  the legacy EnvoyFilter mode (`--legacy-authz` / `-f values-envoyfilter-authz.yaml`). See
  [Upgrade Notes](upgrade-notes.md) and
  [Ingress gateway authentication mode](access-and-tls.md#ingress-gateway-authentication-mode).
