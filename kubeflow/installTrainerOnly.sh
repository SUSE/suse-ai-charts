#!/usr/bin/env bash
# Trainer-only Kubeflow install helper (convenience script, aimed at dev/test clusters).
#
# Installs only Kubeflow Trainer V2 + JobSet (install.sh --preset trainer-only), automating the
# steps of docs/use-cases/trainer-only-install.md (see that guide for what it does and why).
# By default it installs from this chart checkout (source). With --oci,
# --chart-version or --chart-ref it installs the released OCI chart instead
# (default oci://<suse-registry>/ai/charts/kubeflow). Unlike runMe.sh, it does NOT install cert-manager,
# Istio or the External Secrets Operator. It installs with the chart's
# presets/trainer-only.yaml preset (the same file the guide and CI use).
#
# Usage (credentials from environment variables, so the tokens stay out of `ps` and
# shell history):
#   export APPCO_REGISTRY_USER=<user> APPCO_REGISTRY_TOKEN=<token>
#   export SUSE_AI_REGISTRY_USER=regcode SUSE_AI_REGISTRY_TOKEN=<token>
#   ./installTrainerOnly.sh
#       [-f | --values-file <extra values.yaml>]   (repeatable; applied after the trainer-only values)
#       [--kubeconfig <path>]
#       [--suse-registry=<host>] [--suse-app-collection=<host>]
#       [--no-runtimes]        don't install the bundled ClusterTrainingRuntimes
#       [--skip-tests]         don't run `helm test`
#       [--sample]             run a sample TrainJob on torch-distributed after install
#       [--sample-namespace <ns>]   namespace for the sample TrainJob (default: trainer-sample)
#       [--oci]                install the released OCI chart (latest version) instead of this checkout
#       [--chart-version <v>]  install this released OCI chart version (implies --oci)
#       [--chart-ref <ref>]    OCI chart reference (implies --oci; default oci://<suse-registry>/ai/charts/kubeflow)
#
# Released charts are installed by the scripts they ship (0.6.x: their own installTrainerOnly.sh).
#
# The credentials can also be passed as positional arguments (same order as runMe.sh):
#   ./installTrainerOnly.sh <appco-user> <appco-token> <suse-ai-user> <suse-ai-token> [options]
# but then the tokens are visible to other users in the process list; the script warns.

set -euo pipefail

for _a in "$@"; do
  case "$_a" in
    -h | --help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    --preset | --no-istio-cni | --legacy-authz | --disable-cert-manager | --cloudflare-api-key)
      echo "ERROR: unknown option $_a" >&2; exit 1 ;;
  esac
done

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --preset trainer-only "$@"
