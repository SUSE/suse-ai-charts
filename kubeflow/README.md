# Kubeflow Helm Chart

End-to-end Machine Learning platform on Kubernetes, packaged as a single Helm umbrella chart.
Targets **Rancher / RKE2** clusters using images from the SUSE AI Library.

> **Note:** This chart requires an active [SUSE AI](https://www.suse.com/products/ai/) subscription
> to pull images from `dp.apps.rancher.io`. The chart source code itself is Apache 2.0.

---

## Table of Contents

- [Components](#components)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Mode 1 — Automated via `runMe.sh`](#mode-1--automated-via-runmesh)
  - [Mode 2 — Manual Helm install (OCI, recommended for production)](#mode-2--manual-helm-install-oci-recommended-for-production)
- [Accessing Kubeflow](#accessing-kubeflow)
- [Configuration Scenarios](#configuration-scenarios)
  - [Non-prod: NodePort access (zero config)](#non-prod-nodeport-access-zero-config)
  - [Non-prod: Named hostname over HTTP](#non-prod-named-hostname-over-http)
  - [Non-prod: Self-signed TLS](#non-prod-self-signed-tls)
  - [Production: Let's Encrypt TLS + external-dns](#production-lets-encrypt-tls--external-dns)
  - [Production: Bring-your-own certificate](#production-bring-your-own-certificate)
- [Values Reference](#values-reference)
- [Production Hardening](#production-hardening)
- [Multi-tenancy](#multi-tenancy)
- [Upgrade Notes](#upgrade-notes)
  - [Migration — Model Registry consolidated into Kubeflow Hub](#migration--model-registry-consolidated-into-kubeflow-hub)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Components

| Component | Chart source | Namespace | Purpose |
|-----------|-------------|-----------|---------|
| Dex | SUSE Application Collection `dex-idp` 0.23.0 (0.24.0 incompatible — see Known Limitations) | kubeflow | OIDC identity provider |
| oauth2-proxy | SUSE Application Collection `oauth2-proxy` 10.1.4 | kubeflow | OIDC login broker / session cookie |
| Central Dashboard | local | kubeflow | Web UI shell |
| Kubeflow Pipelines | local | kubeflow | ML workflow engine (KFP v2) |
| Notebook Controller | local | kubeflow | Jupyter Notebook CRD controller |
| Jupyter Web App | local | kubeflow | Notebook creation UI |
| Katib | local | kubeflow | Hyperparameter tuning |
| KServe | local | kubeflow | Model serving |
| Training Operator V1 | local | kubeflow | TFJob / PyTorchJob / etc. (`kubeflow.org` API) |
| Trainer V2 | local | kubeflow | TrainJob / TrainingRuntime / ClusterTrainingRuntime (`trainer.kubeflow.org` API) |
| Profiles & KFAM | local | kubeflow | Multi-tenancy / namespace management |
| Volumes Web App | local | kubeflow | PVC management UI (co-enabled with PVCViewer Controller via `volumesWebApp.enabled`) |
| PVCViewer Controller | local | kubeflow | File browser for PVCs (co-enabled with Volumes Web App) |
| Tensorboard Controller | local | kubeflow | TensorBoard CRD controller |
| Tensorboards Web App | local | kubeflow | TensorBoard UI |
| Models Web App | local | kubeflow | Model serving UI (co-enabled with KServe via `kserve.enabled`) |
| Model Registry | local | kubeflow | Model versioning and metadata |
| Admission Webhook | local | kubeflow | PodDefault mutating webhook (always installed — no condition) |
| Knative Serving | local | knative-serving | Serverless layer required by KServe |
| Knative Eventing | local | knative-eventing | Optional event-driven pipeline triggers (disabled by default) |
| MariaDB (KFP) | SUSE Application Collection `mariadb` 0.1.7 | kubeflow | Pipeline + MLMD metadata DB |
| MariaDB (Katib) | inline | kubeflow | Katib experiment DB |
| SeaweedFS | inline | kubeflow | Pipeline artifact store (S3-compatible, Docker Hub image — requires internet access) |
| external-dns | SUSE Application Collection `external-dns` 1.20.0 | kubeflow | Automatic DNS record management for Cloudflare (disabled by default) |
| NetworkPolicies | local | kubeflow / knative-serving | Deny-all + explicit allow NetworkPolicies (disabled by default) |
| Monitoring | local | kubeflow | ServiceMonitors + PrometheusRules for Rancher Monitoring (disabled by default) |

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Kubernetes | >= 1.30 | Tested on RKE2 / K3s |
| Helm | >= 4.0.1 | Required for OCI chart support |
| cert-manager | 1.20.2 | Installed by `runMe.sh`; or pre-install manually |
| Istio | mesh ≥ 1.9 (chart 1.3.0) | `1.3.0` is the SUSE AppCo **chart** version installed by `runMe.sh` (or pre-install manually); it ships a mesh well past the floor. The **mesh** floor is Istio ≥ 1.9 / Envoy ≥ 1.17 — the auth EnvoyFilter uses ext_authz `filter_enabled_metadata` `invert`, added in Envoy 1.17.0 (Istio 1.9). On an older proxy istiod NACKs the filter and auth can **fail open**. Any currently-supported Istio (≥ 1.16) satisfies this. |
| Load Balancer (i.e. metallb) | - | It is required when used in conjunction with external-dns and cert-manager. Tested with MetalLB v0.15.3 |
| Default StorageClass | — | Local Path Provisioner (dev) or Longhorn (prod) |
| SUSE Application Collection credentials | — | Username + token for `dp.apps.rancher.io` (application-collection secret) |
| SUSE Registry credentials | — | Username + token for `registry.suse.com` (suse-ai-registry secret) |

**Storage class:** All PVCs use the cluster default StorageClass unless `global.storageClass` is set.
For single-node clusters the Local Path Provisioner is sufficient for development.
For production, Longhorn is recommended.

> **Note:** make sure default StorageClass is set for the cluster before using
> it. To check for the default StorageClass, run `kubectl get storageclass` to
> ensure there's a StorageClass `(default)` designation next to it's name.
> Otherwise, you must designate a StorageClass as the default StorageClass.
> For example, `kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.

**Cloudflare API token:** Only required if you want automatic DNS record management via
`external-dns`. When using Let's Encrypt as the issuer for Gateway TLS certificate, `external-dns` is required for DNS-01 challenges.

---

## Installation

There are two installation modes:

| Mode | When to use |
|------|------------|
| `runMe.sh` | Fastest path — automates all prerequisite steps. Good for dev, demos, and CI. |
| Manual Helm (OCI) | **Recommended for production.** Install directly from the OCI registry — no source checkout or `helm dependency update` required. |

Both modes end up running the same `helm upgrade --install` command; `runMe.sh` just automates the
steps before it.

---

### Mode 1 — Automated via `runMe.sh`

`runMe.sh` performs prerequisite steps and then installs the Kubeflow chart:

Prerequisite: A RKE2 cluster with a default storageClass configured.

1. Performs Helm registry logins for `dp.apps.rancher.io` and `registry.suse.com`
2. Creates namespaces: `cert-manager`, `istio-system`, `kubeflow`, `knative-serving`
3. Creates `application-collection` and `suse-ai-registry` image pull secrets in `istio-system`, `kubeflow`, `knative-serving`, and `cert-manager`. User namespaces (`kubeflow-user-example-com`, profile namespaces) receive these secrets automatically via the External Secrets Operator (ESO), which is installed as part of the chart.
4. Labels the `kubeflow` and `knative-serving` namespaces for Helm ownership
5. Installs cert-manager from `oci://dp.apps.rancher.io/charts/cert-manager`
6. Installs Istio from `oci://dp.apps.rancher.io/charts/istio` with the gateway enabled
7. Installs External Secrets Operator and waits for CRDs to be established
8. Packages sub-charts via `helm dependency update`
9. Installs the Kubeflow umbrella chart

#### Basic usage (NodePort / port-forward access)

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token>
```

After install the script prints the access URL automatically (NodePort or port-forward instructions
depending on the setup).

Default credentials (change before production use):
```
Email:    user@example.com
Password: 12341234
```

#### Full argument reference

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> \
  [--kubeconfig <path-to-kubeconfig>] \
  [--cloudflare-api-key <CF-API-KEY>] \
  [-f <path-to-values-override.yaml>]
```

| Argument | Env var alternative | Description |
|----------|---------------------|-------------|
| `<appco-registry-username>` | `APPCO_REGISTRY_USER` | SUSE Application Collection username (for `dp.apps.rancher.io`) |
| `<appco-registry-token>` | `APPCO_REGISTRY_TOKEN` | SUSE Application Collection token / password (for `dp.apps.rancher.io`) |
| `<suse-ai-registry-username>` | `SUSE_REGISTRY_USER` | SUSE Registry username (default: `regcode`) |
| `<suse-ai-registry-token>` | `SUSE_REGISTRY_TOKEN` | SUSE Registry token / password (for `registry.suse.com`) SCC_REG_CODE for AI|
| `--kubeconfig <path>` | `KUBECONFIG` | Path to kubeconfig (defaults to `~/.kube/config`, or KUBECONFIG environment variable if set) |
| `--cloudflare-api-key <key>` | `CLOUDFLARE_API_KEY` | Creates `cloudflare-api-key` Secret in `kubeflow` and `cert-manager` namespaces |
| `-f <file>` / `--values-file <file>` | — | Path to a values override YAML file passed to `helm upgrade` |
| `--disable-cert-manager` | — | Do not upgrade/install cert-manager, use an existing one instead |
| `--suse-registry=<mirror>` | `SUSE_REGISTRY` | SUSE AI registry mirror (default: `registry.suse.com`); redirects all `registry.suse.com/*` image pulls and the registry login |
| `--suse-app-collection=<mirror>` | `SUSE_APP_COLLECTION` | Application Collection mirror (default: `dp.apps.rancher.io`); redirects all `dp.apps.rancher.io/*` image pulls, the registry login, and the cert-manager / Istio / ESO OCI chart URLs |


#### Mirror / air-gapped registry usage

To redirect images through an internal mirror registry, pass both flags:

```bash
./runMe.sh <appco-username> <appco-token> regcode <suse-ai-token> \
  --suse-registry=<mirror> \
  --suse-app-collection=<mirror>
```

`--suse-app-collection` redirects: the `dp.apps.rancher.io` registry login, the `application-collection` pull secret, the cert-manager / Istio / ESO OCI chart installs, and sets `global.suseApplicationCollectionRegistry` on the Kubeflow helm install so all pod images resolve from the mirror.
`--suse-registry` redirects: the `registry.suse.com` registry login, the `suse-ai-registry` pull secret, and sets `global.suseRegistry` on the Kubeflow helm install.

#### Using a values override file with `runMe.sh`

Create a `my-values.yaml` file with your overrides (see [Configuration Scenarios](#configuration-scenarios) below), then:

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> -f my-values.yaml
```

Or Use the `demo-overrides.yaml` example provided in the [repo](https://github.com/SUSE/suse-ai-charts/tree/main/kubeflow).
**Never use `demo-overrides.yaml` in production**

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> -f demo-overrides.yaml
```

---

### Mode 2 — Manual Helm install (OCI, recommended for production)

Use this mode for production deployments. The chart is published to the SUSE Registry OCI endpoint —
no source checkout or `helm dependency update` is required.

Prerequisite: A RKE2 cluster with a default storageClass configured.

> **Note:** using the latest versions of the helm charts is recommended.

#### Step 1 — Helm registry login

```bash
# Login to SUSE Application Collection registry
helm registry login dp.apps.rancher.io \
  --username=<appco-registry-username> \
  --password=<appco-registry-token>

# Login to SUSE Registry
helm registry login registry.suse.com \
  --username=regcode \
  --password=<suse-ai-registry-token>
```

#### Step 2 — Create namespaces

```bash
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

> **Note:** `kubeflow-user-example-com` and all other user namespaces are created by the Kubeflow chart and receive registry pull secrets automatically via ESO — no manual creation needed.

#### Step 3 — Create image pull secrets

Create secrets only in the static system namespaces. ESO propagates them to user namespaces automatically.

```bash
# Create application-collection pull secret (SUSE Application Collection — dp.apps.rancher.io)
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create secret docker-registry application-collection \
    --docker-server=dp.apps.rancher.io \
    --docker-username=<appco-registry-username> \
    --docker-password=<appco-registry-token> \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# Create suse-ai-registry pull secret (SUSE Registry — registry.suse.com)
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create secret docker-registry suse-ai-registry \
    --docker-server=registry.suse.com \
    --docker-username=regcode \
    --docker-password=<suse-ai-registry-token> \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

> ESO (installed as part of the Kubeflow chart) automatically copies `suse-ai-registry` and `application-collection` from the `kubeflow` namespace into every user namespace labelled `app.kubernetes.io/part-of: kubeflow-profile`, including namespaces created dynamically by the profiles controller at runtime.

#### Step 4 — Label namespaces for Helm

```bash
for ns in kubeflow kubeflow-user-example-com knative-serving; do
  kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$ns" \
    meta.helm.sh/release-name=kubeflow \
    meta.helm.sh/release-namespace=kubeflow \
    --overwrite
done
```

#### Step 5 — Install cert-manager

```bash
helm upgrade --install cert-manager oci://dp.apps.rancher.io/charts/cert-manager \
  --version 1.20.2 \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m
```

#### Step 6 — Install Istio

```bash
helm upgrade --install istio oci://dp.apps.rancher.io/charts/istio \
  --version 1.3.0 \
  --namespace istio-system \
  --set global.imagePullSecrets[0].name=application-collection \
  --set gateway.enabled=true \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 5m
```

#### Step 7 — Install External Secrets Operator

ESO must be installed before the Kubeflow chart so its CRDs are present when Helm applies the `ClusterSecretStore` and `ClusterExternalSecret` resources.

```bash
helm upgrade --install external-secrets-operator oci://dp.apps.rancher.io/charts/external-secrets-operator \
  --version 2.3.0 \
  --namespace kubeflow \
  --set installCRDs=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m
```

#### Step 8 — Install Kubeflow

Install directly from the OCI registry (no source checkout required):

```bash
helm upgrade --install kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m
```

To apply a values override file, for example the `demo-overrides.yaml` provided in the [repo](https://github.com/SUSE/suse-ai-charts/tree/main/kubeflow). **Never use `demo-overrides.yaml` in production**:

```bash
helm upgrade --install kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m \
  -f demo-overrides.yaml
```

> `--force-conflicts` is required because cert-manager-cainjector, istiod (pilot-discovery), and
> the clusterrole-aggregation-controller modify fields (caBundle, webhook failurePolicy, aggregated
> RBAC rules) that Helm tracks. This flag lets Helm reclaim ownership of those fields on each upgrade.

#### Using a mirror / air-gapped registry (Mode 2)

Substitute the mirror hostname in each `oci://` URL, update the `--docker-server` in the pull
secrets, and pass the `global.suseApplicationCollectionRegistry` / `global.suseRegistry` values to the
Kubeflow chart:

```bash
MIRROR=mirror.corp.example.com

helm registry login "${MIRROR}" --username=<username> --password=<token>

# cert-manager, Istio, ESO from mirror
helm upgrade --install cert-manager oci://${MIRROR}/charts/cert-manager ...
helm upgrade --install istio oci://${MIRROR}/charts/istio ...
helm upgrade --install external-secrets-operator oci://${MIRROR}/charts/external-secrets-operator ...

# Pull secrets pointing at mirror
kubectl create secret docker-registry application-collection \
  --docker-server="${MIRROR}" ...
kubectl create secret docker-registry suse-ai-registry \
  --docker-server="${MIRROR}" ...

# Kubeflow chart + images from mirror
helm upgrade --install kubeflow oci://${MIRROR}/ai/charts/kubeflow \
  --version 0.3.2 -n kubeflow \
  --set global.suseApplicationCollectionRegistry="${MIRROR}" \
  --set global.suseRegistry="${MIRROR}" \
  --force-conflicts --server-side=true --wait --timeout 15m
```

> **Installing from source (development / contributing only)**
>
> If you are developing the chart from a local checkout, run `helm dependency update` first and
> then install from the local path:
>
> ```bash
> helm dependency update charts/kubeflow
> helm upgrade --install kubeflow charts/kubeflow \
>   -n kubeflow \
>   --force-conflicts \
>   --server-side=true \
>   --wait --timeout 15m \
>   -f demo-overrides.yaml
> ```

---

## Accessing Kubeflow

### Option A — Port-forward (local dev)

If NodePorts are not directly reachable use port-forward instead:

```bash
# Run in a separate terminal and keep it open
kubectl port-forward svc/istio -n istio-system 8080:80
```

Open: http://localhost:8080

### Option B — NodePort (standard Linux cluster)

The Istio gateway Service is type `LoadBalancer` and always gets NodePorts assigned, even without a
load-balancer controller:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
HTTP_PORT=$(kubectl get svc istio -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
echo "http://${NODE_IP}:${HTTP_PORT}"
```

### Option C — LoadBalancer external IP

If your cluster has MetalLB or a cloud load-balancer controller, the Service receives an external IP:

```bash
kubectl get svc istio -n istio-system   # wait for EXTERNAL-IP
# Browse to http://<EXTERNAL-IP>
```

No Helm values change is needed for options A, B, or C.

### Option D — Named hostname (HTTP)

Set a hostname to restrict the gateway to a specific FQDN. TLS is not required.

See [Non-prod: Named hostname over HTTP](#non-prod-named-hostname-over-http) for values.

### Option E — Named hostname with TLS (HTTPS)

See [Non-prod: Self-signed TLS](#non-prod-self-signed-tls) or
[Production: Let's Encrypt TLS + external-dns](#production-lets-encrypt-tls--external-dns).

> **Note:** When using Let's Encrypt as the issuer for Gateway TLS certificate, `external-dns` is required for DNS-01 challenges. Furthermore, a load balancer (i.e. MetallLB) must be used in conjunction with `external-dns`. This is to ensure `external-dns` can properly obtain the external IP from the load balancer to create the DNS record.

---

## Configuration Scenarios

### Non-prod: NodePort access (zero config)

No values override file is needed. Install with the default values and access via NodePort or
port-forward as described above.

Default credentials:
```
Email:    user@example.com
Password: 12341234
```

---

### Non-prod: Named hostname over HTTP

Use this when you want a stable URL for a shared dev cluster. You can point `/etc/hosts` at the
cluster IP or use external-dns to automate DNS.

```yaml
# my-values.yaml
global:
  # Inference domain — set it here (the single place), not on the subcharts. It is
  # independent of the dashboard hostname below: here the dashboard is at
  # kubeflow.dev.example.com while InferenceService hosts become
  # <name>-<namespace>.model.dev.example.com. Omit this and it silently falls back
  # to example.com.
  kserveDomain: "model.dev.example.com"
kubeflow-istio-resources:
  hostname: "kubeflow.dev.example.com"
  externalDNSEnabled: false
```

After install, get the cluster IP and add a local DNS entry:

```bash
# Get the external (or node) IP
kubectl get svc istio -n istio-system

# /etc/hosts entry (on your local machine or in the cluster)
192.168.1.100  kubeflow.dev.example.com
```

Browse to: http://kubeflow.dev.example.com

---

### Non-prod: Self-signed TLS

Suitable for shared dev clusters where you can distribute the self-signed CA manually. Requires
cert-manager (installed by `runMe.sh` or step 4 above).

```yaml
# my-values.yaml
global:
  # Single place for the inference domain — keeps InferenceService URLs on
  # models.example.com instead of the example.com fallback. This sets the
  # domain only; the dashboard gets TLS below but inference URLs stay HTTP. To
  # also serve inference over external HTTPS, add kserveExternalHttps — see
  # "External HTTPS for KServe inference" (self-signed issues the wildcard
  # directly, so no DNS-01 solver is needed on that path).
  kserveDomain: "models.example.com"
kubeflow-istio-resources:
  hostname: "kubeflow.dev.example.com"
  externalDNSEnabled: false
  tls:
    source: "selfSigned"
    credentialName: kubeflow-gateway-tls
    httpsRedirect: true
```

The chart creates a self-signed `ClusterIssuer` and requests a `Certificate` automatically.
No `kubectl` steps required beyond the Helm install.

Add the self-signed CA to your browser trust store to avoid certificate warnings.

---

### Production: Let's Encrypt TLS + external-dns

Recommended for internet-facing production deployments. Uses DNS-01 challenge via Cloudflare so
HTTP-01 port requirements are avoided. Requires a Cloudflare API token with DNS edit access.

```yaml
# prod-values.yaml

# ── Access ──────────────────────────────────────────────────────────────────────
global:
  # Single place for the inference domain — keeps InferenceService URLs on
  # models.example.com instead of the example.com fallback. This sets the
  # domain only; to serve inference over external HTTPS add kserveExternalHttps
  # — see "External HTTPS for KServe inference" below (needs the DNS-01 solver
  # this scenario already configures).
  kserveDomain: "models.example.com"
kubeflow-istio-resources:
  hostname: "kubeflow.example.com"
  externalDNSEnabled: true
  tls:
    source: "letsEncrypt"
    credentialName: kubeflow-gateway-tls
    httpsRedirect: true
    letsEncrypt:
      email: "admin@example.com"   # your ACME account email
      server: prod                 # prod | staging (use staging first to test)
      solver: cloudflare           # dns01 via Cloudflare
    # Configuring cloudflare since solver is cloudflare
    cloudflare:
      email: "admin@example.com"
      apiTokenSecretRef:
        name: cloudflare-api-key
        key: apiKey

# external-dns — watches the Istio Gateway and creates/updates DNS records
externaldns:
  enabled: true
  provider:
    name: cloudflare
  cloudflare:
    apiToken: "<YOUR-CLOUDFLARE-API-TOKEN>"  # chart creates the Secret automatically
  domainFilters:
    - "example.com"
  txtOwnerId: "kubeflow"   # unique per cluster — prevents conflicts
  sources:
    - istio-gateway
  env:
    - name: CF_API_TOKEN
      valueFrom:
        secretKeyRef:
          name: cloudflare-api-key
          key: apiKey

# ── Credentials — change ALL of these ───────────────────────────────────────────
auth:
  oidc:
    clientSecret: "<STRONG-RANDOM-32-CHAR-SECRET>"
  initialUser:
    email: "admin@example.com"

dex:
  config:
    staticClients:
      - id: kubeflow-oidc-authservice
        redirectURIs:
          - /oauth2/callback
        name: kubeflow-oidc-authservice
        secret: "<STRONG-RANDOM-32-CHAR-SECRET>"   # must match auth.oidc.clientSecret
    staticPasswords:
      - email: "admin@example.com"
        # Generate: htpasswd -nbBC 12 "" 'YourPassword' | tr -d ':\n' | sed 's/$2y/$2a/'
        hash: "<BCRYPT-HASH-OF-YOUR-PASSWORD>"
        username: admin
        userID: "1"
    enablePasswordDB: true

# ── Storage credentials — change these ──────────────────────────────────────────
pipelines:
  seaweedfs:
    accessKey: "<STRONG-ACCESS-KEY>"
    secretKey: "<STRONG-SECRET-KEY>"
  mariadb:
    backup:
      enabled: true        # recommended for production
      schedule: "0 2 * * *"
      storageSize: 20Gi

# ── User namespace must use the same SeaweedFS credentials ───────────────────────
user-namespace:
  pipelines:
    seaweedfs:
      accessKey: "<STRONG-ACCESS-KEY>"    # same as pipelines.seaweedfs.accessKey
      secretKey: "<STRONG-SECRET-KEY>"    # same as pipelines.seaweedfs.secretKey

# ── Optional hardening ───────────────────────────────────────────────────────────
networkPolicies:
  enabled: false   # set to true when using CNI that enforces NetworkPolicy (Calico, Cilium, Canal)

monitoring:
  enabled: false  # set true after Rancher Monitoring (kube-prometheus-stack) is installed
```

Install:

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> \
  --cloudflare-api-key "<YOUR-CLOUDFLARE-API-TOKEN>" \
  -f prod-values.yaml
```

Or manually:

```bash
helm upgrade --install kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow \
  --force-conflicts \
  --wait --timeout 15m \
  -f prod-values.yaml
```

> **Using `staging` first is strongly recommended.** Let's Encrypt rate-limits production
> certificate issuance. Test with `server: staging` until the certificate is issued, then switch
> to `server: prod` and run `helm upgrade` again.

#### External HTTPS for KServe inference (optional)

KServe inference always routes through its own **dedicated** `kserve-ingress-gateway`
(`global.kserveGateway.name`, default `kubeflow/kserve-ingress-gateway`) — separate from the
dashboard's `kubeflow-gateway`. net-istio binds the Knative ingress VirtualServices to this
gateway, so its readiness prober only ever probes that gateway's ports; inference readiness is
therefore **independent of the dashboard's `:443` TLS**

By default the dedicated gateway serves inference on plain `:80`, and each InferenceService's
`status.url` keeps KServe's default `{name}-{namespace}.{domain}` host over HTTP (behaves exactly
as upstream). Serving inference over external HTTPS is an **opt-in**: set the two globals below and
point the gateway at a TLS issuer, and the chart adds a `*.<kserveDomain>:443` server (plus a
`:80`→`:443` redirect) to the dedicated gateway:

```yaml
# --- KServe external HTTPS opt-in ---

global:
  kserveDomain: "model.example.com"  # base domain for inference hosts + wildcard cert. It does
                                     # NOT have to match the dashboard hostname below — here the
                                     # dashboard lives at kubeflow.example.com while inference
                                     # serves under *.model.example.com.
                                     # Prefer a scoped subdomain (e.g. model.example.com)
                                     # over an org-wide domain (example.com): the wildcard is
                                     # "*.<kserveDomain>", so a bare domain widens the cert's
                                     # blast radius to your whole zone.
  kserveExternalHttps: true          # the only switch — everything else is auto-derived

kubeflow-istio-resources:
  hostname: "kubeflow.example.com"   # required: the dashboard host. With kserveExternalHttps the
                                     # chart fails fast if this is unset (see validations.yaml). The
                                     # LE path gives the dashboard its own cert (kubeflow-gateway-tls),
                                     # separate from the *.model.example.com inference wildcard. Using
                                     # a distinct domain here keeps the dashboard entirely outside the
                                     # inference wildcard.
  tls:
    source: "letsEncrypt"            # or selfSigned / secret / issuerRef
    letsEncrypt:
      email: "admin@example.com"
      solver: cloudflare             # DNS-01 required for wildcard certs
    cloudflare:                      # required for the cloudflare DNS-01 solver
      email: "admin@example.com"
      apiTokenSecretRef:
        name: cloudflare-api-token-secret   # must live in cert-manager's namespace
        key: api-token
```

You **no longer** set `kserve.urlScheme`, `kserve.ingressDomain`, `knativeServing.domain`, or
`knativeServing.domainTemplate` by hand — the chart derives all of them from the two globals:
`urlScheme` becomes `https`, the domains follow `global.kserveDomain`, and the Knative route host
is flattened to the single label `{name}-{namespace}.{domain}` so the
wildcard cert covers it. This makes the **dedicated `kserve-ingress-gateway`** serve
`*.<kserveDomain>` on `:443` using a **separate dedicated certificate** (`kserve-wildcard-tls`) —
on a **separate gateway** from the dashboard, so a DNS-01 failure on the wildcard never takes
down the dashboard's TLS. The chart **fails fast at render time** if the opt-in is incomplete
(missing `hostname`, invalid `tls.source`, HTTP-01 solver, an unpopulated cloudflare block, or
the bundled oauth2-proxy disabled — see below). Notes:

- **Requires the bundled oauth2-proxy (`global.oauth2Proxy.enabled: true`, the default).** The
  gateway's authentication (the `authn-filter` ext_authz chain) is only rendered when oauth2-proxy
  is enabled. If you disable it — e.g. to front Kubeflow with your own IdP — the dedicated gateway
  performs **no auth**, so the `*.<kserveDomain>:443` wildcard server would publish **every
  tenant's inference endpoint** unauthenticated.
  The chart therefore **refuses to render** the wildcard server and **fails fast** when
  `global.kserveExternalHttps: true` is combined with `global.oauth2Proxy.enabled: false`. If you run
  your own gateway auth, keep this opt-in off and expose inference through your own authenticated
  ingress instead.
- **Requires a DNS-01 solver** (`solver: cloudflare`). Let's Encrypt HTTP-01 cannot issue
  wildcard certificates. The `apiTokenSecretRef` Secret must exist in **cert-manager's own
  namespace** (a ClusterIssuer resolves solver secrets there, not in the release namespace).
  Scope the Cloudflare API token to **Zone > DNS > Edit** (plus **Zone > Zone > Read** for zone
  discovery) on the specific zone(s) covering `kserveDomain` / the dashboard host — not "All
  zones" — so a leaked token can only touch those zones.
- **The Knative route host is flattened to `{name}-{namespace}.{domain}`** so a single `*.{domain}`
  wildcard covers them (Let's Encrypt cannot issue a `*.*.{domain}` two-level wildcard). Knative
  and KServe render this host with Go's stdlib `text/template` — **not** Helm/Sprig — so the
  namespace **cannot** be hashed in the template.
- **This opt-in is single-tenant-first — do NOT enable it on an untrusted multi-tenant cluster.**
  **Caveat:** because name and namespace are joined by `-` into one DNS label, two different
  `(name, namespace)` pairs collapse to the same host (e.g. `victim-team` in namespace `alpha` and
  `victim` in namespace `team-alpha` both yield `victim-team-alpha.{domain}`; likewise name `a`/ns
  `b-c` vs name `a-b`/ns `c` → `a-b-c`). Istio resolves the clash **oldest-VirtualService-wins**, so
  a tenant who can create an InferenceService in *any* namespace can hijack or deny another tenant's
  inference host by picking a colliding **name** — and the attacker chooses the name, so
  admin-provisioned namespaces do **not** bound this. Enable the wildcard opt-in only when every
  namespace that can host an InferenceService is trusted (single tenant, or mutually-trusting teams),
  and avoid namespace names that are dash-suffixes of other tenants' `{name}-{namespace}` hosts. For
  strict per-namespace isolation on an untrusted multi-tenant cluster, keep inference cluster-local
  (leave this opt-in off) or issue a `*.{namespace}.{domain}` cert per namespace with the dotted
  `{name}.{namespace}.{domain}` host form.
- **The gateway authenticates but does NOT authorize per tenant — any authenticated user can
  invoke any InferenceService.** The ext_authz chain checks that the caller has a valid Dex
  session / Bearer token; it does **not** check that the caller owns the model's namespace. There
  is no gateway-scoped `AuthorizationPolicy` binding `*.<kserveDomain>` hosts to their owning
  namespace, the Knative `activator`'s `AuthorizationPolicy` is allow-all (`rules: [{}]`), and
  oauth2-proxy accepts any domain (`email_domains: ["*"]`). Verified manually with a two-user test:
  a token for **any** Dex user (e.g. both `user@example.com` and `alice@example.com`) is accepted
  at **every** tenant's inference host, regardless of which namespace owns the model. This is fine
  for a single tenant or mutually-trusting teams, but on an untrusted multi-tenant cluster it means
  one tenant can invoke — and read the outputs of — another tenant's models. For per-tenant
  invocation isolation, keep this opt-in off (reach inference cluster-local, where namespace-scoped
  `AuthorizationPolicy`/`NetworkPolicy` still apply) or add your own gateway-scoped
  `AuthorizationPolicy` binding each `*.<kserveDomain>` host to its namespace.
- **The flattened label must stay under 63 characters** — DNS limits any single label to 63
  chars. Note the Knative **route host** that actually needs the wildcard cert is the
  *component* Knative Service, not the InferenceService: a serverless predictor routes as
  `{isvc}-predictor-{namespace}` (and `-transformer` / `-explainer` for those components),
  so budget for the ~10-char `-predictor` suffix — the label is that long, not just
  `{isvc}-{namespace}`. Long InferenceService or namespace names can exceed the limit.
- **External access requires a Bearer token or session cookie.** Simply serving over HTTPS
  does not bypass Kubeflow's authentication. See the [Tutorial — Programmatic Access](tutorial.md#programmatic--external-access-bearer-token)
  for how to authenticate external `curl` or Python clients.
- Leave `kserveExternalHttps` false (default) to keep inference on plain HTTP: the dedicated
  `kserve-ingress-gateway` serves `:80` only (no wildcard cert, no `:443`). `status.url` is
  unchanged — still KServe's `{name}-{namespace}.{domain}` host over HTTP.

---

### Production: Bring-your-own certificate

Use this when your organisation manages TLS certificates through an existing PKI or secret manager.
Create your TLS Secret in the `istio-system` namespace before installing:

```bash
kubectl create secret tls my-kubeflow-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n istio-system
```

Then reference it in your values:

```yaml
# prod-values.yaml
kubeflow-istio-resources:
  hostname: "kubeflow.example.com"
  externalDNSEnabled: false   # manage DNS separately
  tls:
    source: "secret"
    existingSecret: "my-kubeflow-tls"
    httpsRedirect: true

# Change credentials as shown in the Let's Encrypt scenario above
auth:
  oidc:
    clientSecret: "<STRONG-RANDOM-32-CHAR-SECRET>"
# ... (rest of credentials)
```

> **KServe inference over HTTPS with a BYO cert.** The chart does not create a cert-manager
> `Certificate` when `tls.source: "secret"` — it uses your Secret(s) as-is. Unlike the
> `letsEncrypt`/`selfSigned`/`issuerRef` paths (which issue a *separate* `kserve-wildcard-tls`
> cert for inference), the `secret` path wires the dashboard server to `tls.existingSecret` and
> the `*.<kserveDomain>` inference server to a **dedicated** `tls.kserveExistingSecret`. When you
> set `global.kserveExternalHttps` to true, `tls.kserveExistingSecret` is **required** (chart
> validation fails fast if it is empty) and its certificate **must include the `*.<kserveDomain>`
> SAN**, or TLS handshakes to inference hosts will fail. If you hold a single multi-SAN / wildcard
> cert that covers both hosts, point both fields at the same Secret. `urlScheme` and the domain
> templates are auto-derived:
>
```yaml
global:
  kserveDomain: "models.example.com"
  kserveExternalHttps: true
> kubeflow-istio-resources:
>   hostname: "kubeflow.example.com"             # the APEX — NOT under *.models.example.com,
>                                                # so the dashboard stays outside the wildcard's
>                                                # blast radius (matches the chart's separation
>                                                # rationale: a wildcard-key compromise or DNS-01
>                                                # failure must not reach the dashboard)
>   tls:
>     source: "secret"
>     existingSecret: "my-kubeflow-tls"          # dashboard cert (SAN: kubeflow.example.com)
>     kserveExistingSecret: "my-kserve-wild-tls" # wildcard cert (SAN: *.models.example.com) —
>                                                # a SEPARATE Secret/key from the dashboard cert
> ```
>
> **Recommendation — two rules that contain the blast radius (a distinct domain is NOT one of
> them):** the wildcard Secret terminates TLS for every tenant's inference endpoint, so its
> private key is a cluster-wide single point of compromise. To contain it:
>
> 1. **Scope the wildcard to a dedicated subdomain, not the org-wide apex.** Use
>    `*.models.example.com` (`kserveDomain: models.example.com`) rather than dropping an
>    org-wide `*.example.com` key into the gateway Secret — a scoped wildcard keeps the blast
>    radius inside the Kubeflow subdomain instead of your whole zone.
> 2. **Keep the dashboard host at the apex, outside the wildcard, on its own Secret.** The apex
>    `kubeflow.example.com` is **not** covered by `*.models.example.com`, so it gets a separate
>    cert. This is why the chart provisions the dashboard cert separately from
>    `kserve-wildcard-tls`: a wildcard-key compromise or a DNS-01 failure on the wildcard cannot
>    take down the dashboard's TLS. Reusing one cert for both (a dashboard host *under* the
>    wildcard) collapses that isolation and is not recommended.
>
> With these two rules, `hostname` and `kserveDomain` are the **same value**
> (`kubeflow.example.com`) — the dashboard sits at the apex and inference at `*.<same domain>`.
>
> **Optional variant (not required for blast radius):** you can put the dashboard on a *distinct*
> domain (`hostname: kubeflow.example.com` with `kserveDomain: models.example.com`). It works
> equally well and keeps the dashboard even further from the inference wildcard, but it adds no
> blast-radius protection beyond the two rules above and costs you a second DNS zone to manage.
>
> Whatever cert you bring, restrict RBAC on Secrets in `istio-system` and rotate it independently
> of any org-wide certificate.
>
> Leave `kserveExternalHttps` false to keep inference on plain HTTP (the dedicated
> `kserve-ingress-gateway` serves `:80` only, no wildcard cert).

> **Inference hostname format.** By default Knative route hosts keep the upstream dotted form
> `{name}.{namespace}.{domain}`. They are only flattened to `{name}-{namespace}.{domain}` when
> you opt into wildcard TLS by setting `global.kserveExternalHttps: true`. If you enable this —
> or are upgrading from a release that flattened hosts unconditionally — update any DNS records,
> clients, or certificate SANs accordingly.

### Production: Use existing external-dns and cert-manager

If the existing environment already has `externa-dns` and `cert-manager`, KubeFlow
can make use of them providing that the follow conditions are satisfied.

1. `external-dns` must be configured to watch for the `istio-gateway` source.
   You can check the deplayment with the `kubectl` CLI. e.g.

```bash
$ kubectl get deployment external-dns -n external-dns -o yaml | grep source=
        - --source=service
        - --source=ingress
        - --source=istio-gateway
```

2. A cluster issuer must exist in the environment, and it is configured to issue certificates
   from a production public CA such as LetsEncrypt. You can check the deployment with the
   `kubectl` CLI. e.g.

```bash
$ kubectl get clusterissuer
NAME                     READY   AGE
letsencrypt-production   True    75m
```

To configure KubeFlow to use existing `external-dns` and `cert-manager`:

Then reference it in your values:

```yaml
# prod-values.yaml
global:
  # Single place for the inference domain — keeps InferenceService URLs on
  # models.example.com instead of the example.com fallback. Domain only;
  # to serve inference over external HTTPS via your existing issuer, add
  # kserveExternalHttps — see "External HTTPS for KServe inference".
  kserveDomain: "models.example.com"
kubeflow-istio-resources:
  hostname: "kubeflow.example.com"
  externalDNSEnabled: true
  tls:
    source: "issuerRef"
    httpsRedirect: true

    issuerRef:
      name: letsencrypt-production

externaldns:
  enabled: false

# Change credentials as shown in the Let's Encrypt scenario above
auth:
  oidc:
    clientSecret: "<STRONG-RANDOM-32-CHAR-SECRET>"
# ... (rest of credentials)
```
> **Note:** when adding `istio-gateway` as a source to `external-dns`, make
> sure the Istio CRDs are installed. Otherwise, `external-dns` pod may keep
> crashing with an error indicating failure to list Istion gateway resource.
> However the error will eventually go away after Istio is installed by
> KubeFlow.

> **Note:** if you are using `runMe.sh` for the installation, make sure to
> specify the `--disable-cert-manager` option to skip installing `cert-manager`.

---

## Values Reference

Full JSON schema: [`charts/kubeflow/values.schema.json`](charts/kubeflow/values.schema.json)

### Global

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
| `global.oauth2Proxy.enabled` | `true` | Master switch for the oauth2-proxy auth layer. Disabling it removes the gateway's ext_authz auth chain, so it is **incompatible with `global.kserveExternalHttps: true`** (the chart fails fast on that combination — see [External HTTPS for KServe inference](#external-https-for-kserve-inference-optional)) |
| `global.gateway.name` | `kubeflow/kubeflow-gateway` | Istio Gateway (`<namespace>/<name>`) for the dashboard and app VirtualServices. KServe inference does **not** use this — it uses `global.kserveGateway.name` |
| `global.kserveGateway.name` | `kubeflow/kserve-ingress-gateway` | Single source of truth for the **dedicated** KServe inference gateway (`<namespace>/<name>`). Threads through the Gateway CR that `kubeflow-istio-resources` renders, the `config-istio` `gateway.<ns>.<name>` key net-istio binds inference to, and kserve's `inferenceservice-config` `ingressGateway`. Keeps inference readiness independent of the dashboard's `:443` TLS |

### Credentials

| Key | Default | Description |
|-----|---------|-------------|
| `auth.oidc.clientSecret` | `pUBnBOY80Sn...` | **DEMO DEFAULT** — OIDC client secret shared between Dex and oauth2-proxy |
| `auth.oidc.cookieSecret` | (demo value, 32-byte base64) | **DEMO DEFAULT** — oauth2-proxy cookie encryption key |
| `auth.initialUser.email` | `user@example.com` | **DEMO DEFAULT** — Default Dex login email |
| `auth.initialUser.passwordHash` | bcrypt of `12341234` | **DEMO DEFAULT** — Change via `dex.config.staticPasswords` |
| `pipelines.seaweedfs.accessKey` | `kubeflow` | **DEMO DEFAULT** — SeaweedFS S3 access key |
| `pipelines.seaweedfs.secretKey` | `kubeflow123` | **DEMO DEFAULT** — SeaweedFS S3 secret key |

### Component toggles

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

### Enabling Model Registry

Model Registry provides model versioning and metadata storage, accessible from the Kubeflow
sidebar. It shares KFP's MariaDB.

Once enabled, access via Central Dashboard → "Model Registry" sidebar link or directly at
`/model-registry/` in your browser.

**REST API example:**
```bash
kubectl run mr-test --rm -i --restart=Never --image=busybox:1.36 -n kubeflow \
  --annotations='sidecar.istio.io/inject=false' -- \
  wget -qO- --timeout=10 \
  http://model-registry-service.kubeflow:8080/api/model_registry/v1alpha3/registered_models
# Expected: {"items":[],"nextPageToken":"","pageSize":0,"totalSize":0}
```

---

### Optional features

| Key | Default | Description |
|-----|---------|-------------|
| `networkPolicies.enabled` | `false` | Deny-all NetworkPolicies with explicit allow rules. Requires a CNI that enforces NetworkPolicy (Calico, Cilium, Canal). Disable with bare Flannel or any CNI that does not enforce NetworkPolicy. |
| `preflightChecks.enabled` | `false` | Pre-install hook Job that validates default StorageClass and cert-manager CRDs |
| `preflightChecks.image.repository` | `containers/kubectl` | Repository for the preflight kubectl image |
| `preflightChecks.image.tag` | `1.34.5` | Tag for the preflight kubectl image |
| `monitoring.enabled` | `false` | ServiceMonitors + PrometheusRules (requires Rancher Monitoring) |
| `pipelines.mariadb.backup.enabled` | `false` | Daily MariaDB backup CronJob to a dedicated PVC |
| `certManager.install` | `false` | Install bundled cert-manager v1.20.2 via this chart (not recommended — install separately) |

### Storage and persistence

| Key | Default | Description |
|-----|---------|-------------|
| `pipelines.mariadb.persistence.storageClassName` | `""` | StorageClass for KFP MariaDB PVC (20 Gi) |
| `pipelines.seaweedfs.storageSize` | `20Gi` | SeaweedFS data volume size |
| `pipelines.seaweedfs.storageClass` | `""` | StorageClass for SeaweedFS PVC |
| `katib.mariadb.persistence.storageSize` | `10Gi` | StorageClass for Katib MariaDB PVC |
| `pipelines.mariadb.backup.storageSize` | `10Gi` | Backup PVC size |
| `pipelines.mariadb.backup.schedule` | `"0 2 * * *"` | Backup cron schedule (daily at 02:00 UTC) |

### Networking / Ingress

| Key | Default | Description |
|-----|---------|-------------|
| `kubeflow-istio-resources.hostname` | `""` | Kubeflow FQDN; empty = wildcard (all hosts) |
| `kubeflow-istio-resources.externalDNSEnabled` | `false` | Annotate Istio Gateway for external-dns |
| `kubeflow-istio-resources.tls.source` | `""` | Dashboard TLS source (`""` \| `selfSigned` \| `letsEncrypt` \| `secret` \| `issuerRef`). |
| `kubeflow-istio-resources.tls.letsEncrypt.email` | `""` | ACME account email — optional (recommended) for letsEncrypt; Let's Encrypt issues without it, omitted from the ClusterIssuer when empty |
| `kubeflow-istio-resources.tls.letsEncrypt.server` | `prod` | `prod` \| `staging` |
| `kubeflow-istio-resources.tls.letsEncrypt.solver` | `cloudflare` | `cloudflare` (DNS-01) \| `http01` |
| `global.kserveExternalHttps` | `false` | Opt in to external HTTPS for KServe inference: adds a `*.<global.kserveDomain>` `:443` server (plus a `:80`→`:443` redirect) to the **dedicated** `kserve-ingress-gateway` (`global.kserveGateway.name`) using a dedicated `kserve-wildcard-tls` cert, and flattens the Knative route host to the single label `{name}-{namespace}.{domain}`. Requires a DNS-01 solver, `global.kserveDomain`, and `global.oauth2Proxy.enabled: true` (without gateway auth the wildcard would expose every tenant's inference endpoint unauthenticated — the chart fails fast). Default (`false`) keeps inference on plain `:80` on the dedicated gateway |
| `global.kserveDomain` | `""` | Base domain for the KServe wildcard cert + gateway server (`*.<global.kserveDomain>`). The **recommended single place** to set the inference domain: when set it overrides and auto-wires `kserve.ingressDomain` and `knativeServing.domain` — set it here, not on the subcharts. Empty = fall back to the subchart-local `knativeServing.domain` / `kserve.ingressDomain` (both default `example.com`). Those subchart keys remain settable, so the global is a convention, not an enforced single source; chart validations catch cross-subchart divergence. **Required** when `global.kserveExternalHttps` is `true` |
| `externaldns.enabled` | `false` | Deploy external-dns |
| `externaldns.cloudflare.apiToken` | `""` | Cloudflare API token; chart creates the Secret |
| `externaldns.domainFilters` | `[]` | Restrict DNS management to these domains |
| `externaldns.txtOwnerId` | `kubeflow` | Unique TXT record owner ID per cluster |

### Advanced

| Key | Default | Description |
|-----|---------|-------------|
| `global.kserveDomain` | `""` | Root domain for KServe InferenceService ingress — the recommended single place to set it. When set, overrides and auto-wires the legacy `knativeServing.domain` / `kserve.ingressDomain` (both still settable, so this is a convention rather than an enforced single source — validations catch divergence). Empty = fall back to those (default `example.com`). With `global.kserveExternalHttps: true` it is also the wildcard cert/gateway base |
| `dex.existingOidcClientSecret` | `""` | Name of a pre-existing Secret containing the OIDC client secret; overrides `auth.oidc.clientSecret` |
| `dex.resources` | `{requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}` | CPU/memory for the Dex container |
| `user-namespace.pipelines.seaweedfs.accessKey` | (wired from `pipelines.seaweedfs.accessKey`) | SeaweedFS S3 access key injected into every user namespace |
| `user-namespace.pipelines.seaweedfs.secretKey` | (wired from `pipelines.seaweedfs.secretKey`) | SeaweedFS S3 secret key injected into every user namespace |

### Registry Overrides

Images resolve their registry through a three-tier precedence: an optional master
override, an optional per-family override, then a per-component default.

| Value | Default | Scope |
|-------|---------|-------|
| `global.imageRegistry` | `""` | **All images** — SUSE AI and Application Collection. Overrides everything when set. |
| `global.suseRegistry` | `""` | Optional override for SUSE AI images only (`registry.suse.com/*` — kubeflow components, kfp, kserve, etc.) |
| `global.suseApplicationCollectionRegistry` | `""` | Optional override for Application Collection images only (`dp.apps.rancher.io/*` — mariadb, bci-busybox, kubectl, kube-rbac-proxy, workflow-controller, argoexec, metacontroller) |
| `<subchart>.<component>.image.registry` | `registry.suse.com` (SUSE) / `dp.apps.rancher.io` (App Collection) | The per-component default used when the globals above are empty. |

Precedence (highest to lowest) for each image type:
- **SUSE AI images:** `global.imageRegistry` → `global.suseRegistry` → component `image.registry`
- **App Collection images:** `global.imageRegistry` → `global.suseApplicationCollectionRegistry` → component `image.registry`

All three globals default to empty, so out of the box every image resolves from its own
component `registry:` field (`registry.suse.com` for SUSE AI, `dp.apps.rancher.io` for
Application Collection). Setting a family global overrides that default in bulk for its family;
setting `global.imageRegistry` overrides every image. An unset global simply falls through to
the next tier — nothing is mandatory, so a subchart also renders correctly standalone. See
[docs/registry-values.md](docs/registry-values.md) for the full model.

**Example — mirror only Application Collection images:**

```yaml
global:
  suseApplicationCollectionRegistry: mirror.corp.example.com
```

**Example — mirror both registries:**

```yaml
global:
  suseRegistry: mirror.corp.example.com
  suseApplicationCollectionRegistry: mirror.corp.example.com
```

**Example — single nuclear override for all images:**

```yaml
global:
  imageRegistry: mirror.corp.example.com  # overrides ALL images
```

---

## Production Hardening

The chart ships with demo defaults that are **not suitable for production**. Address these before
exposing the deployment to any network or storing sensitive data.

By default (`global.demoMode: false`) the chart **fails at render time** with a `SECURITY:` error
if any well-known demo credential is still present. To suppress this during local development, set
`global.demoMode: true` in your values file — never set this in production.

### 1. Change all default credentials

The credentials that trigger the render-time security check:

```yaml
# In your values override file

auth:
  oidc:
    clientSecret: "<STRONG-RANDOM-SECRET>"
    cookieSecret: "<STRONG-RANDOM-32-BYTE-BASE64>"  # generate: openssl rand -base64 32

dex:
  config:
    staticClients:
      - id: kubeflow-oidc-authservice
        redirectURIs:
          - /oauth2/callback
        name: kubeflow-oidc-authservice
        secret: "<STRONG-RANDOM-SECRET>"   # must match auth.oidc.clientSecret above
    staticPasswords:
      - email: "admin@yourcompany.com"
        # Generate: htpasswd -nbBC 12 "" 'YourPassword' | tr -d ':\n' | sed 's/$2y/$2a/'
        hash: "<BCRYPT-HASH>"
        username: admin
        userID: "1"
    enablePasswordDB: true

pipelines:
  seaweedfs:
    accessKey: "<STRONG-ACCESS-KEY>"
    secretKey: "<STRONG-SECRET-KEY>"

user-namespace:
  pipelines:
    seaweedfs:
      accessKey: "<STRONG-ACCESS-KEY>"    # must match pipelines.seaweedfs.accessKey
      secretKey: "<STRONG-SECRET-KEY>"    # must match pipelines.seaweedfs.secretKey
```

> **MariaDB root passwords:** Both the KFP and Katib MySQL secrets are **auto-generated** (24-char
> random password) on first install and preserved across upgrades — no action required. To rotate,
> delete the secret and run `helm upgrade` to regenerate:
> ```bash
> kubectl delete secret mysql-secret -n kubeflow        # KFP
> kubectl delete secret katib-mysql-secrets -n kubeflow # Katib
> helm upgrade kubeflow . -f my-values.yaml -n kubeflow
> ```

### 2. Use an external identity provider

Replace Dex static passwords with an LDAP, SAML, or upstream OIDC connector. Add a `connectors`
block to `dex.config` and remove `staticPasswords` + `enablePasswordDB: true`.

### 3. NetworkPolicies

NetworkPolicies are **disabled by default**. They use an ingress-only deny-by-default model
— egress is unrestricted so components can reach external services (HuggingFace, container
registries, etc.).

Supported by Calico, Cilium, Canal, and any other CNI that enforces NetworkPolicy.
Disable if your CNI does not enforce NetworkPolicy.

```yaml
networkPolicies:
  enabled: true
```

### 4. Enable TLS

See [Production: Let's Encrypt TLS + external-dns](#production-lets-encrypt-tls--external-dns)
or [Production: Bring-your-own certificate](#production-bring-your-own-certificate).

### 5. Enable database backups

```yaml
pipelines:
  mariadb:
    backup:
      enabled: true
      schedule: "0 2 * * *"   # daily at 02:00 UTC
      storageSize: 20Gi
```

To restore a backup:

```bash
# List available backups
kubectl exec -n kubeflow sts/mysql -- ls /backup/

# Restore
kubectl exec -n kubeflow sts/mysql -- \
  sh -c "mariadb --ssl=false -u root < /backup/<filename>.sql"
```

### 6. Enable pre-install validation

```yaml
preflightChecks:
  enabled: true
```

Runs a hook Job before install that validates the default StorageClass exists and cert-manager
CRDs are registered.

### 7. Enable High Availability

Apply `ha-overrides.yaml` (provided in the repo) on top of your base values to scale the Katib
controller, training-operator, and KServe controller to 2 replicas. KFP and Dex
PodDisruptionBudgets are already enabled by default.

```bash
helm upgrade kubeflow . -f <your-values>.yaml -f ha-overrides.yaml -n kubeflow
```

> PDBs protect against voluntary disruptions (node drains) but only provide meaningful coverage
> with 2+ replicas. With a single replica, the PDB allows full eviction.
> See the [Known Limitations](#known-limitations) section for which controllers support HA.

### 8. Resource quotas per user namespace

```yaml
additionalUsers:
  - email: alice@example.com
    namespace: alice
    resourceQuota:
      requests.cpu: "4"
      requests.memory: "8Gi"
      requests.nvidia.com/gpu: "1"
```

---

## Multi-tenancy

Kubeflow uses a Profile-per-user model. The `kubeflow-user-example-com` namespace is the default
user namespace created at install time.

### Adding users at install time

```yaml
# my-values.yaml

# The default user namespace is always created (kubeflow-user-example-com).
# Add more users here — each gets a Profile CR and an isolated namespace.
user-namespace:
  additionalUsers:
    - email: alice@example.com
      namespace: alice               # explicit name recommended — avoids email slug collisions
      resourceQuota:
        requests.cpu: "4"
        requests.memory: 8Gi
    - email: bob@example.com
      namespace: bob
```

> **Important:** The `namespace` field is optional but strongly recommended. Without it, the
> namespace is auto-generated from the email by replacing `@` with `--` and `.` with `-`.
> Emails that differ only by `.` vs `-` (e.g. `alice.smith@corp.com` and `alice-smith@corp.com`)
> produce the same auto-generated slug — use an explicit `namespace` to disambiguate.

### Adding users after install

Add the user to your values file and run `helm upgrade`:

```bash
helm upgrade kubeflow oci://registry.suse.com/ai/charts/kubeflow \
  --version <version> \
  -n kubeflow --reuse-values \
  --set "user-namespace.additionalUsers[0].email=alice@example.com" \
  --set "user-namespace.additionalUsers[0].namespace=alice"
```

Or add the user to your values file and re-run the upgrade:

```yaml
# my-values.yaml
user-namespace:
  additionalUsers:
    - email: alice@example.com
      namespace: alice
```

**OCI (production):**
```bash
helm upgrade kubeflow oci://registry.suse.com/ai/charts/kubeflow \
  --version <version> \
  -n kubeflow -f my-values.yaml
```

**From source (development):**
```bash
helm upgrade kubeflow -n kubeflow --force-conflicts -f my-values.yaml .
```

This creates the Profile CR and deploys all required KFP per-namespace resources
(pipeline artifact server, visualization server, credentials, authorization policies)
in a single step.

> **Note:** Do not add users by applying a `Profile` CR directly with `kubectl`.
> The profiles controller only creates namespace-level RBAC — it does not deploy the
> KFP per-namespace resources that pipelines depend on. Users added this way will have
> an incomplete environment and pipeline runs will fail.

---

## Upgrade Notes

### Security — client identity-header spoofing fixed (upgrade recommended)

_Applies to chart version `0.4.0-alpha.2` and later._

This release closes an identity-spoofing gap in the gateway auth filter that
affects **all** installs (not just the KServe external-HTTPS opt-in). Previously a
client could send Kubeflow identity headers (`kubeflow-userid` and the
`x-auth-request-email` / `-user` / `-groups` / `-preferred-username` family)
directly to the gateway; on request paths where ext_authz did not overwrite them,
a downstream app could trust the client-supplied value. The gateway now strips the
entire client-supplied identity-header family at ingress and re-derives
`kubeflow-userid` from the authenticated `x-auth-request-email` (using `replace()`,
not `add()`), so identity is always gateway-authoritative. **Operators running any
prior release should upgrade.** No configuration change is required.

### Migration — Model Registry consolidated into Kubeflow Hub

_Applies to chart version `0.4.0-alpha.2` and later._

The separate `model-registry` and `kubeflow-hub` subcharts have been merged into a
single **`kubeflow-hub`** chart, where "Hub" (formerly Model Registry) is the
umbrella component bundling the Model Registry and the Model Catalog.
The `kubeflow-hub` subchart deploys **one shared** Model Registry
in the `kubeflow` namespace serving all profiles.

**Action required:** rename any `modelRegistry.*` values to `hub.*` in your overrides.

```yaml
modelRegistry:
  enabled: true
  catalog:
    enabled: false
```

```yaml

hub:
  enabled: true
  catalog:
    enabled: false
```

Notes:
- `hub.enabled` defaults to `true`, so default installs are unaffected.
- Kubernetes resource names (`model-registry-*`) and routes (`/api/model_registry/`,
  `/model-registry/`) are unchanged — no dashboard or client changes needed.
- All Hub component **images** are aligned to community-distribution **release-26.03.1**
  and pinned to **v0.3.10** under the renamed `hub/*` path: `hub/server` (also reused
  by the Model Catalog), `hub/ui`, `hub/controller`, and `hub/storage-initializer`
  (previously the UI/controller/storage-initializer used `model-registry/*` at v0.3.7).
- The registry server liveness/startup probes now use `/readyz/isDirty` (readiness
  stays `/readyz/health`), matching release-26.03.1.
- Catalog PostgreSQL dependency bumped `0.5.5` → `0.6.0` (PostgreSQL 18.3 → 18.4,
  same major version — no data migration).
- `hub.enabled=true` still requires `pipelines.enabled=true` (shares KFP's MariaDB).

### Migration — KServe inference domain moved to `global.*`

_Applies to chart version `0.4.0-alpha.2` and later._

The KServe/Knative inference domain now has one recommended home under
**`global.kserveDomain`** — set it there and it overrides and auto-wires the
subchart keys. (The subchart keys remain settable as a fallback, so this is a
convention backed by validations, not a hard single source; see the note below.)
External HTTPS for inference is an opt-in flag **`global.kserveExternalHttps`**.
The old knobs — `_kserveAccess.domain` and hand-set `kserve.urlScheme` /
`kserve.ingressDomain` / `knativeServing.domain` / `knativeServing.domainTemplate`
— are gone or auto-derived.

**Non-breaking by default.** `global.kserveDomain` defaults to `""`, which falls back to
the subchart-local `knativeServing.domain` / `kserve.ingressDomain` (both still default to
`example.com`). Plain-HTTP installs keep KServe's default `{name}-{namespace}.{domain}`
`status.url` host, served over HTTP — no change.

**Action required only if you customized the domain or use the old knobs:**

```yaml
_kserveAccess:
  domain: mycompany.com
knativeServing:
  domain: mycompany.com
kserve:
  ingressDomain: mycompany.com
```

```yaml
global:
  kserveDomain: mycompany.com
```

Notes:
- **Move a custom domain to `global.kserveDomain`.** A leftover `_kserveAccess.domain` key is
  **silently ignored** (the schema does not reject unknown keys), so a typo or a stale key
  produces no error — it just has no effect.
- **Avoid `helm upgrade --reuse-values`** for this upgrade — it carries forward the old
  value tree and misses the new `global.*` structure. Re-supply your full values file.
- **Enabling `global.kserveExternalHttps: true` is a scoped breaking change.** It flattens
  the Knative route host from `{name}.{namespace}.{domain}` to `{name}-{namespace}.{domain}`
  (so a single `*.<domain>` wildcard cert covers it) and switches inference URLs to `https`
  on `global.kserveDomain`; the InferenceService `status.url` keeps KServe's
  `{name}-{namespace}.{domain}` host in both modes. Requires `global.kserveDomain` plus a
  DNS-01 solver. Update DNS records, client URLs (scheme/domain), and BYO-cert SANs
  accordingly. See
  [External HTTPS for KServe inference](#kserve-inference-hostname-format-wildcard-tls-opt-in-only)
  for the single-label naming caveat.

### Migration — KServe inference moved to a dedicated gateway

_Applies to chart version `0.4.0-alpha.2` and later._

KServe/Knative inference no longer shares the dashboard's `kubeflow-gateway`. The chart now
renders a **dedicated `kserve-ingress-gateway`** (in the `kubeflow` namespace) and points
net-istio at it via `config-istio`, so the readiness prober only probes that gateway's ports.
This fixes the net-istio `EOF` / `Ready=Unknown` stall that occurred when inference and a
TLS-terminating dashboard shared one gateway (the prober tried the dashboard's `:443` on
inference hosts). The dashboard's `kubeflow-gateway` is now dashboard-only.

The gateway reference is a single value, **`global.kserveGateway.name`** (default
`kubeflow/kserve-ingress-gateway`), which threads through three places that must stay in sync:
the Gateway CR rendered by `kubeflow-istio-resources`, the `config-istio`
`gateway.<namespace>.<name>` key, and kserve's `inferenceservice-config` `ingressGateway`.

**Non-breaking by default.** Fresh installs get the dedicated gateway automatically; inference
serves on plain `:80` (or `:443` with `global.kserveExternalHttps: true`) exactly as before, just
on its own gateway. Override `global.kserveGateway.name` only if you need a different
namespace/name (e.g. `infra/my-kserve-gw`).

> **Upgrading a live release that previously shared the gateway:** the pre-existing
> `kubeflow-gateway` may still carry a leftover `http-kserve` `*:80` server and any Knative
> ingress VirtualServices may still bind it. After `helm upgrade`, confirm inference
> VirtualServices bind `kserve-ingress-gateway` (`kubectl get virtualservice -A -o yaml | grep
> gateways -A2`) and that `kubeflow-gateway` no longer lists a KServe `:80` server. A pre-existing
> gateway created outside Helm must be adopted or removed so Helm can own the new one.

### Behaviour change — `letsEncrypt` ClusterIssuer is now DNS-zone scoped

_Applies to chart version `0.4.0-alpha.2` and later. Affects `tls.source: letsEncrypt` installs._

The chart-managed `kubeflow-letsencrypt` ClusterIssuer previously emitted a **selector-less
(catch-all) solver** — it would solve ACME challenges for *any* DNS name, including out-of-chart
`Certificate` resources that referenced it. It is now scoped with a `dnsZones` **selector** seeded
with the dashboard host (`kubeflow-istio-resources.hostname`, falling back to `kubeflow.local`)
plus `global.kserveDomain` when the wildcard opt-in is on.

This is a **silent behaviour change**: after upgrading, an out-of-chart `Certificate` that pointed
at `kubeflow-letsencrypt` for a name **outside** those zones will no longer be solved by this
issuer and its order will stall (no matching solver) — with no chart-level error. If you rely on
`kubeflow-letsencrypt` for other names, either add those zones by setting
`kubeflow-istio-resources.hostname` / `global.kserveDomain` to cover them, or (recommended) create
your own dedicated ClusterIssuer for out-of-chart certificates. Note the `dnsZones` selector is a
solver *selector*, not an authorization control — gate `Certificate` creation with RBAC.

### Trainer CRDs realigned to v2.2.1 (manual `kubectl apply` required)

_Applies to `trainer` sub-chart `0.2.0` and later. Affects any install with `trainer.enabled: true`._

The three `trainer.kubeflow.org` CRDs (`trainjobs`, `clustertrainingruntimes`, `trainingruntimes`)
were **out of sync with the deployed Trainer controller** (`appVersion v2.2.1`, image
`trainer-controller-manager:v2.2.1`) and are now regenerated from a single upstream **v2.2.1**
controller-gen run. This is a schema realignment, not a controller change — the image stays
`v2.2.1`. Concretely:

- **`TrainJob`**: `spec.podTemplateOverrides`, `spec.labels`, and `spec.annotations` are **removed**;
  `spec.runtimePatches` and `spec.activeDeadlineSeconds` are the v2.2.1 replacements. The old fields
  were already **inert** under the v2.2.1 controller (it has honored `runtimePatches` since v2.2.1),
  but the previously-shipped CRD still *advertised* them. **The API server prunes unknown fields**,
  so any stored `TrainJob` that still carries `podTemplateOverrides` / `spec.labels` /
  `spec.annotations` will lose those values on its next write. They had no effect under v2.2.1
  regardless; migrate any pod-level customization to `spec.runtimePatches`.
- **`ClusterTrainingRuntime` / `TrainingRuntime`**: the ML-policy schema is realigned to v2.2.1 —
  adds the `flux` and `jax` runtime policies and replaces the old Torch `elasticPolicy`
  (HPA-metrics) shape. The previously-shipped runtime CRDs were stale here.

**Helm does not upgrade `crds/`** (it only installs CRDs on first install). On an existing install
the *old* stored CRDs persist after `helm upgrade`, so a manifest using `spec.runtimePatches` (or the
new runtime policies) is **rejected by the API server** until you apply the new CRDs by hand:

```bash
kubectl apply -f charts/trainer/crds/
# (or `kubectl replace -f charts/trainer/crds/` if apply hits the
#  metadata.annotations too-long limit on these large CRDs)
```

Apply the CRDs **before** creating any `runtimePatches` TrainJob or the updated runtimes (the e2e
suite's `runtimePatches` manifest depends on it).

### Always use `--force-conflicts`

**OCI (production):**

```bash
helm upgrade kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow --force-conflicts --wait --timeout 15m
```

**From source (development only):**

```bash
helm dependency update charts/kubeflow
helm upgrade kubeflow charts/kubeflow -n kubeflow --force-conflicts --wait --timeout 15m
```

### Sub-chart version bumps (source installs only)

After editing a sub-chart's `Chart.yaml` version in a local checkout, repackage before upgrading:

```bash
# If the sub-chart itself has dependencies (e.g. kubeflow-pipelines):
helm dependency update charts/apps/<chart-name>

# Always required before helm upgrade from source:
helm dependency update charts/kubeflow
```

### Switching database engines or changing StorageClass

PVCs with `helm.sh/resource-policy: keep` are not deleted by Helm. When switching database
images or StorageClasses, delete the PVC manually first:

```bash
# For KFP MariaDB (Rancher MariaDB StatefulSet)
kubectl delete pvc -n kubeflow data-mysql-0

# For Katib MariaDB (standalone Deployment, not StatefulSet)
kubectl delete pvc -n kubeflow katib-mysql
```

### Training operator webhook secret migration (auto)

On upgrade from chart versions prior to 0.3.0, a pre-upgrade hook automatically migrates the
`training-operator-webhook-cert` Secret from type `kubernetes.io/tls` to `Opaque`. No manual
action is required. If the hook fails (visible via `kubectl get jobs -n kubeflow`), delete the
secret manually and re-run `helm upgrade`:

```bash
kubectl delete secret training-operator-webhook-cert -n kubeflow --ignore-not-found
helm upgrade kubeflow charts/kubeflow -n kubeflow --force-conflicts --wait --timeout 15m
```

### Credential rotation (SeaweedFS)

Changing `pipelines.seaweedfs.accessKey`/`secretKey` requires restarting all KFP Deployments that
read those credentials — pods do not automatically restart when a Secret changes:

```bash
kubectl rollout restart deployment -n kubeflow \
  ml-pipeline ml-pipeline-ui ml-pipeline-persistenceagent ml-pipeline-scheduledworkflow
kubectl rollout restart deployment -n kubeflow-user-example-com \
  ml-pipeline-ui-artifact
```

SeaweedFS IAM accumulates credentials across restarts (the `postStart` hook adds, never removes).
To clean stale entries after a rotation:

```bash
kubectl exec -n kubeflow deploy/seaweedfs -- \
  sh -c "printf 's3.configure -user <old-user> -access_key <old-key> -delete -apply\n' \
    | weed shell -master 127.0.0.1:9333"
```

### SeaweedFS upgrade downtime

SeaweedFS uses a `Recreate` deployment strategy (single-node S3 store backed by a PVC). During
`helm upgrade`, the old pod is terminated before the new pod starts. Expect a brief window (10–60s)
where S3 artifact uploads and downloads are unavailable. In-flight pipeline runs may stall.

Recommended: quiesce active pipeline runs before upgrading.

### `--reuse-values` gotcha

Running `helm upgrade --reuse-values` does not update the `user-namespace` Secret with new
SeaweedFS credentials. Always supply the full values file on upgrade, or patch the Secret
manually after upgrade.

### KServe inference hostname format (wildcard-TLS opt-in only)

**Scoped to the wildcard-TLS opt-in — default and plain-HTTP installs are unaffected.** The
InferenceService `status.url` you call is always KServe's single-label
`{name}-{namespace}.{domain}` host, in **both** modes. What the opt-in changes is (a) the scheme
(`http`→`https`) and base domain (`global.kserveDomain`), and (b) the **Knative route host** that
net-istio probes for readiness: by default that is Knative's dotted `{name}.{namespace}.{domain}`,
and the opt-in flattens it to `{name}-{namespace}.{domain}` so one `*.{domain}` wildcard cert
covers it (Let's Encrypt cannot issue a two-level `*.*.{domain}` wildcard). Both are auto-derived
from `global.kserveExternalHttps` + `global.kserveDomain` — no manual `domainTemplate`/`urlScheme`
needed. Note that `{name}` here is the **component Knative Service**, not the InferenceService: a
serverless predictor's route host is `{isvc}-predictor-{namespace}.{domain}` (likewise
`-transformer` / `-explainer`), so the flattened label carries that component suffix even though
the `status.url` you call is the shorter `{isvc}-{namespace}.{domain}`.

Knative renders that host with Go's stdlib `text/template`, not Helm/Sprig, so the namespace
**cannot** be hashed — name and namespace are joined by `-`. **Caveat:** two different
`(name, namespace)` pairs can collide into the same host (e.g. name `a`/ns `b-c` vs name `a-b`/ns
`c` → `a-b-c`); this join is also how KServe forms `status.url` upstream, so the caveat is not new
to the opt-in. Istio resolves a clash oldest-VirtualService-wins, so a tenant who can create an
InferenceService in any namespace can hijack or deny another's inference host by picking a colliding
name — the attacker chooses the name, so admin-provisioned namespaces do **not** bound this. Treat
this opt-in as single-tenant-first: enable it only when every namespace that can host an
InferenceService is trusted. For strict isolation on an untrusted multi-tenant cluster keep inference
cluster-local or use a per-namespace `*.{namespace}.{domain}` cert.

When you enable this opt-in — or are upgrading from a release that flattened the Knative host
unconditionally — update:

- DNS records / `/etc/hosts` entries (a `*.<kserveDomain>` wildcard, or per-host)
- Client URLs and scripts (switch `http`→`https` and to `global.kserveDomain`; the
  `{name}-{namespace}` host format itself is unchanged)
- Certificate SANs (BYO certs) — must cover `*.<kserveDomain>`

The flattening is required so a single wildcard cert (`*.<domain>`) can cover inference hosts —
see [External HTTPS for KServe inference](#external-https-for-kserve-inference-optional). Note the
flattened label must stay under the 63-character DNS limit, and the route-host label includes the
component suffix (`{isvc}-predictor-{namespace}`, etc.), so budget ~10 chars beyond
`{isvc}-{namespace}`.

---

## Testing

### Connectivity smoke tests

Runs outside the cluster using `kubectl`. Checks pod health, Deployment readiness, CRDs, Secrets,
TCP service connectivity, SeaweedFS bucket presence, and HTTP health endpoints.

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
```

Ensure the default StorageClass exists:

```bash
kubectl get storageclass
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

The value must be `""` (empty string). A non-empty value (e.g. `kubeflow`) causes the agent to
watch only that namespace and miss workflow updates in user namespaces.

### TensorBoard unavailable / controller CrashLoopBackOff

Check that the `tensorboard-controller-config` ConfigMap contains both required keys:

```bash
kubectl get configmap -n kubeflow -l app=tensorboard-controller -o yaml | grep -A5 'data:'
```

Required keys:
- `ISTIO_HOST: "*"`
- `ISTIO_GATEWAY: kubeflow/kubeflow-gateway` (must be in `namespace/name` format)

If either key is wrong or missing, fix it via `helm upgrade` so the change persists across future upgrades.

**From source:**

```bash
helm upgrade kubeflow . -n kubeflow \
  --reuse-values --force-conflicts \
  --set tensorboard-controller.configMapData.ISTIO_HOST="*" \
  --set tensorboard-controller.configMapData.ISTIO_GATEWAY=kubeflow/kubeflow-gateway
```

**From OCI registry (production):**

```bash
helm upgrade kubeflow oci://registry.suse.com/ai/charts/kubeflow \
  --version <version> -n kubeflow \
  --reuse-values --force-conflicts \
  --set tensorboard-controller.configMapData.ISTIO_HOST="*" \
  --set tensorboard-controller.configMapData.ISTIO_GATEWAY=kubeflow/kubeflow-gateway
```

Alternatively, add the values to your override file and re-run your normal upgrade command:

```yaml
tensorboard-controller:
  configMapData:
    ISTIO_HOST: "*"
    ISTIO_GATEWAY: kubeflow/kubeflow-gateway
```

### KServe InferenceService not progressing

Verify the `ClusterStorageContainer` CRD and default object exist:

```bash
kubectl get crd clusterstoragecontainers.serving.kserve.io
kubectl get clusterstoragecontainer default
```

If either is missing, re-run `helm upgrade` — the chart installs them.

### "RBAC: access denied" for user namespace traffic

Rancher Istio uses the `istio` ServiceAccount (not `istio-ingressgateway-service-account`).
The `rancher-ingressgateway-access` AuthorizationPolicy in each user namespace handles this.

If you pre-created the AuthorizationPolicy with `kubectl` before the first Helm install, you need
to add Helm ownership labels/annotations before upgrade:

```bash
kubectl label authorizationpolicy rancher-ingressgateway-access \
  -n kubeflow-user-example-com app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate authorizationpolicy rancher-ingressgateway-access \
  -n kubeflow-user-example-com \
  meta.helm.sh/release-name=kubeflow \
  meta.helm.sh/release-namespace=kubeflow --overwrite
```

### SeaweedFS pod stuck ContainerCreating

On K3s 1.34 + cri-dockerd (Rancher Desktop), a race between the CNI and the container runtime can
leave the SeaweedFS pod stuck. SeaweedFS acquires a LevelDB file lock on startup; if the pod is
stuck, the lock is held and the next pod will also fail to start.

Recovery:

```bash
# Find the Docker container ID for the stuck pod
docker ps | grep seaweedfs

# Release the lock
docker kill <container-id>

# Delete the stuck pod — a new pod will start cleanly
kubectl delete pod -n kubeflow -l app=seaweedfs
```

### Dex login loop (infinite redirect)

This usually means oauth2-proxy is receiving a 403 from an Istio AuthorizationPolicy rather than
from oauth2-proxy itself. The Lua-redirect filter only converts 403 → 302 when the response
includes a `set-cookie` header; AuthorizationPolicy 403s do not have one.

Check for sidecar-level AuthorizationPolicy denials:

```bash
kubectl logs -n istio-system -l app=istiod | grep "RBAC"
kubectl get authorizationpolicy -A
```

---

## Known Limitations

- Namespace names are hardcoded in most templates (`kubeflow`, `knative-serving`, `istio-system`).
  Deploying to a non-standard namespace requires template modifications.
- Argo workflow executor image pull secrets must be set via the `workflow-controller-configmap`
  `workflowDefaults` field — they cannot be set via Helm values at runtime because the configmap
  is rendered at pod-create time, not Helm time.
- `knativeServing.enabled` must be `true` for KServe to function. Disabling Knative Serving will
  cause KServe InferenceService resources to remain in a non-Ready state.
- Only the Cloudflare provider is supported for external-dns out of the box. Other providers
  (AWS Route53, Azure, GCP) require additional `externaldns.env` configuration.
- **SeaweedFS is single-node, non-replicated.** Pipeline artifact storage has no HA; a SeaweedFS
  pod restart causes a brief (~10–60s) S3 outage. For production HA, replace SeaweedFS with an
  external S3-compatible store.
- **Not all Kubeflow controllers support multiple replicas.** Leader election is confirmed for
  katib-controller (v0.17+), training-operator, kserve-controller-manager, pvcviewer-controller,
  and model-registry-controller — these are safe to scale via `ha-overrides.yaml`. It is **not**
  confirmed for notebook-controller, profiles-controller, tensorboard-controller, and several KFP
  background workers; setting `replicaCount > 1` for those may cause duplicate reconciliation or
  data corruption.
- **CRDs are not automatically upgraded by `helm upgrade`.** Kubeflow CRDs are placed in `crds/`
  subdirectories; Helm intentionally skips them on upgrade. After a chart version bump, run:
  ```bash
  find charts -path '*/crds/*.yaml' | xargs -I{} kubectl apply -f {}
  ```
- **Dex must be v0.23.0 (dex 2.42.0).** v0.24.0 (dex 2.44.0) uses Go 1.25 which introduced
  strict IPv6 URL parsing. Kubernetes API server addresses like `[10.43.0.1]:443` are rejected,
  crashing Dex on startup. The chart pins v0.23.0.
- **SeaweedFS image is pulled from Docker Hub** (`chrislusf/seaweedfs:4.00`). Air-gapped clusters
  or environments with Docker Hub pull-rate limits will fail to start Kubeflow Pipelines. Mirror
  the image to a private registry and set `global.imageRegistry` (or `global.suseRegistry`) to override.
