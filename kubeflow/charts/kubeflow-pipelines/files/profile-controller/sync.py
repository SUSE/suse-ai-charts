# Copyright 2020-2021 The Kubeflow Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SUSE: copy of upstream Kubeflow Pipelines sync.py (kubeflow/pipelines, manifests/kustomize/base/
# installs/multi-user/pipelines-profile-controller/sync.py) at the tag in UPSTREAM_VERSION.
# SUSE changes are marked "SUSE:" below: image pull secrets for the optional per-profile
# artifact-proxy Deployment, keeping pull secrets older chart versions created here, replacing
# profile Secrets that hold the shared admin key or a key SeaweedFS no longer has, revoking a
# profile's other keys once its Secret exists, making the S3/IAM calls through the aws CLI
# instead of botocore, and serving requests on threads.
# The full difference from upstream is suse.patch next to this file (upstream tag in
# UPSTREAM_VERSION); CI checks upstream + suse.patch == this file. To re-sync: fetch the new
# upstream sync.py, apply suse.patch, update UPSTREAM_VERSION and regenerate the patch.

from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
import json
import os
import base64
import hashlib

# SUSE: the aws-cli image bundles botocore inside the `aws` binary, where Python can't import
# it. This shim keeps the botocore client API used below and runs each call as `aws <cmd>`.
import re
import subprocess


class _AwsCliError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.response = {'Error': {'Code': code, 'Message': message}}


