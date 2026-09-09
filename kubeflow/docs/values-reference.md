# Values Reference

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Accessing & TLS](access-and-tls.md) · [Production Hardening](production-and-tenancy.md#production-hardening)

Full JSON schema: [`values.schema.json`](../values.schema.json)

---

## Global

| Key | Default | Description |
|-----|---------|-------------|
| `global.storageClass` | `""` | StorageClass for all PVCs; empty = cluster default |
| `global.imagePullPolicy` | `IfNotPresent` | Image pull policy for all components |
| `global.imagePullSecrets` | `[{name: application-collection}]` | Registry pull secrets — defined once, used everywhere |
| `global.imageRegistry` | `""` | Nuclear override — redirects **all** images (SUSE AI + Application Collection) to this registry |
| `global.suseRegistry` | `"registry.suse.com"` | Override for SUSE AI images only (`registry.suse.com/*`); use for staging or mirror registries |
| `global.suseApplicationCollectionRegistry` | `"dp.apps.rancher.io"` | Override for SUSE Application Collection images only (`dp.apps.rancher.io/*`); use for mirror registries |
| `global.labels` | `{}` | Common labels applied to all managed resources |
| `global.demoMode` | `false` | Set `true` to suppress credential validation; **never use in production** |
| `global.oauth2Proxy.enabled` | `true` | Master switch for the oauth2-proxy auth layer. Disabling it removes the gateway's ext_authz auth chain, so it is **incompatible with `global.kserveExternalHttps: true`** (the chart fails fast on that combination — see [External HTTPS for KServe inference](access-and-tls.md#external-https-for-kserve-inference-opt-in)) |
| `global.gateway.name` | `kubeflow/kubeflow-gateway` | Istio Gateway (`<namespace>/<name>`) for the dashboard and app VirtualServices. KServe inference does **not** use this — it uses `global.kserveGateway.name` |
| `global.kserveGateway.name` | `kubeflow/kserve-ingress-gateway` | Single source of truth for the **dedicated** KServe inference gateway (`<namespace>/<name>`). Threads through the Gateway CR that `kubeflow-istio-resources` renders, the `config-istio` `gateway.<ns>.<name>` key net-istio binds inference to, and kserve's `inferenceservice-config` `ingressGateway`. Keeps inference readiness independent of the dashboard's `:443` TLS |

## Credentials

| Key | Default | Description |
|-----|---------|-------------|
| `auth.oidc.clientSecret` | `pUBnBOY80Sn...` | **DEMO DEFAULT** — OIDC client secret shared between Dex and oauth2-proxy |
| `auth.oidc.cookieSecret` | (demo value, 32-byte base64) | **DEMO DEFAULT** — oauth2-proxy cookie encryption key |
| `auth.initialUser.email` | `user@example.com` | **DEMO DEFAULT** — Default Dex login email |
| `auth.initialUser.passwordHash` | bcrypt of `12341234` | **DEMO DEFAULT** — Change via `dex.config.staticPasswords` |
| `pipelines.seaweedfs.accessKey` | `kubeflow` | **DEMO DEFAULT** — SeaweedFS S3 access key |
| `pipelines.seaweedfs.secretKey` | `kubeflow123` | **DEMO DEFAULT** — SeaweedFS S3 secret key |

> Change all of these before any production or networked use — see
> [Production Hardening](production-and-tenancy.md#production-hardening).

## Component toggles

| Key | Default | Description |
|-----|---------|-------------|
| `centralDashboard.enabled` | `true` | Central Dashboard |
| `pipelines.enabled` | `true` | Kubeflow Pipelines + MariaDB + SeaweedFS |
| `notebooks.controller.enabled` | `true` | Notebook Controller |
| `notebooks.webApp.enabled` | `true` | Jupyter Web App |
| `katib.enabled` | `true` | Katib hyperparameter tuning |
| `kserve.enabled` | `true` | KServe model serving + Models Web App |
| `hub.enabled` | `true` | Kubeflow Hub — Model Registry + Model Catalog (requires `pipelines.enabled=true`) |
| `trainingOperator.enabled` | `true` | Training Operator V1 (TFJob, PyTorchJob, etc.) |
| `trainer.enabled` | `true` | Trainer V2 (TrainJob, TrainingRuntime, ClusterTrainingRuntime) |
| `profiles.enabled` | `true` | Profiles & KFAM (multi-tenancy) |
| `volumesWebApp.enabled` | `true` | Volumes Web App + PVCViewer Controller |
| `tensorboard.controller.enabled` | `true` | TensorBoard Controller |
| `tensorboard.webApp.enabled` | `true` | TensorBoard Web App |
| `knativeServing.enabled` | `true` | Knative Serving (required by KServe) |
| `knativeEventing.enabled` | `false` | Knative Eventing (optional, disabled by default) |
| `notebooks.enabled` | `true` | Master switch for all notebook components |
| `hub.catalog.enabled` | `false` | Model Catalog server with PostgreSQL backend (disabled by default) |
| `trainer.runtimes.enabled` | `true` | Deploy built-in ClusterTrainingRuntime manifests |
| `trainer.runtimes.torchtune.enabled` | `false` | TorchTune fine-tuning runtime (disabled by default) |
| `dex.enabled` | `true` | Dex OIDC identity provider |
| `oauth2Proxy.enabled` | `true` | oauth2-proxy authentication broker |

Model Registry provides model versioning and metadata storage, accessible from the Central Dashboard →
"Model Registry" sidebar link or directly at `/model-registry/`. It shares KFP's MariaDB.

```bash
# REST API smoke test
kubectl run mr-test --rm -i --restart=Never --image=busybox:1.36 -n kubeflow \
  --annotations='sidecar.istio.io/inject=false' -- \
  wget -qO- --timeout=10 \
  http://model-registry-service.kubeflow:8080/api/model_registry/v1alpha3/registered_models
# Expected: {"items":[],"nextPageToken":"","pageSize":0,"totalSize":0}
```

## Optional features

| Key | Default | Description |
|-----|---------|-------------|
| `networkPolicies.enabled` | `false` | Deny-all NetworkPolicies with explicit allow rules. Requires a CNI that enforces NetworkPolicy (Calico, Cilium, Canal). Disable with bare Flannel or any CNI that does not enforce NetworkPolicy. |
| `preflightChecks.enabled` | `false` | Pre-install hook Job that validates default StorageClass and cert-manager CRDs |
| `preflightChecks.image.repository` | `containers/kubectl` | Repository for the preflight kubectl image |
| `preflightChecks.image.tag` | `1.34.5` | Tag for the preflight kubectl image |
| `monitoring.enabled` | `false` | ServiceMonitors + PrometheusRules (requires Rancher Monitoring) |
| `pipelines.mariadb.backup.enabled` | `false` | Daily MariaDB backup CronJob to a dedicated PVC |
| `certManager.install` | `false` | Install bundled cert-manager v1.20.2 via this chart (not recommended — install separately) |

## Storage and persistence

| Key | Default | Description |
|-----|---------|-------------|
| `pipelines.mariadb.persistence.storageClassName` | `""` | StorageClass for KFP MariaDB PVC (20 Gi) |
| `pipelines.seaweedfs.storageSize` | `20Gi` | SeaweedFS data volume size |
| `pipelines.seaweedfs.storageClass` | `""` | StorageClass for SeaweedFS PVC |
| `katib.mariadb.persistence.storageSize` | `10Gi` | StorageClass for Katib MariaDB PVC |
| `pipelines.mariadb.backup.storageSize` | `10Gi` | Backup PVC size |
| `pipelines.mariadb.backup.schedule` | `"0 2 * * *"` | Backup cron schedule (daily at 02:00 UTC) |

## Networking / Ingress

| Key | Default | Description |
|-----|---------|-------------|
| `kubeflow-istio-resources.hostname` | `""` | Kubeflow FQDN; empty = wildcard (all hosts) |
| `kubeflow-istio-resources.externalDNSEnabled` | `false` | Annotate Istio Gateway for external-dns |
| `kubeflow-istio-resources.tls.source` | `""` | Dashboard TLS source (`""` \| `selfSigned` \| `letsEncrypt` \| `secret` \| `issuerRef`). |
| `kubeflow-istio-resources.tls.letsEncrypt.email` | `""` | ACME account email — optional (recommended) for letsEncrypt; Let's Encrypt issues without it, omitted from the ClusterIssuer when empty |
| `kubeflow-istio-resources.tls.letsEncrypt.server` | `prod` | `prod` \| `staging` |
| `kubeflow-istio-resources.tls.letsEncrypt.solver` | `cloudflare` | `cloudflare` (DNS-01) \| `http01` |
| `global.kserveExternalHttps` | `false` | Opt in to external HTTPS for KServe inference: adds a `*.<global.kserveDomain>` `:443` server (plus a `:80`→`:443` redirect) to the **dedicated** `kserve-ingress-gateway` (`global.kserveGateway.name`) using a dedicated `kserve-wildcard-tls` cert, and flattens the Knative route host to the single label `{name}-{namespace}.{domain}`. Requires a DNS-01 solver, `global.kserveDomain`, and `global.oauth2Proxy.enabled: true` (without gateway auth the wildcard would expose every tenant's inference endpoint unauthenticated — the chart fails fast). Default (`false`) keeps inference on plain `:80` on the dedicated gateway |
| `externaldns.enabled` | `false` | Deploy external-dns |
| `externaldns.cloudflare.apiToken` | `""` | Cloudflare API token; chart creates the Secret |
| `externaldns.domainFilters` | `[]` | Restrict DNS management to these domains |
| `externaldns.txtOwnerId` | `kubeflow` | Unique TXT record owner ID per cluster |

## Advanced

| Key | Default | Description |
|-----|---------|-------------|
| `global.kserveDomain` | `""` | Root domain for KServe InferenceService ingress — the **enforced single source of truth** and the recommended single place to set the inference domain. When set, it overrides and auto-wires the legacy `knativeServing.domain` / `kserve.ingressDomain`. Setting those subchart keys alone (without `global.kserveDomain`) **fails fast** — they feed the Knative/KServe configs but not the dedicated `kserve-ingress-gateway`'s hosts, so the chart rejects the divergence rather than silently stranding inference at `READY=Unknown`. Empty = the whole stack stays on `example.com` (the subchart-local defaults). With `global.kserveExternalHttps: true` it is also the wildcard cert/gateway base and is **required** |
| `dex.existingOidcClientSecret` | `""` | Name of a pre-existing Secret containing the OIDC client secret; overrides `auth.oidc.clientSecret` |
| `dex.resources` | `{requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}` | CPU/memory for the Dex container |
| `user-namespace.pipelines.seaweedfs.accessKey` | (wired from `pipelines.seaweedfs.accessKey`) | SeaweedFS S3 access key injected into every user namespace |
| `user-namespace.pipelines.seaweedfs.secretKey` | (wired from `pipelines.seaweedfs.secretKey`) | SeaweedFS S3 secret key injected into every user namespace |

## Registry Overrides

Images resolve their registry through a three-tier precedence: an optional master override, an
optional per-family override, then a per-component default.

| Value | Default | Scope |
|-------|---------|-------|
| `global.imageRegistry` | `""` | **All images** — SUSE AI and Application Collection. Overrides everything when set. |
| `global.suseRegistry` | `""` | Optional override for SUSE AI images only (`registry.suse.com/*` — kubeflow components, kfp, kserve, etc.) |
| `global.suseApplicationCollectionRegistry` | `""` | Optional override for Application Collection images only (`dp.apps.rancher.io/*` — mariadb, bci-busybox, kubectl, kube-rbac-proxy, workflow-controller, argoexec, metacontroller) |
| `<subchart>.<component>.image.registry` | `registry.suse.com` (SUSE) / `dp.apps.rancher.io` (App Collection) | The per-component default used when the globals above are empty. |

Precedence (highest to lowest) for each image type:
- **SUSE AI images:** `global.imageRegistry` → `global.suseRegistry` → component `image.registry`
- **App Collection images:** `global.imageRegistry` → `global.suseApplicationCollectionRegistry` → component `image.registry`

All three globals default to empty, so out of the box every image resolves from its own component
`registry:` field (`registry.suse.com` for SUSE AI, `dp.apps.rancher.io` for Application Collection).
Setting a family global overrides that default in bulk for its family; setting `global.imageRegistry`
overrides every image. An unset global simply falls through to the next tier — nothing is mandatory, so
a subchart also renders correctly standalone.

```yaml
# Mirror only Application Collection images
global:
  suseApplicationCollectionRegistry: mirror.corp.example.com

# Mirror both registries
global:
  suseRegistry: mirror.corp.example.com
  suseApplicationCollectionRegistry: mirror.corp.example.com

# Single nuclear override for all images
global:
  imageRegistry: mirror.corp.example.com
```
