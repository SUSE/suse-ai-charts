#!/usr/bin/env bash
# Tier 2 Smoke Tests — Kubeflow Helm Chart
# =========================================
# Runs from the host (outside the cluster) using kubectl.
# Prerequisites: kubectl configured and pointing at your cluster.
#
# Usage:
#   chmod +x test/smoke/smoke.sh
#   ./test/smoke/smoke.sh
#
# Exit code: 0 = all passed, 1 = one or more failures.

set -uo pipefail

NS=kubeflow
USER_NS=kubeflow-user-example-com
SUSE_REGISTRY=stgregistry.suse.com        # override with --suse-registry=
SUSE_APP_COLLECTION=dp.apps.rancher.io  # override with --suse-app-collection=

for arg in "$@"; do
  case "$arg" in
    --user-namespace=*)       USER_NS="${arg#*=}" ;;
    --suse-registry=*)        SUSE_REGISTRY="${arg#*=}" ;;
    --suse-app-collection=*)  SUSE_APP_COLLECTION="${arg#*=}" ;;
  esac
done

PASS=0
FAIL=0
WARNINGS=0

# ── colour helpers ─────────────────────────────────────────────────────────────
green() { printf '\033[32m  ✓  %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗  %s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m  ⚠  %s\033[0m\n' "$*"; }
header(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

pass()    { green "$1";  ((PASS++))     || true; }
fail()    { red "$1";    ((FAIL++))     || true; }
warn()    { yellow "$1"; ((WARNINGS++)) || true; }

# ── helpers ────────────────────────────────────────────────────────────────────

# Check that a kubectl resource exists
check_resource() {
  local kind="$1" name="$2" ns="${3:-$NS}"
  if kubectl get "$kind" "$name" -n "$ns" &>/dev/null; then
    pass "$kind/$name exists in $ns"
  else
    fail "$kind/$name missing in $ns"
  fi
}

# Check that a CRD exists
check_crd() {
  local crd="$1"
  if kubectl get crd "$crd" &>/dev/null; then
    pass "CRD $crd registered"
  else
    fail "CRD $crd missing"
  fi
}

# Check that a deployment has at least N ready replicas
check_deploy_ready() {
  local name="$1" ns="${2:-$NS}" min="${3:-1}"
  local ready
  ready=$(kubectl get deploy "$name" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  ready=${ready:-0}
  if [ "$ready" -ge "$min" ]; then
    pass "Deployment $name ready ($ready/$min)"
  else
    fail "Deployment $name not ready ($ready/$min replicas)"
  fi
}

# Check that a statefulset has at least N ready replicas
check_sts_ready() {
  local name="$1" ns="${2:-$NS}" min="${3:-1}"
  local ready
  ready=$(kubectl get sts "$name" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  ready=${ready:-0}
  if [ "$ready" -ge "$min" ]; then
    pass "StatefulSet $name ready ($ready/$min)"
  else
    fail "StatefulSet $name not ready ($ready/$min replicas)"
  fi
}

# HTTP health check via a temporary kubectl run pod (no port-forward needed)
check_http() {
  local label="$1" url="$2"
  local result

  if result=$(kubectl run "smoke-http-$$" \
        --image=${SUSE_APP_COLLECTION}/containers/bci-busybox:15.7 \
        --restart=Never \
        --rm \
        --attach \
        -n "$NS" \
        --overrides='
{
  "metadata": {
    "annotations": {
      "sidecar.istio.io/nativeSidecar": "true"
    }
  },
  "spec": {
    "imagePullSecrets": [
      { "name": "application-collection" }
    ]
  }
}' \
        --command -- \
        wget -qO- --timeout=10 "$url" 2>/dev/null); then
    pass "HTTP $label ($url)"
  else
    fail "HTTP $label ($url)"
  fi
}

# TCP connectivity check via a temporary pod
check_tcp() {
  local label="$1" host="$2" port="$3"
  if kubectl run "smoke-tcp-$$" \
      --image=${SUSE_APP_COLLECTION}/containers/bci-busybox:15.7 \
      --restart=Never \
      --rm \
      --attach \
      -n "$NS" \
      --overrides='
{
  "metadata": {
    "annotations": {
      "sidecar.istio.io/nativeSidecar": "true"
    }
  },
  "spec": {
    "imagePullSecrets": [
      { "name": "application-collection" }
    ]
  }
}' \
      --command -- \
      nc -zw 5 "$host" "$port" &>/dev/null; then
    pass "TCP $label ($host:$port)"
  else
    fail "TCP $label ($host:$port)"
  fi
}

# ── count pods in bad state ────────────────────────────────────────────────────
count_bad_pods() {
  local ns="$1"
  kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '{print $3}' \
    | grep -E "^(Error|CrashLoopBackOff|OOMKilled|CreateContainerConfigError|ImagePullBackOff|ErrImagePull|Terminating|Evicted)$" \
    | wc -l \
    | tr -d ' '
}

# ── SeaweedFS S3 bucket check ──────────────────────────────────────────────────
check_seaweedfs_bucket() {
  local bucket="$1"
  # Use weed shell via kubectl exec — S3 API requires auth after IAM is configured.
  # weed shell connects to the master gRPC port (9333) which does not require S3 auth.
  if kubectl exec -n "$NS" deploy/seaweedfs -- \
      sh -c "printf 's3.bucket.list\n' | weed shell -master 127.0.0.1:9333 2>&1 | grep -q '${bucket}'"; then
    pass "SeaweedFS bucket '$bucket' accessible"
  else
    fail "SeaweedFS bucket '$bucket' not accessible"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
header "━━━ Tier 2 Smoke Tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
header "Namespace: $NS   |   $(date '+%Y-%m-%d %H:%M:%S')"

# ── Section 1: Pod health ──────────────────────────────────────────────────────
header "1. Pod health — namespace: $NS"

bad=$(count_bad_pods "$NS")
if [ "$bad" -eq 0 ]; then
  pass "No pods in error state in $NS"
else
  fail "$bad pod(s) in error state in $NS — run: kubectl get pods -n $NS"
fi

bad=$(count_bad_pods "$USER_NS")
if [ "$bad" -eq 0 ]; then
  pass "No pods in error state in $USER_NS"
else
  fail "$bad pod(s) in error state in $USER_NS — run: kubectl get pods -n $USER_NS"
fi

# ── Section 2: Key deployments ready ──────────────────────────────────────────
header "2. Key deployments ready"

check_deploy_ready "ml-pipeline"
check_deploy_ready "ml-pipeline-ui"
check_deploy_ready "ml-pipeline-persistenceagent"
check_deploy_ready "ml-pipeline-scheduledworkflow"
check_deploy_ready "kubeflow-central-dashboard"
check_deploy_ready "katib-controller"
check_deploy_ready "katib-db-manager"
check_deploy_ready "katib-mysql"
check_deploy_ready "profiles-deployment"
check_deploy_ready "notebook-controller-deployment"
check_deploy_ready "training-operator"
if kubectl get deploy kubeflow-trainer-controller-manager -n "$NS" &>/dev/null; then
  check_deploy_ready "kubeflow-trainer-controller-manager"
fi
check_deploy_ready "volumes-web-app-deployment"
check_deploy_ready "tensorboard-controller-deployment"
check_deploy_ready "jupyter-web-app-deployment"
check_deploy_ready "kserve-controller-manager"

if kubectl get deploy model-registry-deployment -n "$NS" &>/dev/null; then
  check_deploy_ready "model-registry-deployment"
  check_deploy_ready "model-registry-ui"
fi
if kubectl get deploy model-registry-controller -n "$NS" &>/dev/null; then
  check_deploy_ready "model-registry-controller"
fi

# ── Section 3: Key StatefulSets ready ─────────────────────────────────────────
header "3. StatefulSets ready"

check_sts_ready "mysql"      # KFP MariaDB (fullnameOverride: mysql)

# ── Section 4: CRDs registered ────────────────────────────────────────────────
header "4. CRDs"

check_crd "experiments.kubeflow.org"
check_crd "trials.kubeflow.org"
check_crd "suggestions.kubeflow.org"
check_crd "scheduledworkflows.kubeflow.org"
check_crd "pytorchjobs.kubeflow.org"
check_crd "tfjobs.kubeflow.org"
check_crd "inferenceservices.serving.kserve.io"
check_crd "servingruntimes.serving.kserve.io"
check_crd "clusterservingruntimes.serving.kserve.io"
check_crd "notebooks.kubeflow.org"
check_crd "pvcviewers.kubeflow.org"
check_crd "profiles.kubeflow.org"
if kubectl get deploy kubeflow-trainer-controller-manager -n "$NS" &>/dev/null; then
  check_crd "trainjobs.trainer.kubeflow.org"
  check_crd "trainingruntimes.trainer.kubeflow.org"
  check_crd "clustertrainingruntimes.trainer.kubeflow.org"
  check_crd "jobsets.jobset.x-k8s.io"
fi

# ── Section 5: Key Secrets / ConfigMaps ───────────────────────────────────────
header "5. Secrets and ConfigMaps"

check_resource secret mysql-secret
check_resource secret katib-mysql-secrets
check_resource secret kubeflow-dex
check_resource configmap katib-config
check_resource configmap workflow-controller-configmap
check_resource configmap inferenceservice-config
check_resource configmap config-domain knative-serving

# Verify config-domain has a domain key configured (non-empty data)
DOMAIN_KEY=$(kubectl get cm config-domain -n knative-serving \
  -o jsonpath='{.data}' 2>/dev/null | grep -o '"[^"]*":' | head -1 | tr -d '":')
if [[ -n "$DOMAIN_KEY" ]]; then
  pass "config-domain has domain key: $DOMAIN_KEY"
else
  warn "config-domain has no domain key — InferenceService URLs may be broken"
fi

# Verify inferenceservice-config has the correct ingressService name
INGRESS_SVC=$(kubectl get cm inferenceservice-config -n kubeflow \
  -o jsonpath='{.data.ingress}' 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ingressService',''))" 2>/dev/null || echo "")
if [[ "$INGRESS_SVC" == "istio.istio-system.svc.cluster.local" ]]; then
  pass "KServe ingressService: $INGRESS_SVC"
else
  fail "KServe ingressService wrong: '$INGRESS_SVC' (expected istio.istio-system.svc.cluster.local)"
fi

# Auto-generated passwords must be non-empty (lookup+randAlphaNum pattern — empty means generation failed)
pw=$(kubectl get secret mysql-secret -n "$NS" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
[ -n "$pw" ] && pass "mysql-secret password is non-empty" \
             || fail "mysql-secret password is empty — auto-generation may have failed"

pw=$(kubectl get secret katib-mysql-secrets -n "$NS" \
  -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' 2>/dev/null | base64 -d)
[ -n "$pw" ] && pass "katib-mysql-secrets password is non-empty" \
             || fail "katib-mysql-secrets password is empty — auto-generation may have failed"

# ── Section 6: Service connectivity (TCP) ─────────────────────────────────────
header "6. Service connectivity (TCP)"

check_tcp "KFP API"              "ml-pipeline.${NS}.svc.cluster.local"        8888
check_tcp "Central Dashboard"    "kubeflow-central-dashboard.${NS}.svc.cluster.local"   80
check_tcp "Dex"                  "kubeflow-dex.${NS}.svc.cluster.local"        5556
check_tcp "oauth2-proxy"         "kubeflow-oauth2-proxy.${NS}.svc.cluster.local"        80
check_tcp "SeaweedFS S3"         "seaweedfs.${NS}.svc.cluster.local"           9000
check_tcp "Katib DB Manager"     "katib-db-manager.${NS}.svc.cluster.local"   6789
check_tcp "KFP MariaDB"          "mysql.${NS}.svc.cluster.local"               3306
check_tcp "Katib MariaDB"        "katib-mysql.${NS}.svc.cluster.local"         3306

if kubectl get svc model-registry-service -n "$NS" &>/dev/null; then
  check_tcp  "Model Registry API" "model-registry-service.${NS}.svc.cluster.local" 8080
  check_tcp  "Model Registry UI"  "model-registry-ui-service.${NS}.svc.cluster.local" 8080
  check_http "Model Registry API healthz" \
    "http://model-registry-service.${NS}.svc.cluster.local:8080/api/model_registry/v1alpha3/registered_models"
fi
if kubectl get sts model-catalog-postgres -n "$NS" &>/dev/null; then
  check_sts_ready    "model-catalog-postgres"
  check_deploy_ready "model-catalog-server"
  check_tcp "Model Catalog API" "model-catalog.${NS}.svc.cluster.local" 8080
fi

# ── Section 7: SeaweedFS bucket ───────────────────────────────────────────────
header "7. SeaweedFS bucket"

check_seaweedfs_bucket "mlpipeline"

# ── Section 8: HTTP health checks ─────────────────────────────────────────────
header "8. HTTP health checks"

check_http "KFP API healthz"          "http://ml-pipeline.${NS}.svc.cluster.local:8888/apis/v1beta1/healthz"
check_http "Central Dashboard"        "http://kubeflow-central-dashboard.${NS}.svc.cluster.local:80/healthz"
check_http "Dex OIDC discovery"       "http://kubeflow-dex.${NS}.svc.cluster.local:5556/dex/.well-known/openid-configuration"
check_http "oauth2-proxy ping"        "http://kubeflow-oauth2-proxy.${NS}.svc.cluster.local:80/ping"
check_http "SeaweedFS master health"  "http://seaweedfs.${NS}.svc.cluster.local:9333/cluster/status"
check_http "Profiles metrics"         "http://profiles-kfam.${NS}.svc.cluster.local:8081/metrics"

# ── Section 9: PodDisruptionBudgets ───────────────────────────────────────────
header "9. PodDisruptionBudgets"
check_resource pdb ml-pipeline
check_resource pdb metadata-grpc-deployment
check_resource pdb workflow-controller

# ── Summary ────────────────────────────────────────────────────────────────────
header "━━━ Results ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Passed:   %d\n" "$PASS"
printf "  Failed:   %d\n" "$FAIL"
printf "  Warnings: %d\n" "$WARNINGS"
echo ""

if [ "$FAIL" -gt 0 ]; then
  red "SMOKE TESTS FAILED ($FAIL failure(s))"
  exit 1
else
  green "ALL SMOKE TESTS PASSED"
  exit 0
fi
