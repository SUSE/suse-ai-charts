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
| `global.istio.cni` | `true` | Set to match how Istio is installed: `true` with istio-cni (profile namespaces enforce Pod Security `baseline`), `false` for classic `istio-init`. See [Pod Security Standards on profile namespaces](production-and-tenancy.md#9-pod-security-standards-on-profile-namespaces) |
| `global.gateway.name` | `kubeflow/kubeflow-gateway` | Istio Gateway (`<namespace>/<name>`) for the dashboard and app VirtualServices. KServe inference does **not** use this — it uses `global.kserveGateway.name` |
| `global.kserveGateway.name` | `kubeflow/kserve-ingress-gateway` | Single source of truth for the **dedicated** KServe inference gateway (`<namespace>/<name>`). Threads through the Gateway CR that `kubeflow-istio-resources` renders, the `config-istio` `gateway.<ns>.<name>` key net-istio binds inference to, and kserve's `inferenceservice-config` `ingressGateway`. Keeps inference readiness independent of the dashboard's `:443` TLS |

## Credentials

| Key | Default | Description |
|-----|---------|-------------|
| `auth.oidc.clientSecret` | `pUBnBOY80Sn...` | **DEMO DEFAULT** — OIDC client secret shared between Dex and oauth2-proxy |
| `auth.oidc.cookieSecret` | (demo value, 32-byte base64) | **DEMO DEFAULT** — oauth2-proxy cookie encryption key |
| `auth.oidc.existingSecret` | `false` | `true` = don't create the `kubeflow-oidc-client` Secret (keys `client-id`, `client-secret`, `cookie-secret`) that Dex and oauth2-proxy both read; provide it yourself (e.g. with External Secrets), with `client-id: kubeflow-oidc-authservice` |
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
| `hub.enabled` | `true` | Kubeflow Hub — Model Registry + Model Catalog |
| `global.modelRegistry.mode` | `perProfile` | `perProfile`: one registry per profile namespace (upstream). `shared` (deprecated): one registry in `kubeflow`, needs `pipelines.enabled=true`. See [Upgrade Notes](upgrade-notes.md#model-registry-per-profile) |
| `user-namespace.modelRegistry.enabled` | `null` | Follows `global.modelRegistry.mode`. Set `false` to skip the per-profile registries (required when `hub.enabled=false` and `userNamespace.enabled=true`) |
| `user-namespace.profile.enabled` | `true` | Create the example profile (`user-namespace.profile.name`). `false` keeps only `additionalUsers` and `modelRegistry.extraNamespaces` (e.g. production) |
| `user-namespace.profile.name` | `kubeflow-user-example-com` | Name of the example profile and its namespace |
| `user-namespace.modelRegistry.extraNamespaces` | `[]` | Existing profile namespaces created outside the chart that should also get a registry (registry resources only). Remove an entry before deleting its profile, or the next `helm upgrade` fails with "namespace not found" |
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
| `trainer.runtimes.istioSidecar` | `disabled` | Istio sidecar for the bundled runtimes' training pods. `disabled`: `sidecar.istio.io/inject: "false"`, pods leave the mesh (no mTLS or AuthorizationPolicy). `native`: `sidecar.istio.io/nativeSidecar: "true"`, pods complete inside the mesh; use on full-platform installs. `default`: no annotation. |
| `trainer.runtimes.podAnnotations` | `{}` | Extra annotations for the bundled runtimes' training pod templates; they win over `istioSidecar` on conflicts |
| `dex.enabled` | `true` | Dex OIDC identity provider |
| `oauth2Proxy.enabled` | `true` | oauth2-proxy authentication broker |
| `istioResources.enabled` | `true` | kubeflow-istio-resources: Gateways, Dex/oauth2-proxy VirtualServices, gateway AuthorizationPolicies/EnvoyFilters (requires Istio CRDs). When `false`, every component that needs Istio must be disabled; the install fails and its error lists the ones still enabled. |
| `admissionWebhook.enabled` | `true` | PodDefaults admission webhook (requires cert-manager CRDs). When `false`, notebooks run without PodDefaults |
| `userNamespace.enabled` | `true` | Example `kubeflow-user-example-com` Profile, `user-namespace.additionalUsers` and the per-profile Model Registry (requires `profiles.enabled=true`) |
| `kubeflowRoles.enabled` | `true` | Aggregated `kubeflow-{admin,edit,view}` and `kubeflow-kubernetes-*` ClusterRoles |

To install only Trainer V2 + JobSet, use the `trainer-only-overrides.yaml` preset in the chart root,
which sets all of the above (and every other component except `trainer`) to `false`. See
[Trainer-only Install](use-cases/trainer-only-install.md) for the full instructions.

Model Registry provides model versioning and metadata storage, accessible from the Central Dashboard →
"Model Registry" sidebar link or directly at `/model-registry/`. Each profile namespace has its own
registry (server + Postgres): the example profile, every `user-namespace.additionalUsers[]` entry, and
any namespace in `user-namespace.modelRegistry.extraNamespaces`. Select the namespace in the UI.
Per-profile settings (embedded or external Postgres, Istio route, authorization policy) are documented
in `charts/user-namespace/values.yaml` under `modelRegistry`.

- **Registry data lives and dies with the profile namespace.** The embedded Postgres PVC
  (`metadata-postgres`) and its Secret carry `helm.sh/resource-policy: keep`, so Helm itself never
  deletes them. But a namespace the chart created (the example profile, `additionalUsers[]`) is
  deleted on `helm uninstall` or when you remove the user from `additionalUsers`, and the PVC goes
  with it — as upstream, where deleting a Profile deletes its namespace. Only namespaces listed in
  `extraNamespaces` (not created by the chart) keep the data. Back up the registry first if you
  need it.
- **Installs rendered with `helm template`** (no cluster access, so no Helm `lookup`) would
  generate a new embedded-DB password on every render. Set
  `user-namespace.modelRegistry.db.embedded.existingSecret` and create that Secret (keys
  `POSTGRES_USER` / `POSTGRES_PASSWORD`) in every registry namespace.
- **Server image is set twice.** The per-profile servers use `user-namespace.modelRegistry.server.image`;
  the catalog (and the shared server) use `hub.server.image`. Override both together.

```bash
# REST API smoke test for one profile (port-forward bypasses the mesh)
kubectl port-forward -n kubeflow-user-example-com svc/model-registry-service 8080:8080 & PF=$!; sleep 2
curl -s http://localhost:8080/api/model_registry/v1alpha3/registered_models
# Expected (empty registry): {"items":[],"nextPageToken":"","pageSize":0,"size":0}
kill $PF
```

## Optional features

| Key | Default | Description |
|-----|---------|-------------|
| `networkPolicies.enabled` | `false` | Deny-all NetworkPolicies with explicit allow rules. Requires a CNI that enforces NetworkPolicy (Calico, Cilium, Canal). Disable with bare Flannel or any CNI that does not enforce NetworkPolicy. |
| `network-policies.knativeServingPolicies.enabled` | `true` | Render the NetworkPolicies for the `knative-serving` namespace. Set `false` when `networkPolicies.enabled=true` but Knative Serving is not installed (e.g. trainer-only); the chart refuses that combination otherwise. |
| `preflightChecks.enabled` | `false` | Pre-install hook Job that validates the default StorageClass and, when a cert-manager consumer is enabled (admission webhook, Katib, KServe, pipelines, volumes web app, or a cert-manager gateway TLS source), the cert-manager CRDs, and (with profile namespaces) that Istio CNI matches `global.istio.cni` |
| `preflightChecks.image.repository` | `containers/kubectl` | Repository for the preflight kubectl image |
| `preflightChecks.image.tag` | `1.36.2` | Tag for the preflight kubectl image |
| `preflightChecks.resources` | requests `50m`/`64Mi`, limits `500m`/`256Mi` | Resources for the preflight and webhook-secret-migration Jobs (the Trainer runtimes applier uses `trainer.runtimes.applier.resources`), so they run in namespaces whose ResourceQuota requires them |
| `monitoring.enabled` | `false` | ServiceMonitors + PrometheusRules (requires Rancher Monitoring) |
| `pipelines.mariadb.backup.enabled` | `false` | Daily MariaDB backup CronJob to a dedicated PVC |
| `certManager.install` | `false` | Install bundled cert-manager v1.20.2 via this chart (not recommended — install separately) |
| `pipelines.artifacts.proxyEnabled` | `false` | Per-profile KFP artifact proxy (`ml-pipeline-ui-artifact`). Off by default, as upstream: the KFP UI reads artifacts directly. A change reaches existing profiles at metacontroller's hourly resync; to apply it now, `kubectl rollout restart statefulset/metacontroller -n kubeflow` |
| `pipelines.artifacts.retentionDays` | `-1` | Delete pipeline artifacts under `private-artifacts/` older than N days (SeaweedFS lifecycle rule). `-1` keeps them. The rule is bucket-wide and is written only when the KFP profile controller creates a profile's access key (a new profile, or after deleting a profile's `mlpipeline-minio-artifact` Secret), so a change takes effect at the next such event, not on `helm upgrade`. |
| `hub.kserve.storageContainer.enabled` | `false` | Model Registry storage initializer: KServe loads models by `model-registry://` URI. Extra steps in per-profile mode — see [Optional Features](optional-features.md#model-registry-kserve-integration) |
| `hub.controller.enabled` | `false` | Model Registry InferenceService controller: records deployments in the registry. Needs `hub.controller.env.registriesNamespace` in per-profile mode — see [Optional Features](optional-features.md#model-registry-kserve-integration) |

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
| `dex.existingOidcClientSecret` | `""` | Not read by this chart. To supply the OIDC credentials yourself, set `auth.oidc.existingSecret: true` |
| `dex.resources` | `{requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}` | CPU/memory for the Dex container |

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
