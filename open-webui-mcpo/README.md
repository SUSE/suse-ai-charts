# Open WebUI mcpo

`mcpo` is a dead-simple proxy that takes an MCP server command and makes it accessible via standard RESTful OpenAPI, so your tools "just work" with LLM agents and apps expecting OpenAPI servers.

**Homepage:** <https://apps.rancher.io/applications/open-webui-mcpo>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| SUSE LLC |  | <https://www.suse.com> |


## Prerequisites

- Kubernetes 1.16+
- Helm 3.2.0+

## Installing the Chart

To install the chart with the release name `open-webui-mcpo`:

```bash
helm install open-webui-mcpo \
--set 'global.imagePullSecrets[0].name'=my-pull-secrets \
oci://dp.apps.rancher.io/charts/open-webui-mcpo
```

The command deploys the mcpo proxy on the Kubernetes cluster in the default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

## Uninstalling the Chart

To uninstall/delete the `open-webui-mcpo` deployment:

```bash
helm delete open-webui-mcpo
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Parameters

### Global parameters

| Name                | Description                                   | Value |
| ------------------- | --------------------------------------------- | ----- |
| `replicaCount`      | Number of open-webui-mcpo replicas to deploy             | `1`   |
| `nameOverride`      | String to partially override open-webui-mcpo.fullname    | `""`  |
| `fullnameOverride`  | String to fully override open-webui-mcpo.fullname        | `""`  |

### Image parameters

| Name               | Description                                | Value                        |
| ------------------ | ------------------------------------------ | ---------------------------- |
| `image.registry`   | open-webui-mcpo image registry                        | `dp.apps.rancher.io`         |
| `image.repository` | open-webui-mcpo image repository                      | `containers/open-webui-mcpo` |
| `image.tag`        | open-webui-mcpo image tag (immutable tags recommended)| `0.0.17`                     |
| `image.pullPolicy` | open-webui-mcpo image pull policy                     | `IfNotPresent`               |
| `imagePullSecrets` | open-webui-mcpo image pull secrets                    | `[]`                         |
| `global.imagePullSecrets` | Global override for container image registry pull secrets |`[]`    |
| `global.imageRegistry` | Global override for container image registry | `""`                   |


### Service Account parameters

| Name                         | Description                             | Value |
| ---------------------------- | --------------------------------------- | ----- |
| `serviceAccount.create`      | Specifies whether a service account should be created | `true` |
| `serviceAccount.annotations` | Annotations to add to the service account | `{}`   |
| `serviceAccount.name`        | The name of the service account to use | `""`   |

### Service parameters

| Name           | Description             | Value       |
| -------------- | ----------------------- | ----------- |
| `service.type` | open-webui-mcpo service type       | `ClusterIP` |
| `service.port` | open-webui-mcpo service HTTP port  | `8000`      |

### Ingress parameters

| Name                  | Description                                              | Value |
| --------------------- | -------------------------------------------------------- | ----- |
| `ingress.enabled`     | Enable ingress record generation for open-webui-mcpo                | `false` |
| `ingress.className`   | IngressClass that will be used to implement the Ingress   | `""`    |
| `ingress.annotations` | Additional annotations for the Ingress resource          | `{}`    |
| `ingress.path` | Base path for the service | `/` |
| `ingress.pathType` | Path matching behavior | `Prefix` |
| `ingress.hosts` | List of hostnames | `["open-webui-mcpo.local"]` |
| `ingress.tls`         | TLS configuration for ingress | `[]` |

When `ingress.path` is not `/`, the annotation `nginx.ingress.kubernetes.io/use-regex: "true"` is automatically added.

### Environment variables

| Name         | Description                                          | Value |
| ------------ | ---------------------------------------------------- | ----- |
| `env`        | Environment variables to be set on the container    | `{}`  |
| `envSecrets` | Environment variables from external secrets         | `{}`  |
| `secretEnv`  | Environment variables to be set from created secret | `{}`  |

### Configuration file

| Name      | Description                                         | Value |
| --------- | --------------------------------------------------- | ----- |
| `config`  | Structure used to generate `config.json`            | `see values.yaml` |

Default `config` structure:

```yaml
mcpServers:
  memory:
    command: npx
    args:
      - -y
      - "@modelcontextprotocol/server-memory"
```

See the commented example in `values.yaml` for a more complete configuration with
additional MCP servers.

### Autoscaling parameters

| Name                                            | Description                              | Value |
| ----------------------------------------------- | ---------------------------------------- | ----- |
| `autoscaling.enabled`                           | Enable Horizontal Pod Autoscaler (HPA)   | `false` |
| `autoscaling.minReplicas`                       | Minimum number of open-webui-mcpo replicas          | `1` |
| `autoscaling.maxReplicas`                       | Maximum number of open-webui-mcpo replicas          | `100` |
| `autoscaling.targetCPUUtilizationPercentage`    | Target CPU utilization percentage        | `80` |
| `autoscaling.targetMemoryUtilizationPercentage` | Target Memory utilization percentage     | `""` |

## Configuration and installation details

mcpo proxies another MCP server. The chart mounts a `config.json` file from a
ConfigMap and starts the container with `--config /opt/mcpo/config.json`.
`config.json` is generated from the `config` values found in `values.yaml`. The
default configuration defines a single MCP server, but you can customize this to
define multiple servers by editing the `config` section.

### Exposing the application

To access the mcpo server from outside the cluster, you can:

1. **Use port forwarding** (for development):

   ```bash
   kubectl port-forward svc/mcpo 8000:8000
   ```

2. **Enable ingress** (for production):

   ```yaml
   ingress:
     enabled: true
     className: "nginx"
     path: /
     hosts:
       - open-webui-mcpo.your-domain.com
   ```

3. **Use LoadBalancer service type**:

   ```yaml
   service:
     type: LoadBalancer
   ```

## Troubleshooting

### Check pod status

```bash
kubectl get pods -l app.kubernetes.io/name=mcpo
```

### Check logs

```bash
kubectl logs -l app.kubernetes.io/name=mcpo
```

### Test connection

```bash
helm test open-webui-mcpo
```
