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

To restore a backup:

```bash
kubectl exec -n kubeflow sts/mysql -- ls /backup/        # list available backups
kubectl exec -n kubeflow sts/mysql -- \
  sh -c "mariadb --ssl=false -u root < /backup/<filename>.sql"
```

### 6. Enable pre-install validation

```yaml
preflightChecks:
  enabled: true
```

Runs a hook Job before install that validates the default StorageClass exists and cert-manager CRDs are
registered.

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

This creates the Profile CR and deploys all required KFP per-namespace resources (pipeline artifact
server, visualization server, credentials, authorization policies) in a single step.

> **Note:** Do not add users by applying a `Profile` CR directly with `kubectl`. The profiles
> controller only creates namespace-level RBAC — it does not deploy the KFP per-namespace resources
> that pipelines depend on. Users added this way will have an incomplete environment and pipeline runs
> will fail.
