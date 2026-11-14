# Production Hardening & Multi-tenancy

[← Back to README](../README.md) · Related: [Accessing & TLS](access-and-tls.md) · [Values Reference](values-reference.md) · [Upgrade Notes](upgrade-notes.md)

---

## Production Hardening

The chart ships with demo defaults that are **not suitable for production**. Address these before
exposing the deployment to any network or storing sensitive data.

By default (`global.demoMode: false`) the chart **fails at render time** with a `SECURITY:` error if
any well-known demo credential is still present. To suppress this during local development, set
`global.demoMode: true` — never set this in production.

### 1. Change all default credentials

The credentials that trigger the render-time security check:

```yaml
# In your values override file
auth:
  oidc:
    clientSecret: "<STRONG-RANDOM-SECRET>"
    cookieSecret: "<STRONG-RANDOM-32-BYTE-BASE64>"  # generate: openssl rand -base64 32 | tr -- '+/' '-_'

dex:
  config:
    staticClients:
      - id: kubeflow-oidc-authservice
        redirectURIs:
          - /oauth2/callback
        name: kubeflow-oidc-authservice
        secretEnv: KUBEFLOW_OIDC_CLIENT_SECRET   # read from the kubeflow-oidc-client Secret; set auth.oidc.clientSecret, not this
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

> **Rotating the OIDC secrets:** `auth.oidc.clientSecret` and `auth.oidc.cookieSecret` are stored
> in the `kubeflow-oidc-client` Secret, which Dex and oauth2-proxy read at start-up. After changing
> them on an existing installation, restart both so they load the new values together (this also
> signs every user out):
> ```bash
> kubectl -n kubeflow rollout restart deploy/kubeflow-dex deploy/kubeflow-oauth2-proxy
> ```

> **MariaDB root passwords:** Both the KFP and Katib MySQL secrets are **auto-generated** (24-char
> random password) on first install and preserved across upgrades — no action required. To rotate,
> delete the secret and run `helm upgrade` to regenerate:
> ```bash
> kubectl delete secret mysql-secret -n kubeflow        # KFP
> kubectl delete secret katib-mysql-secrets -n kubeflow # Katib
> helm upgrade kubeflow . -f my-values.yaml -n kubeflow
> ```

### 2. Use an external identity provider

Replace Dex static passwords with an LDAP, SAML, or upstream OIDC connector. Add a `connectors` block
to `dex.config` and remove `staticPasswords` + `enablePasswordDB: true`.

### 3. NetworkPolicies

NetworkPolicies are **disabled by default**. They use an ingress-only deny-by-default model — egress is
unrestricted so components can reach external services (HuggingFace, container registries, etc.).
Supported by Calico, Cilium, Canal, and any other CNI that enforces NetworkPolicy. Disable if your CNI
does not enforce NetworkPolicy.

```yaml
networkPolicies:
  enabled: true
```

### 4. Enable TLS

See [Production: Let's Encrypt TLS + external-dns](access-and-tls.md#production-lets-encrypt-tls--external-dns)
or [Production: Bring-your-own certificate](access-and-tls.md#production-bring-your-own-certificate).

### 5. Enable database backups

```yaml
pipelines:
  mariadb:
    backup:
      enabled: true
      schedule: "0 2 * * *"   # daily at 02:00 UTC
      storageSize: 20Gi
```

This dumps the KFP databases (`mlpipeline`, `metadb`) as `kubeflow_<timestamp>.sql.gz` to PVC
`mariadb-backup-pvc`. Model Registry databases are not included; back them up separately. With
`networkPolicies.enabled`, make sure the restore pod below may reach `mysql`.

To take a backup now, list backups, or restore one (stop pipeline runs first):

```bash
kubectl create job -n kubeflow --from=cronjob/mariadb-backup mariadb-backup-manual   # backup now

# Shell with the backups mounted, using the backup job's image, pull secret and credentials
JOB='{.spec.jobTemplate.spec.template.spec'
IMG=$(kubectl get cronjob mariadb-backup -n kubeflow -o jsonpath="$JOB.containers[0].image}")
PULL=$(kubectl get cronjob mariadb-backup -n kubeflow -o jsonpath="$JOB.imagePullSecrets[0].name}")
kubectl run mariadb-restore -n kubeflow --rm -it --restart=Never --image="$IMG" \
  --annotations=sidecar.istio.io/nativeSidecar=true --overrides='{"spec":{
  "imagePullSecrets":[{"name":"'"$PULL"'"}],
  "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"fsGroup":1000},
  "volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"mariadb-backup-pvc"}}],
  "containers":[{"name":"mariadb-restore","image":"'"$IMG"'","stdin":true,"tty":true,"command":["sh"],
    "env":[{"name":"MYSQL_PWD","valueFrom":{"secretKeyRef":{"name":"mysql-secret","key":"password"}}}],
    "volumeMounts":[{"name":"backup","mountPath":"/backup"}]}]}}'

# Inside that shell:
ls -t /backup/
gunzip -c /backup/kubeflow_<timestamp>.sql.gz | mariadb -h mysql -u root --ssl=false
```

### 6. Enable pre-install validation

```yaml
preflightChecks:
  enabled: true
