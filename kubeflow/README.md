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
| Helm | >= 4.0 | Required for OCI chart support |
| cert-manager | 1.19.3 | Installed by `runMe.sh`; or pre-install manually |
| Istio | 1.1.3 | Installed by `runMe.sh`; or pre-install manually |
| Load Balancer (i.e. metallb) | - | It is required when used in conjunction with external-dns and cert-manager. Tested with MetalLB v0.15.3 |
| Default StorageClass | — | Local Path Provisioner (dev) or Longhorn (prod) |
| SUSE Application Collection credentials | — | Username + token for `dp.apps.rancher.io` (application-collection secret) |
| SUSE Registry credentials | — | Username + token for `stgregistry.suse.com` (suse-ai-registry secret) |

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

1. Performs Helm registry logins for `dp.apps.rancher.io` and `stgregistry.suse.com`
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
| `<suse-ai-registry-token>` | `SUSE_REGISTRY_TOKEN` | SUSE Registry token / password (for `stgregistry.suse.com`) SCC_REG_CODE for AI|
| `--kubeconfig <path>` | `KUBECONFIG` | Path to kubeconfig (defaults to `~/.kube/config`, or KUBECONFIG environment variable if set) |
| `--cloudflare-api-key <key>` | `CLOUDFLARE_API_KEY` | Creates `cloudflare-api-key` Secret in `kubeflow` and `cert-manager` namespaces |
| `-f <file>` / `--values-file <file>` | — | Path to a values override YAML file passed to `helm upgrade` |
| `--disable-cert-manager` | - | Do not upgrade/install cert-manager, use an existing one instead |


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
helm registry login stgregistry.suse.com \
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

# Create suse-ai-registry pull secret (SUSE Registry — stgregistry.suse.com)
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create secret docker-registry suse-ai-registry \
    --docker-server=stgregistry.suse.com \
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
  --version 1.19.3 \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m
```

#### Step 6 — Install Istio

```bash
helm upgrade --install istio oci://dp.apps.rancher.io/charts/istio \
  --version 1.1.3 \
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
  oci://stgregistry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m
```

To apply a values override file, for example the `demo-overrides.yaml` provided in the [repo](https://github.com/SUSE/suse-ai-charts/tree/main/kubeflow). **Never use `demo-overrides.yaml` in production**:

```bash
helm upgrade --install kubeflow \
  oci://stgregistry.suse.com/ai/charts/kubeflow \
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
  oci://stgregistry.suse.com/ai/charts/kubeflow \
  --version 0.3.2 \
  -n kubeflow \
  --force-conflicts \
  --wait --timeout 15m \
  -f prod-values.yaml