class _AwsCliClient:
    def __init__(self, service, region_name, endpoint_url=None):
        self._service = 's3api' if service == 's3' else service
        self._opts = ['--output', 'json', '--region', region_name]
        if endpoint_url:
            self._opts += ['--endpoint-url', endpoint_url]

    def __getattr__(self, operation):
        if operation.startswith('_'):
            raise AttributeError(operation)

        def call(**params):
            try:
                proc = subprocess.run(
                    ['aws', self._service, operation.replace('_', '-'), *self._opts,
                     '--cli-input-json', json.dumps(params)],
                    capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired as exc:
                raise _AwsCliError('Timeout', f'aws {self._service} {operation}: no reply in {exc.timeout}s')
            if proc.returncode != 0:
                code = re.search(r'An error occurred \(([^)]+)\)', proc.stderr)
                raise _AwsCliError(code.group(1) if code else 'AwsCliError', proc.stderr.strip())
            return json.loads(proc.stdout) if proc.stdout.strip() else {}
        return call


class _AwsCliSession:
    def create_client(self, service, region_name, endpoint_url=None):
        return _AwsCliClient(service, region_name, endpoint_url)


S3_BUCKET_NAME = 'mlpipeline'

session = _AwsCliSession()  # SUSE: was botocore.session.get_session()
# S3 client for lifecycle policy and bucket policy management
s3_endpoint_url = os.environ.get("S3_ENDPOINT_URL", "http://seaweedfs.kubeflow:8333")
s3 = session.create_client('s3', region_name='foobar', endpoint_url=s3_endpoint_url)


def _normalize_domain(domain):
    return domain if domain.startswith('.') else '.' + domain


def create_iam_client():
    # To interact with SeaweedFS user management. Region does not matter.
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    if endpoint_url:
        return session.create_client('iam', region_name='foobar', endpoint_url=endpoint_url)
    return session.create_client('iam', region_name='foobar')


iam = create_iam_client()


def _accesskey(secret):
    # SUSE: decoded accesskey of an observed Secret, "" if absent or malformed.
    try:
        return base64.b64decode((secret or {}).get("data", {}).get("accesskey", "")).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def _holds_admin_key(secret):
    # SUSE: True if an observed Secret carries this controller's own (admin) access key.
    admin_key = os.environ.get("AWS_ACCESS_KEY_ID")
    return bool(admin_key) and _accesskey(secret) == admin_key


def _profile_keys(user):
    # SUSE: the IAM user's access key IDs; [] if the user does not exist, None if IAM can't be read.
    try:
        return [k["AccessKeyId"] for k in iam.list_access_keys(UserName=user).get("AccessKeyMetadata", [])]
    except Exception as exc:
        if getattr(exc, "response", {}).get("Error", {}).get("Code") == "NoSuchEntity":
            return []
        print(f"WARNING: cannot list access keys for {user}: {exc}")
        return None


def _iam_ready():
    # SUSE: True once SeaweedFS IAM lists this controller's own (admin) key, i.e. it has loaded its
    # identities. Before that (e.g. right after a restart) a missing profile key proves nothing.
    admin_key = os.environ.get("AWS_ACCESS_KEY_ID")
    try:
        keys = [k["AccessKeyId"] for k in iam.list_access_keys().get("AccessKeyMetadata", [])]
    except Exception as exc:
        print(f"WARNING: cannot list the controller's own access keys: {exc}")
        return False
    return bool(admin_key) and admin_key in keys


def main():
    settings = get_settings_from_env()
    server = server_factory(**settings)
    server.serve_forever()


def get_settings_from_env(controller_port=None,
                          frontend_image=None,
                          frontend_tag=None,
                          disable_istio_sidecar=None,
                          artifacts_proxy_enabled=None,
                          artifact_retention_days=None,
                          cluster_domain=None,
                          object_store_host=None,
                          image_pull_secrets=None):
    """
    Returns a dict of settings from environment variables relevant to the controller

    Environment settings can be overridden by passing them here as arguments.

    Settings are pulled from the all-caps version of the setting name.  The
    following defaults are used if those environment variables are not set
    to enable backwards compatibility with previous versions of this script:
        frontend_image: ghcr.io/kubeflow/kfp-frontend
        frontend_tag: value of KFP_VERSION environment variable
        disable_istio_sidecar: Required (no default)
    """
    settings = dict()
    settings["controller_port"] = \
        controller_port or \
        os.environ.get("CONTROLLER_PORT", "8080")

    settings["frontend_image"] = \
        frontend_image or \
        os.environ.get("FRONTEND_IMAGE", "ghcr.io/kubeflow/kfp-frontend")

    settings["artifacts_proxy_enabled"] = \
        artifacts_proxy_enabled or \
        os.environ.get("ARTIFACTS_PROXY_ENABLED", "false")

    settings["artifact_retention_days"] = \
        artifact_retention_days or \
        os.environ.get("ARTIFACT_RETENTION_DAYS", -1)

    settings["cluster_domain"] = \
        cluster_domain or \
        os.environ.get("CLUSTER_DOMAIN", ".svc.cluster.local")

    settings["object_store_host"] = \
        object_store_host or \
        os.environ.get("OBJECT_STORE_HOST", "seaweedfs")

    # Look for specific tags for each image first, falling back to
    # previously used KFP_VERSION environment variable for backwards
    # compatibility
    settings["frontend_tag"] = \
        frontend_tag or \
        os.environ.get("FRONTEND_TAG") or \
        os.environ["KFP_VERSION"]

    settings["disable_istio_sidecar"] = \
        disable_istio_sidecar if disable_istio_sidecar is not None \
            else os.environ.get("DISABLE_ISTIO_SIDECAR") == "true"

    # SUSE: comma-separated image pull secret names for the artifact-proxy Deployment.
    settings["image_pull_secrets"] = \
        image_pull_secrets if image_pull_secrets is not None \
            else [n.strip() for n in os.environ.get("IMAGE_PULL_SECRETS", "").split(",") if n.strip()]

    return settings


def server_factory(frontend_image,
                   frontend_tag,
                   disable_istio_sidecar,
                   artifacts_proxy_enabled,
                   artifact_retention_days,
                   cluster_domain=".svc.cluster.local",
                   object_store_host="seaweedfs",
                   image_pull_secrets=(),  # SUSE
                   url="",
                   controller_port=8080):
    """
    Returns an HTTPServer populated with Handler with customized settings
    """
    class Controller(BaseHTTPRequestHandler):
        def upsert_lifecycle_policy(self, bucket_name, artifact_retention_days):
            """Configures or deletes the lifecycle policy based on the artifact_retention_days string."""
            try:
                retention_days = int(artifact_retention_days)
            except ValueError:
                print(f"ERROR: ARTIFACT_RETENTION_DAYS value '{artifact_retention_days}' is not a valid integer. Aborting policy update.")
                return

            # To disable lifecycle policy we need to delete it
            if retention_days <= 0:
                print(f"ARTIFACT_RETENTION_DAYS is non-positive ({retention_days} days). Attempting to delete lifecycle policy.")
                try:
                    response = s3.get_bucket_lifecycle_configuration(Bucket=bucket_name)
                    # Check if there are any enabled rules
                    has_enabled_rules = any(rule.get('Status') == 'Enabled' for rule in response.get('Rules', []))

                    if has_enabled_rules:
                        s3.delete_bucket_lifecycle(Bucket=bucket_name)
                        print("Successfully deleted lifecycle policy.")
                    else:
                        print("No enabled lifecycle rules found to delete.")
                except Exception:
                    print(f"Warning: No lifecycle policy exists")
                return

            # Create/update lifecycle policy
            life_cycle_policy = {
                "Rules": [
                    {
                        "Status": "Enabled",
                        "Filter": {"Prefix": "private-artifacts"},
                        "Expiration": {"Days": retention_days},
                        "ID": "private-artifacts",
                    },
                ]
            }
            print('upsert_lifecycle_policy:', life_cycle_policy)

            try:
                api_response = s3.put_bucket_lifecycle_configuration(
                    Bucket=bucket_name,
                    LifecycleConfiguration = life_cycle_policy
                )
                print('Lifecycle policy configured successfully:', api_response)
            except Exception as exception:
                if hasattr(exception, 'response') and 'Error' in exception.response:
                    print(f"ERROR: Failed to configure lifecycle policy: {exception.response['Error']['Code']} - {exception}")
                else:
                    print(f"ERROR: Failed to configure lifecycle policy: {exception}")

        def ensure_bucket_list_policy(self, bucket_name):
            """Bucket-wide ListBucket isolation, keyed on ${aws:username}.

            Top-level folder browsing is allowed for everyone; listing deeper
            inside another namespace's private prefix is denied. HeadBucket
            (KServe storage-initializer) is allowed. Set as a bucket policy
            because the embedded user-policy engine is Allow-only and cannot
            express Deny; SeaweedFS evaluates the bucket policy before it.
            """
            bucket_arn = f"arn:aws:s3:::{bucket_name}"
            desired = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Sid": "AllowOwnDeepList",
                        "Effect": "Allow",
                        "Principal": "*",
                        "Action": "s3:ListBucket",
                        "Resource": bucket_arn,
                        "Condition": {"StringLike": {"s3:prefix": [
                            "private-artifacts/${aws:username}/*",
                            "private/${aws:username}/*",
                            "artifacts/*",
                            "shared/*",
                        ]}},
                    },
                    {
                        "Sid": "AllowHeadBucket",
                        "Effect": "Allow",
                        "Principal": "*",
                        "Action": "s3:ListBucket",
                        "Resource": bucket_arn,
                        "Condition": {"StringEquals": {"s3:RequestMethod": "HEAD"}},
                    },
                    {
                        "Sid": "AllowTopLevelDelimitedBrowse",
                        "Effect": "Allow",
                        "Principal": "*",
                        "Action": "s3:ListBucket",
                        "Resource": bucket_arn,
                        "Condition": {
                            "Null": {"s3:prefix": "true"},
                            "StringEquals": {"s3:delimiter": "/"},
                        },
                    },
                    {
                        "Sid": "DenyOtherDeepList",
                        "Effect": "Deny",
                        "Principal": "*",
                        "Action": "s3:ListBucket",
                        "Resource": bucket_arn,
                        "Condition": {
                            "StringLike": {"s3:prefix": ["private-artifacts/*", "private/*"]},
                            "StringNotLike": {"s3:prefix": [
                                "private-artifacts/${aws:username}/*",
                                "private/${aws:username}/*",
                            ]},
                        },
                    },
                ],
            }
            desired_json = json.dumps(desired, sort_keys=True)

            try:
                current = s3.get_bucket_policy(Bucket=bucket_name).get("Policy", "")
                if current and json.dumps(json.loads(current), sort_keys=True) == desired_json:
                    return
            except Exception:
                pass

            try:
                s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(desired))
                print(f"Set ListBucket isolation bucket policy on {bucket_name}")
            except Exception as exception:
                if hasattr(exception, 'response') and 'Error' in exception.response:
                    print(f"ERROR: Failed to set bucket policy: {exception.response['Error']['Code']} - {exception}")
                else:
                    print(f"ERROR: Failed to set bucket policy: {exception}")

        def sync(self, parent, attachments):
            # parent is a namespace
            namespace = parent.get("metadata", {}).get("name")

            pipeline_enabled = parent.get("metadata", {}).get(
                "labels", {}).get("pipelines.kubeflow.org/enabled")

            if pipeline_enabled != "true":
                return {"status": {}, "attachments": []}

            # Compute status based on observed state.
            desired_status = {
                "kubeflow-pipelines-ready":
                    len(attachments["Secret.v1"]) == 1 and
                    len(attachments["ConfigMap.v1"]) == 3 and
                    len(attachments["Deployment.apps/v1"]) == (1 if artifacts_proxy_enabled.lower() == "true" else 0) and
                    len(attachments["Service.v1"]) == (1 if artifacts_proxy_enabled.lower() == "true" else 0) and
                    "True" or "False"
            }

            # Generate the desired attachment object(s).
            desired_resources = [
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {
                        "name": "kfp-launcher",
                        "namespace": namespace,
                    },
                    "data": {
                        "defaultPipelineRoot": f"minio://{S3_BUCKET_NAME}/private-artifacts/{namespace}/v2/artifacts",
                        "clusterDomain": cluster_domain,
                    },
                },
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {
                        "name": "metadata-grpc-configmap",
                        "namespace": namespace,
                    },
                    "data": {
                        "METADATA_GRPC_SERVICE_HOST":
                            "metadata-grpc-service.kubeflow",
                        "METADATA_GRPC_SERVICE_PORT": "8080",
                    },
                },
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {
                        "name": "artifact-repositories",
                        "namespace": namespace,
                        "annotations": {
                            "workflows.argoproj.io/default-artifact-repository": "default-namespaced"
                        }
                    },
                    "data": {
                        "default-namespaced": json.dumps({
                            "archiveLogs": True,
                            "s3": {
                                "endpoint": f"{object_store_host}.kubeflow{_normalize_domain(cluster_domain)}:9000",
                                "bucket": S3_BUCKET_NAME,
                                "keyFormat": f"private-artifacts/{namespace}/{{{{workflow.name}}}}/{{{{workflow.creationTimestamp.Y}}}}/{{{{workflow.creationTimestamp.m}}}}/{{{{workflow.creationTimestamp.d}}}}/{{{{pod.name}}}}",
                                "insecure": True,
                                "accessKeySecret": {
                                    "name": "mlpipeline-minio-artifact",
                                    "key": "accesskey",
                                },
                                "secretKeySecret": {
                                    "name": "mlpipeline-minio-artifact",
                                    "key": "secretkey",
                                }
                            }
                        })
                    }
                },
            ]

            # Add artifact fetcher related resources if enabled
            if artifacts_proxy_enabled.lower() == "true":
                desired_resources.extend([
                    {
                        "apiVersion": "apps/v1",
                        "kind": "Deployment",
                        "metadata": {
                            "labels": {
                                "app": "ml-pipeline-ui-artifact"
                            },
                            "name": "ml-pipeline-ui-artifact",
                            "namespace": namespace,
                        },
                        "spec": {
                            "selector": {
                                "matchLabels": {
                                    "app": "ml-pipeline-ui-artifact"
                                }
                            },
                            "template": {
                                "metadata": {
                                    "labels": {
                                        "app": "ml-pipeline-ui-artifact"
                                    },
                                    "annotations": {
                                        **({"sidecar.istio.io/inject": "false"} if disable_istio_sidecar else {}),
                                        "kubeflow-pipelines/image-spec-hash": hashlib.sha256(f"{frontend_image}:{frontend_tag}".encode()).hexdigest()[:16],
                                    },
                                },
                                "spec": {
                                    "containers": [{
                                        "name":
                                            "ml-pipeline-ui-artifact",
                                        "image": f"{frontend_image}:{frontend_tag}",
                                        "imagePullPolicy":
                                            "IfNotPresent",
                                        "ports": [{
                                            "containerPort": 3000
                                        }],
                                        "env": [
                                            {
                                                "name": "MINIO_ACCESS_KEY",
                                                "valueFrom": {
                                                    "secretKeyRef": {
                                                        "key": "accesskey",
                                                        "name": "mlpipeline-minio-artifact"
                                                    }
                                                }
                                            },
                                            {
                                                "name": "MINIO_SECRET_KEY",
                                                "valueFrom": {
                                                    "secretKeyRef": {
                                                        "key": "secretkey",
                                                        "name": "mlpipeline-minio-artifact"
                                                    }
                                                }
                                            },
                                            {
                                                "name": "ML_PIPELINE_SERVICE_HOST",
                                                "value": f"ml-pipeline.kubeflow{_normalize_domain(cluster_domain)}"
                                            },
                                            {
                                                "name": "ML_PIPELINE_SERVICE_PORT",
                                                "value": "8888"
                                            },
                                            {
                                                "name": "FRONTEND_SERVER_NAMESPACE",
                                                "value": namespace,
                                            },
                                            {
                                                "name": "CLUSTER_DOMAIN",
                                                "value": cluster_domain,
                                            }
                                        ],
                                        "resources": {
                                            "requests": {
                                                "cpu": "10m",
                                                "memory": "70Mi"
                                            },
                                            "limits": {
                                                "cpu": "100m",
                                                "memory": "500Mi"
                                            },
                                        }
                                    }],
                                    "serviceAccountName":
                                        "default-editor",
                                    # SUSE: pull the frontend image from an authenticated registry.
                                    **({"imagePullSecrets": [{"name": n} for n in image_pull_secrets]}
                                       if image_pull_secrets else {}),
                                }
                            }
                        }
                    },
                    {
                        "apiVersion": "v1",
                        "kind": "Service",
                        "metadata": {
                            "name": "ml-pipeline-ui-artifact",
                            "namespace": namespace,
                            "labels": {
                                "app": "ml-pipeline-ui-artifact"
                            }
                        },
                        "spec": {
                            "ports": [{
                                "name":
                                    "http",  # name is required to let istio understand request protocol
                                "port": 80,
                                "protocol": "TCP",
                                "targetPort": 3000
                            }],
                            "selector": {
                                "app": "ml-pipeline-ui-artifact"
                            }
                        }
                    },
                ])

            print('Received request:\n', json.dumps(parent, sort_keys=True))
            print('Desired resources except secrets:\n', json.dumps(desired_resources, sort_keys=True))

            # Moved after the print argument because this is sensitive data.

            # SUSE: a Secret holding the shared admin key (copied there by older chart and controller
            # versions) or a key SeaweedFS no longer has is left out, so metacontroller deletes it
            # (Secrets are OnDelete, so new data would be ignored); the sync that the deletion triggers
            # creates a per-profile key.
            observed_secret = attachments["Secret.v1"].get(f"{namespace}/mlpipeline-minio-artifact")
            live_keys = _profile_keys(namespace) if observed_secret else None
            if _holds_admin_key(observed_secret) or (
                    live_keys is not None and _accesskey(observed_secret) not in live_keys and _iam_ready()):
                print('Existing secret holds the admin key or an unknown key; deleting it so a new key is created.')
            # Check if secret is already there when the controller made the request. If yes, then
            # use it. Else create a new credentials on seaweedfs for the namespace.
            elif s3_secret := attachments["Secret.v1"].get(f"{namespace}/mlpipeline-minio-artifact"):
                desired_resources.append(s3_secret)
                print('Using existing secret')
                # SUSE: the Secret's key is the profile's key; revoke any others (left by a sync that ran
                # before the new Secret was visible, or by a rotation), so each profile keeps one key.
                for key_id in live_keys or []:
                    if key_id != _accesskey(s3_secret):
                        try:
                            iam.delete_access_key(UserName=namespace, AccessKeyId=key_id)
                        except Exception as exc:
                            print(f"WARNING: cannot revoke access key for {namespace}: {exc}")
            else:
                print('Creating new access key.')
                s3_access_key = iam.create_access_key(UserName=namespace)

                # Per-user policy grants object access only. ListBucket scoping is
                # handled by the bucket policy (ensure_bucket_list_policy) because
                # the embedded user-policy engine is Allow-only and cannot Deny.
                iam.put_user_policy(
                    UserName=namespace,
                    PolicyName=f"KubeflowProject{namespace}",
                    PolicyDocument=json.dumps(
                        {
                            "Version": "2012-10-17",
                            "Statement": [
                                {
                                    "Effect": "Allow",
                                    "Action": [
                                        "s3:Put*",
                                        "s3:Get*",
                                        "s3:List*",
                                        "s3:DeleteObject"
                                    ],
                                    "Resource": [
                                        f"arn:aws:s3:::{S3_BUCKET_NAME}/artifacts/*",
                                        f"arn:aws:s3:::{S3_BUCKET_NAME}/private-artifacts/{namespace}/*",
                                        f"arn:aws:s3:::{S3_BUCKET_NAME}/private/{namespace}/*",
                                        f"arn:aws:s3:::{S3_BUCKET_NAME}/shared/*",
                                    ]
                                }
                            ]
                        })
                )

                self.ensure_bucket_list_policy(S3_BUCKET_NAME)

                self.upsert_lifecycle_policy(S3_BUCKET_NAME, artifact_retention_days)

                desired_resources.insert(
                    0,
                    {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {
                            "name": "mlpipeline-minio-artifact",
                            "namespace": namespace,
                        },
                        "data": {
                            "accesskey": base64.b64encode(s3_access_key["AccessKey"]["AccessKeyId"].encode('utf-8')).decode("utf-8"),
                            "secretkey": base64.b64encode(s3_access_key["AccessKey"]["SecretAccessKey"].encode('utf-8')).decode("utf-8"),
                    },
                })

            # SUSE: keep pull secrets that older chart versions created through this controller;
            # leaving them out of the desired set would make metacontroller delete them.
            for name in image_pull_secrets:
                if owned := attachments["Secret.v1"].get(f"{namespace}/{name}"):
                    desired_resources.append(owned)

            return {"status": desired_status, "attachments": desired_resources}

        def do_POST(self):
            # Serve the sync() function as a JSON webhook.
            observed = json.loads(
                self.rfile.read(int(self.headers.get("content-length"))))
            desired = self.sync(observed["object"], observed["attachments"])

            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(bytes(json.dumps(desired), 'utf-8'))

    # SUSE: one thread per request. Each S3/IAM call starts an aws CLI process, so serial syncs
    # queue past metacontroller's webhook timeout with many profiles; syncs touch per-profile
    # IAM users and idempotent bucket settings, and metacontroller never syncs one profile twice
    # at once.
    return ThreadingHTTPServer((url, int(controller_port)), Controller)


if __name__ == "__main__":
    main()
