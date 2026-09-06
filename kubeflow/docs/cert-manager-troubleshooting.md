# Troubleshooting cert-manager Certificates, Requests, and ACME Orders

This guide provides step-by-step instructions for diagnosing and resolving cert-manager issues (such as stuck, pending, or failed TLS certificates) on the Kubeflow deployment.

---

## 1. High-Level Resource Lifecycle

When a `Certificate` is created, cert-manager coordinates several sub-resources to acquire the actual TLS secret:

```
[Certificate] ──> [CertificateRequest] ──> [Order] ──> [Challenge] (DNS-01 / HTTP-01)
```

If any layer in this chain stalls or errors out, the parent `Certificate` stays `READY=False` or `InProgress`.

---

## 2. Step-by-Step Diagnostics Workflow

### Step 1: Check the Top-Level Certificates
List all Certificates to see which ones are not `READY`:
```bash
kubectl get certificate -n istio-system
```

Describe the stuck Certificate to view the latest status message and failure reasons:
```bash
kubectl describe certificate <certificate-name> -n istio-system
```
*Look for **`Status.Conditions`** and **`Events`** at the bottom (e.g. `Issuing certificate as Secret does not exist`).*

---

### Step 2: Check the CertificateRequest
If a Certificate is stuck, check if there is an approved but unfulfilled request:
```bash
kubectl get certificaterequest -n istio-system
```

Describe the stuck request to see why it isn't ready:
```bash
kubectl describe certificaterequest <request-name> -n istio-system
```

---

### Step 3: Check the ACME Order
If you are using Let's Encrypt, cert-manager creates an `Order` resource. Check its status:
```bash
kubectl get order -n istio-system
```

If the order is in an `errored` state, describe it to see the exact API reject response from Let's Encrypt:
```bash
kubectl describe order <order-name> -n istio-system
```

* **Example Error (Race Condition / `orderNotReady`):**
  ```
  Reason: Failed to finalize Order: 403 urn:ietf:params:acme:error:orderNotReady: Order's status ("processing") is not acceptable for finalization
  ```
  This happens if cert-manager attempts to send the Certificate Signing Request (CSR) before Let's Encrypt finishes transitioning all authorizations to the `"valid"` state.

---

### Step 4: Check the Active Challenges
If the order is pending or errored, look for the underlying ACME DNS-01 or HTTP-01 challenges:
```bash
kubectl get challenge -n istio-system
```

Describe the challenge to see why DNS propagation or validation is failing:
```bash
kubectl describe challenge <challenge-name> -n istio-system
```
*Look for **`Events`** like `propagation check failed` or authorization reject reasons.*

---

## 3. How to Force-Reset Stuck cert-manager Backoffs

If an order errors out, cert-manager enters an **exponential backoff state** (often backing off for up to **1 hour**) before it will retry. During backoff, annotating the Certificate with `cert-manager.io/renew="true"` **will be ignored** because it is a failed issuance retry, not a renewal.

### The Solution: Delete and Recreate
To bypass the backoff and trigger an immediate retry (which will instantly reuse any already cached/valid authorizations without re-running DNS validation):

1. **Delete the stuck CertificateRequest:**
   ```bash
   kubectl delete certificaterequest <request-name> -n istio-system
   ```

2. **Cleanly Recreate the Certificate:**
   Export the Certificate's spec, strip out the runtime metadata and status fields, delete the stuck Certificate resource to clear the controller's backoff memory, and re-apply it:
   ```bash
   kubectl get certificate <certificate-name> -n istio-system -o json \
     | jq 'del(.status, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.annotations)' \
     | kubectl replace --force -f -
   ```

---

## 4. Common Point-of-Failure Checklist

### DNS-01 Wildcard Challenges (Let's Encrypt)
* **Required Scopes:** Ensure your DNS Provider (e.g. Cloudflare) API token has **both** `Zone - DNS - Edit` and `Zone - Zone - Read` scopes.
* **Zone Access:** The API token must be allowed to manage the base root domain zone (e.g. `suseclouddev.com`), as wildcard certificates (`*.mbvmdl.suseclouddev.com`) require editing records on the root zone.
* **HTTP-01 Restriction:** Let's Encrypt **does not support** HTTP-01 challenges for wildcard domains. You **must** use a DNS-01 solver (e.g., Cloudflare) for wildcards.

---

## 5. Permanent Prevention: Global cert-manager Tuning

To permanently prevent the finalization race condition (which is caused by client-side API throttling and stale caches during concurrent certificate requests), you can tune the **cert-manager controller settings** globally.

This optimizes API concurrency and caps the failed order retry backoff so that cert-manager recovers automatically in minutes rather than hours.

### Option A: If installing cert-manager separately (Recommended)
Add these CLI flags when deploying or upgrading cert-manager via Helm:

```yaml
# Helm values for cert-manager installation
# Boost QPS/Burst to eliminate client-side throttling and optimistic locking
# Lower backoff caps so that failures are automatically retried in minutes instead of hours
controller:
  extraArgs:
    - --api-qps=100
    - --api-burst=150
    - --certificate-request-minimum-backoff-duration=1m
    - --certificate-request-maximum-backoff-duration=10m
```

### Option B: If installing cert-manager via the Kubeflow umbrella chart
If you have set `certManager.install: true` in your values overrides, add this block to your values file:

```yaml
certManager:
  install: true

cert-manager:
  controller:
    extraArgs:
      - --api-qps=100
      - --api-burst=150
      - --certificate-request-minimum-backoff-duration=1m
      - --certificate-request-maximum-backoff-duration=10m
```

### Why These Settings Work:
* **`--api-qps=100` & `--api-burst=150`:** Elevates cert-manager's permission limit for concurrent Kubernetes API requests. This eliminates the `"client-side throttling"` delays, allowing cert-manager to process events instantly before caching states become stale (preventing `"the object has been modified"` optimistic locking errors).
* **`--certificate-request-minimum-backoff-duration=1m` & `--certificate-request-maximum-backoff-duration=10m`:** Redefines the default failed order retry timer. If Let's Encrypt rejects a finalization request due to a transient race condition, cert-manager will retry in **1 minute** instead of **1 hour**, resolving the issue autonomously without manual administrator intervention.