```

Runs a hook Job before install that validates the default StorageClass exists, cert-manager CRDs are
registered, and Istio CNI matches `global.istio.cni` (see [Pod Security Standards on profile
namespaces](#9-pod-security-standards-on-profile-namespaces)).

### 7. Enable High Availability

Apply `ha-overrides.yaml` (provided in the repo) on top of your base values to scale the Katib
controller, training-operator, and KServe controller to 2 replicas. KFP and Dex PodDisruptionBudgets
are already enabled by default.

```bash
helm upgrade kubeflow . -f <your-values>.yaml -f ha-overrides.yaml -n kubeflow
```

> PDBs protect against voluntary disruptions (node drains) but only provide meaningful coverage with
> 2+ replicas. With a single replica, the PDB allows full eviction. See
> [Known Limitations](troubleshooting.md#known-limitations) for which controllers support HA.

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


<a id="pod-security-standards-on-profile-namespaces"></a>

### 9. Pod Security Standards on profile namespaces

With `global.istio.cni: true` (the default), every profile namespace enforces the Kubernetes
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
`baseline` level (`pod-security.kubernetes.io/enforce: baseline`), as upstream Kubeflow does: pods
that request privileged mode, host namespaces, `hostPath` volumes or extra capabilities are rejected.
This needs Istio installed **with the istio-cni plugin** — without it, every meshed pod carries the
`istio-init` container, which needs `NET_ADMIN`/`NET_RAW` and would be rejected.

| | `global.istio.cni: true` (default) | `global.istio.cni: false` |
|---|---|---|
| Istio install | with istio-cni (`runMe.sh` default, `istio-cni-values.yaml`) | classic `istio-init` (`runMe.sh --no-istio-cni`) |
| User pods | no privileged init container | `istio-init` with `NET_ADMIN`/`NET_RAW` |
| Profile namespaces | `istio-injection: enabled` + PSS `enforce: baseline` | `istio-injection: enabled` |

The label is set on namespaces the chart creates (example profile, `additionalUsers[]`) and through
the profile controller on profiles created at runtime (including `extraNamespaces`). If
`cni: true` and istiod runs in `istio-system` (including a revisioned `istiod-<rev>`) but no
`istio-cni-node` DaemonSet exists in any namespace (or istiod's injector has
`pilot.cni.enabled: false`), `helm install` / `helm upgrade` fails with an explanatory error. Renders with `helm template` cannot see the cluster: set `global.istio.cni`
explicitly, or enable `preflightChecks.enabled` if your tool runs Helm hooks before other resources.
Switching `cni` from `true` to `false` needs a one-time label clean-up
([upgrade notes](upgrade-notes.md#istio-cni)).

**Security trade-off when running without CNI (`global.istio.cni: false`).** Profile namespaces are
still labelled `istio-injection: enabled` (as upstream's profile controller does), so every pod in
them — notebooks, pipeline steps, model servers — joins the mesh and starts with the `istio-init`
container, which holds the `NET_ADMIN` and `NET_RAW` capabilities. That buys mTLS and
AuthorizationPolicy enforcement for user workloads, but it also means user-controlled pods run a
container with network-administration privileges, and no Pod Security level is enforced on the
namespace. Prefer Istio with CNI wherever the platform supports it; use `false` only where it does
not.

---

## Multi-tenancy

Kubeflow uses a Profile-per-user model. The `kubeflow-user-example-com` namespace is the default user
namespace created at install time.

### Adding users at install time

```yaml
# my-values.yaml
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

> **Important:** The `namespace` field is optional but strongly recommended. Without it, the namespace
> is auto-generated from the email by replacing `@` with `--` and `.` with `-`. Emails that differ only
> by `.` vs `-` (e.g. `alice.smith@corp.com` and `alice-smith@corp.com`) produce the same
> auto-generated slug — use an explicit `namespace` to disambiguate.

### Adding users after install

Add the user to your values file and run `helm upgrade`:

```bash
# OCI (production)
helm upgrade kubeflow oci://registry.suse.com/ai/charts/kubeflow \
  --version <version> \
  -n kubeflow -f my-values.yaml

# From source (development)
helm upgrade kubeflow -n kubeflow --force-conflicts -f my-values.yaml .
```

This creates the Profile and namespace and the user's own Model Registry (server + Postgres) in a
single step. Gateway access comes from the profiles controller's `ns-owner-access-istio`
AuthorizationPolicy (see the note below). The KFP per-namespace resources (the profile's own
artifact-store credentials, the launcher and artifact-repository ConfigMaps, and authorization
policies; the per-profile artifact proxy only with `pipelines.artifacts.proxyEnabled`) are then
created automatically by the KFP profile controller, as upstream, for every profile namespace labelled
`pipelines.kubeflow.org/enabled=true` (the profiles controller sets that label).

> **Note:** A profile created with `kubectl` (or the dashboard registration flow) gets the same
> namespace setup as one from `additionalUsers`: the profiles controller creates RBAC and the
> `ns-owner-access-istio` AuthorizationPolicy (admitting the gateway principal from
> `global.istio.ingressGateway.principal`), and the KFP profile controller creates the KFP resources.
> The one difference is the Model Registry: list the namespace in
> `user-namespace.modelRegistry.extraNamespaces` and run `helm upgrade` to get one.
