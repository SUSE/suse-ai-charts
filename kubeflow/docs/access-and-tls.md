# Accessing Kubeflow & TLS / Configuration Scenarios

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Values Reference](values-reference.md) · [Production Hardening](production-and-tenancy.md#production-hardening)

---

## Accessing Kubeflow

No Helm values change is needed for options A, B, or C.

### Option A — Port-forward (local dev)

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

### Option D — Named hostname (HTTP)

Set a hostname to restrict the gateway to a specific FQDN. TLS is not required. See
[Non-prod: Named hostname over HTTP](#non-prod-named-hostname-over-http).

### Option E — Named hostname with TLS (HTTPS)

See [Non-prod: Self-signed TLS](#non-prod-self-signed-tls) or
[Production: Let's Encrypt TLS + external-dns](#production-lets-encrypt-tls--external-dns).

> **Note:** With Let's Encrypt as the Gateway TLS issuer, `external-dns` is required for DNS-01
> challenges, and a load balancer (e.g. MetalLB) must be used alongside `external-dns` so it can obtain
> the external IP to create the DNS record.

---

## Configuration Scenarios

> **The inference domain has one home: `global.kserve.domain`.** Set it there (not on the subcharts) to
> keep InferenceService URLs on your domain instead of the `example.com` fallback. It is independent of
> the dashboard hostname (`global.gateway.hostname`) — e.g. the dashboard at
> `kubeflow.dev.example.com` while inference hosts become `<name>-<namespace>.models.dev.example.com`.
> To also serve inference over external HTTPS, see
> [External HTTPS for KServe inference](#external-https-for-kserve-inference-opt-in). Full details in
> the [Values Reference](values-reference.md#advanced).

### Non-prod: NodePort access (zero config)

No values override file is needed. Install with defaults and access via NodePort or port-forward (see
[Accessing Kubeflow](#accessing-kubeflow)). Log in as `user@example.com` with the generated password
(the install prints how to read it), or install with `demo-overrides.yaml` for the demo credentials
from [Mode 1](../README.md#mode-1--automated-via-runmesh).

### Non-prod: Named hostname over HTTP

Use this for a stable URL on a shared dev cluster. Point `/etc/hosts` at the cluster IP, or use
external-dns to automate DNS.

```yaml
# my-values.yaml
global:
  gateway:
    hostname: "kubeflow.dev.example.com"
    externalDNS: false
  kserve:
    domain: "models.dev.example.com"   # inference domain — see note above
```

After install, get the cluster IP and add a local DNS entry:

```bash
kubectl get svc istio -n istio-system        # get the external (or node) IP
# /etc/hosts entry (on your local machine or in the cluster)
192.168.1.100  kubeflow.dev.example.com
```

Browse to: http://kubeflow.dev.example.com

### Non-prod: Self-signed TLS

Suitable for shared dev clusters where you can distribute the self-signed CA manually. Requires
cert-manager. The chart creates a self-signed `ClusterIssuer` and requests the `Certificate`
automatically — no `kubectl` steps beyond the Helm install. Add the self-signed CA to your browser
trust store to avoid certificate warnings.

```yaml
# my-values.yaml
global:
  gateway:
    hostname: "kubeflow.dev.example.com"
    externalDNS: false
  tls:
    source: "selfSigned"
    secretName: kubeflow-gateway-tls
    httpsRedirect: true
  kserve:
    domain: "models.dev.example.com"   # inference domain — see note above
```

> The self-signed path can also serve inference over external HTTPS (it issues the wildcard directly,
> so no DNS-01 solver is needed on that path) — see
> [External HTTPS for KServe inference](#external-https-for-kserve-inference-opt-in).

### Production: Let's Encrypt TLS + external-dns

Recommended for internet-facing production. Uses the DNS-01 challenge via Cloudflare, avoiding
HTTP-01 port requirements. Requires a Cloudflare API token with DNS edit access.

```yaml
# prod-values.yaml

# ── Access ──────────────────────────────────────────────────────────────────────
global:
  gateway:
    hostname: "kubeflow.example.com"
    externalDNS: true
  tls:
    source: "letsEncrypt"
    secretName: kubeflow-gateway-tls
    httpsRedirect: true
    letsEncrypt:
      email: "admin@example.com"   # your ACME account email
      server: prod                 # prod | staging (use staging first to test)
      solver: cloudflare           # dns01 via Cloudflare
      cloudflare:
        email: "admin@example.com"
        apiTokenSecretRef:         # created in cert-manager by --cloudflare-api-token
          name: cloudflare-api-token
          key: token
  kserve:
    domain: "models.example.com"   # inference domain — see note above

# external-dns — watches the Istio Gateway and creates/updates DNS records
externaldns:
  enabled: true
  provider:
    name: cloudflare
  # The token comes from the cloudflare-api-token Secret that --cloudflare-api-token creates (or set
  # cloudflare.apiToken and the chart creates it in the kubeflow namespace; one of the two, not both).
  domainFilters:
    - "example.com"
  txtOwnerId: "kubeflow"   # unique per cluster — prevents conflicts
  sources:
    - istio-gateway

# ── Credentials ──────────────────────────────────────────────────────────────────
# Generated on install and kept on upgrade when left empty. To set your own: auth.oidc.clientSecret /
# cookieSecret, auth.initialUser.passwordHash and pipelines.seaweedfs.accessKey / secretKey (README,
# "change-initial-password" for the login).

pipelines:
  mariadb:
    backup:
      enabled: true        # recommended for production
      schedule: "0 2 * * *"
      storageSize: 20Gi

# ── Optional hardening ───────────────────────────────────────────────────────────
networkPolicies:
  enabled: false   # set true when using a CNI that enforces NetworkPolicy (Calico, Cilium, Canal)
monitoring:
  enabled: false   # set true after Rancher Monitoring (kube-prometheus-stack) is installed
```

Install with `runMe.sh`:

```bash
bash ./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> \
  --cloudflare-api-token "<YOUR-CLOUDFLARE-API-TOKEN>" \
  -f prod-values.yaml
```

Or manually (see [Mode 2](../README.md#mode-2--manual-helm-install-oci-recommended-for-production)),
creating the token Secret that external-dns and the DNS-01 solver read (what `--cloudflare-api-token` does):

```bash
for ns in kubeflow cert-manager; do
  kubectl -n "$ns" create secret generic cloudflare-api-token --from-literal=token="<YOUR-CLOUDFLARE-API-TOKEN>" \
    --dry-run=client -o yaml | kubectl apply -f -
done
helm upgrade --install kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version <chart-version> \
  -n kubeflow \
  --force-conflicts --server-side=true \
  --wait --timeout 15m \
  -f prod-values.yaml
```

> **Use `staging` first.** Let's Encrypt rate-limits production certificate issuance. Test with
> `server: staging` until the certificate is issued, then switch to `server: prod` and run
> `helm upgrade` again.

### Production: Bring-your-own certificate

Use this when your organisation manages TLS through an existing PKI or secret manager. Create your TLS
Secret in the `istio-system` namespace before installing:

```bash
kubectl create secret tls my-kubeflow-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n istio-system
```

Then reference it in your values:

```yaml
# prod-values.yaml
global:
  gateway:
    hostname: "kubeflow.example.com"
    externalDNS: false   # manage DNS separately
  tls:
    source: "secret"
    secretName: "my-kubeflow-tls"
    httpsRedirect: true
  kserve:
    domain: "models.example.com"   # inference domain — see note above
    externalHttps: false

# Credentials are generated on install; to set your own, see the Let's Encrypt scenario above.
```

<details>
<summary><strong>Serving KServe inference over HTTPS with a BYO cert</strong></summary>

The chart does not create a cert-manager `Certificate` when `global.tls.source: "secret"` — it uses your
Secret(s) as-is. Unlike the `letsEncrypt`/`selfSigned`/`issuerRef` paths (which issue a *separate*
`kserve-wildcard-tls` cert for inference), the `secret` path wires the dashboard server to
`global.tls.secretName` and the `*.<kserve.domain>` inference server to a **dedicated**
`global.kserve.tls.secretName`. When `global.kserve.externalHttps: true`, `global.kserve.tls.secretName` is
**required** (validation fails fast if empty) and its certificate **must include the
`*.<kserve.domain>` SAN**, or TLS handshakes to inference hosts will fail. If you hold a single
multi-SAN / wildcard cert covering both hosts, point both fields at the same Secret. `urlScheme` and
the domain templates are auto-derived.

```yaml
global:
  gateway:
    hostname: "kubeflow.example.com"           # the APEX — NOT under *.models.example.com
  tls:
    source: "secret"
    secretName: "my-kubeflow-tls"              # dashboard cert (SAN: kubeflow.example.com)
  kserve:
    domain: "models.example.com"
    externalHttps: true
    tls:
      secretName: "my-kserve-wild-tls"         # wildcard cert (SAN: *.models.example.com) —
                                               # a SEPARATE Secret/key from the dashboard cert
```

**<a id="tls-blast-radius"></a>Containing the blast radius (two rules — a distinct domain is NOT one
of them).** The wildcard Secret terminates TLS for every tenant's inference endpoint, so its private
key is a cluster-wide single point of compromise. To contain it:

1. **Scope the wildcard to a dedicated subdomain, not the org-wide apex.** Use `*.models.example.com`
   (`kserve.domain: models.example.com`) rather than dropping an org-wide `*.example.com` key into the
   gateway Secret — a scoped wildcard keeps the blast radius inside the Kubeflow subdomain instead of
   your whole zone.
2. **Keep the dashboard host at the apex, outside the wildcard, on its own Secret.** The apex
   `kubeflow.example.com` is **not** covered by `*.models.example.com`, so it gets a separate cert.
   This is why the chart provisions the dashboard cert separately from `kserve-wildcard-tls`: a
   wildcard-key compromise or a DNS-01 failure on the wildcard cannot take down the dashboard's TLS.
   Reusing one cert for both (a dashboard host *under* the wildcard) collapses that isolation and is
   not recommended.

With these two rules, `hostname` and `kserve.domain` can be the same value — the dashboard sits at the
apex and inference at `*.<same domain>`. **Optional variant (not required for blast radius):** you can
put the dashboard on a *distinct* domain (`hostname: kubeflow.example.com` with
`kserve.domain: models.example.com`). It works equally well and keeps the dashboard even further from
the inference wildcard, but adds no blast-radius protection beyond the two rules above and costs a
second DNS zone to manage.

Whatever cert you bring, restrict RBAC on Secrets in `istio-system` and rotate it independently of any
org-wide certificate. Leave `kserve.externalHttps` false to keep inference on plain HTTP (the dedicated
`kserve-ingress-gateway` serves `:80` only, no wildcard cert).

</details>

> **Inference hostname format.** By default Knative route hosts keep the upstream dotted form
> `{name}.{namespace}.{domain}`. They are only flattened to `{name}-{namespace}.{domain}` when you opt
> into wildcard TLS (`global.kserve.externalHttps: true`). See
> [External HTTPS for KServe inference](#external-https-for-kserve-inference-opt-in) for the full
> caveat, and update DNS records, clients, or certificate SANs accordingly.

### Production: Use existing external-dns and cert-manager

If the environment already has `external-dns` and `cert-manager`, Kubeflow can reuse them provided:

1. `external-dns` is configured to watch the `istio-gateway` source:
   ```bash
   $ kubectl get deployment external-dns -n external-dns -o yaml | grep source=
           - --source=service
           - --source=ingress
           - --source=istio-gateway
   ```
2. A ClusterIssuer exists, configured to issue certificates from a production public CA such as
   Let's Encrypt:
   ```bash
   $ kubectl get clusterissuer
   NAME                     READY   AGE
   letsencrypt-production   True    75m
   ```

Then reference them in your values:

```yaml
# prod-values.yaml
global:
  gateway:
    hostname: "kubeflow.example.com"
    externalDNS: true
  tls:
    source: "issuerRef"
    httpsRedirect: true
    issuerRef:
      name: letsencrypt-production
  kserve:
    domain: "models.example.com"   # inference domain — see note above
externaldns:
  enabled: false

# Credentials are generated on install; to set your own, see the Let's Encrypt scenario above.
```

> **Note:** when adding `istio-gateway` as an `external-dns` source, make sure the Istio CRDs are
> installed. Otherwise the `external-dns` pod may keep crashing with a failure to list Istio gateway
> resources — this error goes away once Istio is installed by Kubeflow.
>
> **Note:** if you use `runMe.sh`, pass `--disable-cert-manager` to skip installing `cert-manager`.

<a id="calling-an-inferenceservice-from-outside-the-cluster"></a>

### Production: TLS terminated in front of the gateway

When a load balancer or reverse proxy in front of the cluster terminates TLS and forwards plain HTTP to
the Istio gateway, set `global.tls.source: edge`:

```yaml
# prod-values.yaml
global:
  gateway:
    hostname: "kubeflow.example.com"
  tls:
    source: "edge"
```

The chart then:

- serves the dashboard host on `:80` only (no certificate, no `:443` server) and **never redirects**
  HTTP to HTTPS: behind a terminator that forwards plain HTTP, a gateway redirect would loop;
- marks the login session cookie and the web apps' CSRF cookie `Secure`, since users browse over HTTPS;
- shows `https://` URLs in the install notes. cert-manager isn't needed for the gateway.

Make the terminator accept only HTTPS from users (or redirect there): the chart can't enforce it.
External HTTPS for KServe inference (`global.kserve.externalHttps`) isn't supported with `edge` yet; the
chart refuses the combination. Use a gateway TLS source for HTTPS inference.

### Calling an InferenceService from outside the cluster

Profile namespaces are Istio-injected, so every KServe predictor runs with a sidecar, and the
profile's `ns-owner-access-istio` policy does not admit requests that arrive through the ingress
gateway and Knative. As in upstream Kubeflow, **each InferenceService that must be callable from
outside the cluster needs its own ALLOW policy** in its namespace. Without it, authenticated callers
get `403 RBAC: access denied`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-sklearn-iris                     # one per InferenceService
  namespace: kubeflow-user-example-com         # the profile namespace
spec:
  action: ALLOW
  rules:
  - {}
  selector:
    matchLabels:
      serving.knative.dev/service: sklearn-iris-predictor   # <inferenceservice>-predictor
```

- **Authentication stays at the gateway.** Requests without a Kubeflow session cookie or a valid
  Dex-issued bearer token are still rejected there (redirect to login / `401`); the policy only lets
  authenticated requests reach this one predictor.
- **Any logged-in user can then call the model**, not only the profile owner — the same as upstream.
  Serve models that must stay private to a profile from inside the cluster instead.
- **Do not narrow it with a `from: namespaces` rule.** Knative's activator calls the predictor pod
  IP without an mTLS identity, so such a rule fails intermittently depending on whether the
  activator is in the request path.
- Calls from inside the same profile (for example a notebook using the predictor's
  `…-private` Service) need no policy.

### External HTTPS for KServe inference (opt-in)

KServe inference always routes through its own **dedicated** `kserve-ingress-gateway`
(`global.kserve.gateway.name`, default `kubeflow/kserve-ingress-gateway`) — separate from the
dashboard's `kubeflow-gateway`. net-istio binds the Knative ingress VirtualServices to this gateway,
so its readiness prober only ever probes that gateway's ports; inference readiness is therefore
**independent of the dashboard's `:443` TLS**.

By default the dedicated gateway serves inference on plain `:80`, and each InferenceService's
`status.url` keeps KServe's default `{name}-{namespace}.{domain}` host over HTTP (behaves exactly as
upstream). Serving inference over external HTTPS is an **opt-in**: set the two globals below and point
the gateway at a TLS issuer, and the chart adds a `*.<kserve.domain>:443` server (plus a `:80`→`:443`
redirect) to the dedicated gateway:

```yaml
# --- KServe external HTTPS opt-in ---
global:
  gateway:
    hostname: "kubeflow.example.com"    # required: the dashboard host (chart fails fast if unset). Keep
                                        # it outside the *.models.example.com wildcard so the dashboard
                                        # gets its own cert.
  tls:
    source: "letsEncrypt"               # or selfSigned / secret / issuerRef (not edge)
    letsEncrypt:
      email: "admin@example.com"
      solver: cloudflare                # DNS-01 required for wildcard certs
      cloudflare:                       # required for the cloudflare DNS-01 solver
        email: "admin@example.com"
        apiTokenSecretRef:
          name: cloudflare-api-token    # must live in cert-manager's namespace
          key: token
  kserve:
    domain: "models.example.com"        # base domain for inference hosts + wildcard cert. Prefer a
                                        # scoped subdomain (models.example.com) over an org-wide domain:
                                        # the wildcard is "*.<kserve.domain>", so a bare domain widens the
                                        # cert's blast radius to your whole zone.
    externalHttps: true                 # the only switch — everything else is auto-derived
```

You **no longer** set `kserve.urlScheme`, `kserve.ingressDomain`, `knativeServing.domain`, or
`knativeServing.domainTemplate` by hand — the chart derives all of them from the two globals:
`urlScheme` becomes `https`, the domains follow `global.kserve.domain`, and the Knative route host is
flattened to the single label `{name}-{namespace}.{domain}` so the wildcard cert covers it. This makes
the dedicated `kserve-ingress-gateway` serve `*.<kserve.domain>` on `:443` using a separate dedicated
certificate (`kserve-wildcard-tls`) — on a separate gateway from the dashboard, so a DNS-01 failure on
the wildcard never takes down the dashboard's TLS. The chart **fails fast at render time** if the
opt-in is incomplete (missing `hostname`, invalid `global.tls.source`, HTTP-01 solver, an unpopulated
cloudflare block, or the bundled oauth2-proxy disabled).

<details>
<summary><strong>Requirements, security model, and caveats (read before enabling)</strong></summary>

- **Requires the bundled oauth2-proxy (`global.oauth2Proxy.enabled: true`, the default).** The
  gateway's authentication (the `authn-filter` ext_authz chain) is only rendered when oauth2-proxy is
  enabled. If you disable it — e.g. to front Kubeflow with your own IdP — the dedicated gateway
  performs **no auth**, so the `*.<kserve.domain>:443` wildcard server would publish **every tenant's
  inference endpoint** unauthenticated. The chart therefore **refuses to render** the wildcard server
  and **fails fast** when `global.kserve.externalHttps: true` is combined with
  `global.oauth2Proxy.enabled: false`. If you run your own gateway auth, keep this opt-in off and
  expose inference through your own authenticated ingress instead.
- **Requires a DNS-01 solver** (`solver: cloudflare`). Let's Encrypt HTTP-01 cannot issue wildcard
  certificates. The `apiTokenSecretRef` Secret must exist in **cert-manager's own namespace** (a
  ClusterIssuer resolves solver secrets there, not in the release namespace). Scope the Cloudflare API
  token to **Zone > DNS > Edit** (plus **Zone > Zone > Read** for zone discovery) on the specific
  zone(s) covering `kserve.domain` / the dashboard host — not "All zones" — so a leaked token can only
  touch those zones.
- **The Knative route host is flattened to `{name}-{namespace}.{domain}`** so a single `*.{domain}`
  wildcard covers them (Let's Encrypt cannot issue a `*.*.{domain}` two-level wildcard). Knative and
  KServe render this host with Go's stdlib `text/template` — **not** Helm/Sprig — so the namespace
  **cannot** be hashed in the template.
- **This opt-in is single-tenant-first — do NOT enable it on an untrusted multi-tenant cluster.**
  Because name and namespace are joined by `-` into one DNS label, two different `(name, namespace)`
  pairs collapse to the same host (e.g. `victim-team` in namespace `alpha` and `victim` in namespace
  `team-alpha` both yield `victim-team-alpha.{domain}`; likewise name `a`/ns `b-c` vs name `a-b`/ns
  `c` → `a-b-c`). Istio resolves the clash **oldest-VirtualService-wins**, so a tenant who can create
  an InferenceService in *any* namespace can hijack or deny another tenant's inference host by picking
  a colliding **name** — and the attacker chooses the name, so admin-provisioned namespaces do **not**
  bound this. Enable the wildcard opt-in only when every namespace that can host an InferenceService is
  trusted (single tenant, or mutually-trusting teams), and avoid namespace names that are dash-suffixes
  of other tenants' `{name}-{namespace}` hosts. For strict per-namespace isolation on an untrusted
  cluster, keep inference cluster-local (leave this opt-in off) or issue a `*.{namespace}.{domain}`
  cert per namespace with the dotted `{name}.{namespace}.{domain}` host form.
- **The gateway authenticates but does NOT authorize per tenant — any authenticated user can invoke
  any InferenceService.** The ext_authz chain checks that the caller has a valid Dex session / Bearer
  token; it does **not** check that the caller owns the model's namespace. There is no gateway-scoped
  `AuthorizationPolicy` binding `*.<kserve.domain>` hosts to their owning namespace, the Knative
  `activator`'s `AuthorizationPolicy` is allow-all (`rules: [{}]`), and oauth2-proxy accepts any domain
  (`email_domains: ["*"]`). Verified manually with a two-user test: a token for **any** Dex user is
  accepted at **every** tenant's inference host, regardless of which namespace owns the model. This is
  fine for a single tenant or mutually-trusting teams, but on an untrusted multi-tenant cluster one
  tenant can invoke — and read the outputs of — another tenant's models. For per-tenant invocation
  isolation, keep this opt-in off (reach inference cluster-local, where namespace-scoped
  `AuthorizationPolicy`/`NetworkPolicy` still apply) or add your own gateway-scoped
  `AuthorizationPolicy` binding each `*.<kserve.domain>` host to its namespace.
- **The flattened label must stay under 63 characters** — DNS limits any single label to 63 chars.
  Note the Knative **route host** that needs the wildcard cert is the *component* Knative Service, not
  the InferenceService: a serverless predictor routes as `{isvc}-predictor-{namespace}` (and
  `-transformer` / `-explainer` for those components), so budget for the ~10-char `-predictor` suffix.
  Long InferenceService or namespace names can exceed the limit.
- **External access requires a Bearer token or session cookie.** Serving over HTTPS does not bypass
  Kubeflow's authentication. See the
  [Tutorial — Programmatic Access](../tutorial.md#programmatic--external-access-bearer-token) for
  authenticating external `curl` or Python clients.
- **BYO cert path differs** — see [Serving KServe inference over HTTPS with a BYO cert](#production-bring-your-own-certificate)
  and the [blast-radius rules](#tls-blast-radius).
- Leave `kserve.externalHttps` false (default) to keep inference on plain HTTP: the dedicated
  `kserve-ingress-gateway` serves `:80` only (no wildcard cert, no `:443`). `status.url` is unchanged —
  still KServe's `{name}-{namespace}.{domain}` host over HTTP.

</details>

---

## Ingress gateway authentication mode

All browser traffic enters through the shared Istio ingress gateway, which enforces OIDC login via
oauth2-proxy and Dex. The chart ships **two interchangeable implementations** of that gateway auth,
selected by `global.oauth2Proxy.gatewayAuthMode`:

| Mode | Value | How it works | When to use |
|------|-------|--------------|-------------|
| **Native** (default) | `native` | Upstream-parity Istio-native ext_authz: a `RequestAuthentication` (Dex JWT) plus two `AuthorizationPolicy` resources (a `CUSTOM` ext_authz to oauth2-proxy and a `DENY` require-jwt) on the ingress gateway. Requires istiod's MeshConfig to register the `oauth2-proxy` extension provider. | Default. Matches upstream Kubeflow; least custom Envoy config. |
| **EnvoyFilter** (legacy) | `envoyfilter` | A single self-contained `EnvoyFilter` (Lua + ext_authz chain) on the gateway. Needs **no** istiod MeshConfig change. | BYO / managed Istio control plane whose MeshConfig you cannot modify. |

The two modes are **mutually exclusive** — the chart renders exactly one set of resources, driven by
`global.oauth2Proxy.gatewayAuthMode`. The only two-sided prerequisite is on the istio install: native
mode needs the MeshConfig extension provider there. The `-f values-envoyfilter-authz.yaml` overlay (in the chart) just
flips `gatewayAuthMode` to `envoyfilter`, which both renders the EnvoyFilter and drops the oauth2-proxy
`/dex/` skip_auth_routes (the base config emits that skip only in native mode; in envoyfilter mode the
EnvoyFilter's own Lua handles the /dex,/oauth2 skip, so oauth2-proxy must not also skip it).

> **External IdP integration is independent of this choice.** Both modes authenticate
> via oauth2-proxy → Dex, so federating to a corporate LDAP/OIDC/SAML provider through
> `dex.config.connectors` works identically in either mode — the mode only changes how the
> gateway *enforces* that a request is authenticated, not who issues the identity. See
> [Production Hardening & Multi-tenancy](production-and-tenancy.md) for external IdP setup.

**Selecting native (default) — nothing extra beyond Step 6's `-f istio-native-authz-values.yaml` in the [manual install](../README.md#mode-2--manual-helm-install-oci-recommended-for-production):**

```bash
# runMe.sh does this automatically. Manual install: pass the istiod extension-provider
# values to the ISTIO install (Step 6), then install Kubeflow normally (Step 8).
```

**Selecting the legacy EnvoyFilter mode:**

```bash
# runMe.sh:
bash ./runMe.sh <appco-user> <appco-token> regcode <suse-ai-token> --legacy-authz

# Manual install (README, Mode 2): skip -f istio-native-authz-values.yaml in Step 6, and add
# the overlay to the Kubeflow install in Step 8:
helm upgrade --install kubeflow oci://registry.suse.com/ai/charts/kubeflow ... \
  -f kubeflow/values-envoyfilter-authz.yaml   # from the chart pulled in Step 1
```

> **Fail-closed guard:** in native mode the chart includes a `native-authz-guard` template that fails
> the install fast (with remediation steps) if istiod's MeshConfig is missing the `oauth2-proxy`
> extension provider — preventing a silent lockout of all ingress. The guard uses `lookup`, so it is
> inert during `helm template` / `--dry-run` and only enforces on a live cluster.

> **⚠ Limitation — cookie-less external KServe inference on the shared gateway is denied in native
> mode.** The native `require-jwt` `DENY` policy selects the **shared** ingress gateway and denies any
> request without a verified JWT request-principal on all paths except `/dex/*` and `/oauth2/*`. A
> cookie-less external inference `POST` to a KServe `InferenceService` served on that same gateway
> therefore gets a `403`. This is a **behavior change** versus the legacy EnvoyFilter mode, and native
> is now the default. **KServe in-cluster traffic is unaffected** — it uses the dedicated cluster-local
> gateway (`kserve-ingress-gateway`), not the shared ingress gateway. If you rely on external,
> unauthenticated inference over the shared gateway, either use the dedicated KServe gateway / wildcard-
> TLS path (see [External HTTPS for KServe inference](#external-https-for-kserve-inference-opt-in))
> or select the legacy EnvoyFilter mode. Combining native authz with the KServe wildcard-TLS opt-in
> must be scoped and verified first. See [Upgrade Notes](upgrade-notes.md).

> **Path-normalization dependency.** The `/dex/*` and `/oauth2/*` exemptions on the native policies
> rely on Istio's HTTP path normalization (`MeshConfig.pathNormalization`) to prevent evasion of the
> `DENY` via encoded/duplicated slashes (e.g. `//dex/..%2f`). This posture is inherited from upstream
> Kubeflow community-distribution; if your mesh disables slash normalization/merging, treat the
> exemptions as a theoretical bypass surface and confirm your `pathNormalization` setting.

The single source of truth for the gateway **identity** consumed by these resources is
`global.istio.ingressGateway.{principal,selector}` (Rancher/AppCo Istio by default; override
`selector.istio` to `ingressgateway` and `principal` to the upstream service account for upstream
Istio).