```

> **Using `staging` first is strongly recommended.** Let's Encrypt rate-limits production
> certificate issuance. Test with `server: staging` until the certificate is issued, then switch
> to `server: prod` and run `helm upgrade` again.

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
| `global.imageRegistry` | `""` | Optional private registry prefix for air-gapped deployments |
| `global.labels` | `{}` | Common labels applied to all managed resources |
| `global.demoMode` | `false` | Set `true` to suppress credential validation; **never use in production** |
| `global.oauth2Proxy.enabled` | `true` | Master switch for the oauth2-proxy auth layer |
| `global.gateway.name` | `kubeflow/kubeflow-gateway` | Istio Gateway reference used by all VirtualServices |

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
| `modelRegistry.enabled` | `true` | Model Registry (requires `pipelines.enabled=true`) |
| `trainingOperator.enabled` | `true` | Training Operator V1 (TFJob, PyTorchJob, etc.) |
| `trainer.enabled` | `true` | Trainer V2 (TrainJob, TrainingRuntime, ClusterTrainingRuntime) |
| `profiles.enabled` | `true` | Profiles & KFAM (multi-tenancy) |
| `volumesWebApp.enabled` | `true` | Volumes Web App + PVCViewer Controller |
| `tensorboard.controller.enabled` | `true` | TensorBoard Controller |
| `tensorboard.webApp.enabled` | `true` | TensorBoard Web App |
| `knativeServing.enabled` | `true` | Knative Serving (required by KServe) |
| `knativeEventing.enabled` | `false` | Knative Eventing (optional, disabled by default) |
| `notebooks.enabled` | `true` | Master switch for all notebook components |
| `modelRegistry.catalog.enabled` | `false` | Model catalog server with PostgreSQL backend (disabled by default) |
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
| `preflightChecks.image.registry` | `dp.apps.rancher.io` | Registry for the preflight kubectl image |
| `preflightChecks.image.repository` | `containers/kubectl` | Repository for the preflight kubectl image |
| `preflightChecks.image.tag` | `1.34.5` | Tag for the preflight kubectl image |
| `monitoring.enabled` | `false` | ServiceMonitors + PrometheusRules (requires Rancher Monitoring) |
| `pipelines.mariadb.backup.enabled` | `false` | Daily MariaDB backup CronJob to a dedicated PVC |
| `certManager.install` | `false` | Install bundled cert-manager v1.13.1 via this chart (not recommended — install separately) |

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
| `kubeflow-istio-resources.tls.source` | `""` | `""` \| `selfSigned` \| `letsEncrypt` \| `secret` |
| `kubeflow-istio-resources.tls.letsEncrypt.email` | `""` | ACME account email (required for letsEncrypt) |
| `kubeflow-istio-resources.tls.letsEncrypt.server` | `prod` | `prod` \| `staging` |
| `kubeflow-istio-resources.tls.letsEncrypt.solver` | `cloudflare` | `cloudflare` (DNS-01) \| `http01` |
| `externaldns.enabled` | `false` | Deploy external-dns |
| `externaldns.cloudflare.apiToken` | `""` | Cloudflare API token; chart creates the Secret |
| `externaldns.domainFilters` | `[]` | Restrict DNS management to these domains |
| `externaldns.txtOwnerId` | `kubeflow` | Unique TXT record owner ID per cluster |

### Advanced

| Key | Default | Description |
|-----|---------|-------------|
| `_kserveAccess.domain` | `example.com` | Root domain for KServe InferenceService ingress; wired into both `kserve.ingressDomain` and `knativeServing.domain` |
| `dex.existingOidcClientSecret` | `""` | Name of a pre-existing Secret containing the OIDC client secret; overrides `auth.oidc.clientSecret` |
| `dex.resources` | `{requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}` | CPU/memory for the Dex container |
| `user-namespace.pipelines.seaweedfs.accessKey` | (wired from `pipelines.seaweedfs.accessKey`) | SeaweedFS S3 access key injected into every user namespace |
| `user-namespace.pipelines.seaweedfs.secretKey` | (wired from `pipelines.seaweedfs.secretKey`) | SeaweedFS S3 secret key injected into every user namespace |

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
helm upgrade kubeflow oci://stgregistry.suse.com/ai/charts/kubeflow \
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
helm upgrade kubeflow oci://stgregistry.suse.com/ai/charts/kubeflow \
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

### Always use `--force-conflicts`

**OCI (production):**

```bash
helm upgrade kubeflow \
  oci://stgregistry.suse.com/ai/charts/kubeflow \
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

---

## Testing

### Connectivity smoke tests

Runs outside the cluster using `kubectl`. Checks pod health, Deployment readiness, CRDs, Secrets,
TCP service connectivity, SeaweedFS bucket presence, and HTTP health endpoints.

```bash
chmod +x test/smoke/smoke.sh
./test/smoke/smoke.sh
```

### End-to-end tests

Tests a full KFP pipeline run, a Notebook lifecycle, a PyTorchJob, and a KServe InferenceService
prediction. Requires `kubectl` and `curl`.

```bash
chmod +x test/e2e/e2e.sh
./test/e2e/e2e.sh
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
helm upgrade kubeflow oci://stgregistry.suse.com/ai/charts/kubeflow \
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
  the image to a private registry and set `pipelines.seaweedfs.image.registry` to override.
