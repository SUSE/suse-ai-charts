"""Unit tests for the vendored KFP profile-controller hook
(charts/kubeflow-pipelines/files/profile-controller/sync.py).

Upstream's own test_sync.py is stale for KFP 2.17 (it still expects the removed per-profile
visualization server and fails against pristine upstream sync.py), so these tests drive sync()
directly with mocked SeaweedFS IAM/S3 clients and pin the behaviour this chart relies on:
per-profile credentials, upstream's ConfigMap set, the optional artifact proxy, and the
SUSE image-pull-secret patch.

Run:  pip install pytest && pytest -q kubeflow/test/unit
"""
import base64
import importlib.util
import json
import pathlib
from unittest import mock

import pytest

SYNC_PY = (pathlib.Path(__file__).resolve().parents[2]
           / "charts/kubeflow-pipelines/files/profile-controller/sync.py")


@pytest.fixture
def sync_mod(monkeypatch):
    monkeypatch.setenv("AWS_ENDPOINT_URL", "http://seaweedfs.kubeflow:8111")
    spec = importlib.util.spec_from_file_location("kfp_profile_sync", SYNC_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.iam = mock.MagicMock()
    mod.iam.create_access_key.return_value = {
        "AccessKey": {"AccessKeyId": "AKIDALICE", "SecretAccessKey": "secret-alice"}}
    mod.iam.list_access_keys.return_value = {"AccessKeyMetadata": []}
    mod.s3 = mock.MagicMock()
    mod.s3.get_bucket_policy.side_effect = Exception("no policy")
    mod.s3.get_bucket_lifecycle_configuration.side_effect = Exception("no lifecycle")
    return mod


def controller(mod, proxy="false", pull_secrets=(), retention="-1"):
    srv = mod.server_factory(frontend_image="registry.suse.com/ai/containers/kubeflow/kfp-frontend",
                             frontend_tag="2.17.3", disable_istio_sidecar=False,
                             artifacts_proxy_enabled=proxy, artifact_retention_days=retention,
                             image_pull_secrets=list(pull_secrets), controller_port=0)
    try:
        return object.__new__(srv.RequestHandlerClass)
    finally:
        srv.server_close()


def ns(name="alice", enabled="true"):
    return {"metadata": {"name": name, "labels": {"pipelines.kubeflow.org/enabled": enabled}}}


def empty_attachments():
    return {"Secret.v1": {}, "ConfigMap.v1": {}, "Deployment.apps/v1": {}, "Service.v1": {}}


def by_kind(result):
    return {(a["kind"], a["metadata"]["name"]): a for a in result["attachments"]}


def test_namespace_without_label_gets_nothing(sync_mod):
    out = controller(sync_mod).sync(ns(enabled="false"), empty_attachments())
    assert out["attachments"] == []
    sync_mod.iam.create_access_key.assert_not_called()


def test_new_profile_gets_its_own_scoped_credentials(sync_mod):
    out = controller(sync_mod).sync(ns("alice"), empty_attachments())
    objs = by_kind(out)
    sync_mod.iam.create_access_key.assert_called_once_with(UserName="alice")
    policy = json.loads(sync_mod.iam.put_user_policy.call_args.kwargs["PolicyDocument"])
    resources = policy["Statement"][0]["Resource"]
    assert "arn:aws:s3:::mlpipeline/private-artifacts/alice/*" in resources
    assert "arn:aws:s3:::mlpipeline/private/alice/*" in resources
    assert not any("bob" in r for r in resources)
    sync_mod.s3.put_bucket_policy.assert_called_once()  # ListBucket isolation
    secret = objs[("Secret", "mlpipeline-minio-artifact")]
    assert base64.b64decode(secret["data"]["accesskey"]).decode() == "AKIDALICE"
    assert base64.b64decode(secret["data"]["secretkey"]).decode() == "secret-alice"


def test_upstream_configmaps_and_no_proxy_by_default(sync_mod):
    objs = by_kind(controller(sync_mod).sync(ns("alice"), empty_attachments()))
    assert {k for k in objs if k[0] == "ConfigMap"} == {
        ("ConfigMap", "kfp-launcher"), ("ConfigMap", "metadata-grpc-configmap"),
        ("ConfigMap", "artifact-repositories")}
    root = objs[("ConfigMap", "kfp-launcher")]["data"]["defaultPipelineRoot"]
    assert root == "minio://mlpipeline/private-artifacts/alice/v2/artifacts"
    repo = json.loads(objs[("ConfigMap", "artifact-repositories")]["data"]["default-namespaced"])
    assert repo["s3"]["keyFormat"].startswith("private-artifacts/alice/")
    assert not any(k[0] in ("Deployment", "Service") for k in objs)
    assert not any("visualizationserver" in k[1] for k in objs)


def test_existing_secret_is_reused_without_new_keys(sync_mod):
    att = empty_attachments()
    existing = {"apiVersion": "v1", "kind": "Secret",
                "metadata": {"name": "mlpipeline-minio-artifact", "namespace": "alice"},
                "data": {"accesskey": "b2xk", "secretkey": "b2xk"}}
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = existing
    sync_mod.iam.list_access_keys.return_value = {"AccessKeyMetadata": [{"AccessKeyId": "old"}]}
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    sync_mod.iam.create_access_key.assert_not_called()
    assert objs[("Secret", "mlpipeline-minio-artifact")] is existing


def secret_with_key(key):
    b64 = base64.b64encode(key.encode()).decode()
    return {"apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": "mlpipeline-minio-artifact", "namespace": "alice"},
            "data": {"accesskey": b64, "secretkey": b64}}


def test_secret_with_admin_key_is_deleted_then_replaced(sync_mod, monkeypatch):
    # Profiles from before 0.6.0 hold the shared admin key. Secrets are OnDelete in metacontroller,
    # so the controller drops the Secret (metacontroller deletes it) without minting a key ...
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "ADMINKEY")
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = secret_with_key("ADMINKEY")
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert ("Secret", "mlpipeline-minio-artifact") not in objs
    sync_mod.iam.create_access_key.assert_not_called()
    # ... and the next sync, with the Secret gone, mints the per-profile key once.
    objs = by_kind(controller(sync_mod).sync(ns("alice"), empty_attachments()))
    sync_mod.iam.create_access_key.assert_called_once_with(UserName="alice")
    secret = objs[("Secret", "mlpipeline-minio-artifact")]
    assert base64.b64decode(secret["data"]["accesskey"]).decode() == "AKIDALICE"


def test_per_profile_secret_is_kept_when_admin_key_differs(sync_mod, monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "ADMINKEY")
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = existing = secret_with_key("AKIDALICE")
    sync_mod.iam.list_access_keys.return_value = {"AccessKeyMetadata": [{"AccessKeyId": "AKIDALICE"}]}
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    sync_mod.iam.create_access_key.assert_not_called()
    assert objs[("Secret", "mlpipeline-minio-artifact")] is existing


def keys(*ids):
    return {"AccessKeyMetadata": [{"AccessKeyId": i} for i in ids]}


def test_new_key_does_not_revoke_anything(sync_mod):
    # A sync can run before the Secret it just returned is visible; revoking here would break that
    # Secret (seen live: the profile was left with a revoked key). Revocation happens on reuse.
    sync_mod.iam.list_access_keys.return_value = keys("OLD1")
    controller(sync_mod).sync(ns("alice"), empty_attachments())
    sync_mod.iam.delete_access_key.assert_not_called()
    sync_mod.iam.create_access_key.assert_called_once_with(UserName="alice")


def test_reuse_revokes_the_profiles_other_keys(sync_mod):
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = secret_with_key("KEEP")
    sync_mod.iam.list_access_keys.return_value = keys("ORPHAN", "KEEP")
    controller(sync_mod).sync(ns("alice"), att)
    sync_mod.iam.delete_access_key.assert_called_once_with(UserName="alice", AccessKeyId="ORPHAN")
    sync_mod.iam.create_access_key.assert_not_called()


def iam_lists(profile_keys, own_keys=("ADMINKEY",)):
    # list_access_keys(UserName=...) -> the profile's keys; without UserName -> the controller's own.
    def side_effect(**kw):
        if "UserName" not in kw:
            return keys(*own_keys)
        if isinstance(profile_keys, Exception):
            raise profile_keys
        return keys(*profile_keys)
    return side_effect


def test_secret_with_unknown_key_is_deleted_then_replaced(sync_mod, monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "ADMINKEY")
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = secret_with_key("REVOKED")
    sync_mod.iam.list_access_keys.side_effect = iam_lists(["OTHER"])
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert ("Secret", "mlpipeline-minio-artifact") not in objs
    sync_mod.iam.create_access_key.assert_not_called()
    sync_mod.iam.delete_access_key.assert_not_called()


def test_secret_is_deleted_when_the_iam_user_is_gone(sync_mod, monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "ADMINKEY")
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = secret_with_key("AKIDALICE")
    sync_mod.iam.list_access_keys.side_effect = iam_lists(sync_mod._AwsCliError("NoSuchEntity", "no user"))
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert ("Secret", "mlpipeline-minio-artifact") not in objs


def test_secret_is_kept_while_iam_has_not_loaded_its_identities(sync_mod, monkeypatch):
    # Right after a SeaweedFS restart IAM can answer with empty lists; a missing profile key then
    # proves nothing, so no Secret may be dropped (that would rotate every profile's key).
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "ADMINKEY")
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = existing = secret_with_key("AKIDALICE")
    sync_mod.iam.list_access_keys.side_effect = iam_lists([], own_keys=())
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert objs[("Secret", "mlpipeline-minio-artifact")] is existing
    sync_mod.iam.delete_access_key.assert_not_called()
    sync_mod.iam.create_access_key.assert_not_called()


def test_secret_is_kept_when_iam_cannot_be_read(sync_mod):
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = existing = secret_with_key("AKIDALICE")
    sync_mod.iam.list_access_keys.side_effect = sync_mod._AwsCliError("Timeout", "no reply")
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert objs[("Secret", "mlpipeline-minio-artifact")] is existing
    sync_mod.iam.delete_access_key.assert_not_called()


def test_double_sync_before_the_secret_is_visible_ends_with_one_working_key(sync_mod):
    # Two syncs see no Secret (metacontroller cache lag) and each mints a key; the Secret keeps the
    # first. The next sync sees that Secret, keeps its key and revokes the orphan.
    sync_mod.iam.create_access_key.side_effect = [
        {"AccessKey": {"AccessKeyId": k, "SecretAccessKey": "s"}} for k in ("K1", "K2")]
    first = by_kind(controller(sync_mod).sync(ns("alice"), empty_attachments()))
    controller(sync_mod).sync(ns("alice"), empty_attachments())
    att = empty_attachments()
    att["Secret.v1"]["alice/mlpipeline-minio-artifact"] = first[("Secret", "mlpipeline-minio-artifact")]
    sync_mod.iam.list_access_keys.return_value = keys("K1", "K2")
    objs = by_kind(controller(sync_mod).sync(ns("alice"), att))
    assert base64.b64decode(objs[("Secret", "mlpipeline-minio-artifact")]["data"]["accesskey"]).decode() == "K1"
    sync_mod.iam.delete_access_key.assert_called_once_with(UserName="alice", AccessKeyId="K2")


def test_owned_pull_secret_is_kept_but_never_created(sync_mod):
    # Charts before July 2026 created the pull secret through this controller: it must stay owned,
    # or metacontroller deletes it. A pull secret the controller does not own is never created.
    att = empty_attachments()
    owned = {"apiVersion": "v1", "kind": "Secret",
             "metadata": {"name": "application-collection", "namespace": "alice"}}
    att["Secret.v1"]["alice/application-collection"] = owned
    ctl = controller(sync_mod, pull_secrets=["application-collection", "suse-ai-registry"])
    objs = by_kind(ctl.sync(ns("alice"), att))
    assert objs[("Secret", "application-collection")] is owned
    assert ("Secret", "suse-ai-registry") not in objs
    assert ("Secret", "application-collection") not in by_kind(ctl.sync(ns("alice"), empty_attachments()))


def test_proxy_on_adds_deployment_with_suse_pull_secrets(sync_mod):
    objs = by_kind(controller(sync_mod, proxy="true",
                              pull_secrets=["application-collection", "suse-ai-registry"])
                   .sync(ns("alice"), empty_attachments()))
    pod = objs[("Deployment", "ml-pipeline-ui-artifact")]["spec"]["template"]["spec"]
    assert pod["imagePullSecrets"] == [{"name": "application-collection"}, {"name": "suse-ai-registry"}]
    assert pod["containers"][0]["image"] == "registry.suse.com/ai/containers/kubeflow/kfp-frontend:2.17.3"
    assert ("Service", "ml-pipeline-ui-artifact") in objs


def test_proxy_on_without_pull_secrets_matches_upstream(sync_mod):
    objs = by_kind(controller(sync_mod, proxy="true").sync(ns("alice"), empty_attachments()))
    pod = objs[("Deployment", "ml-pipeline-ui-artifact")]["spec"]["template"]["spec"]
    assert "imagePullSecrets" not in pod


def test_pull_secrets_env_parsing(sync_mod, monkeypatch):
    monkeypatch.setenv("KFP_VERSION", "2.17.3")
    monkeypatch.setenv("IMAGE_PULL_SECRETS", "a, b,,")
    assert sync_mod.get_settings_from_env()["image_pull_secrets"] == ["a", "b"]
    monkeypatch.setenv("IMAGE_PULL_SECRETS", "")
    assert sync_mod.get_settings_from_env()["image_pull_secrets"] == []


def test_retention_days_sets_lifecycle_rule(sync_mod):
    controller(sync_mod, retention="30").sync(ns("alice"), empty_attachments())
    rule = sync_mod.s3.put_bucket_lifecycle_configuration.call_args.kwargs[
        "LifecycleConfiguration"]["Rules"][0]
    assert rule["Filter"]["Prefix"] == "private-artifacts" and rule["Expiration"]["Days"] == 30


def test_controller_objects_pass_pss_baseline(sync_mod):
    # global.istio.cni=true enforces Pod Security Standards 'baseline' in profile namespaces,
    # so everything the controller creates there must be admissible (proxy on = most objects).
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    import pss_baseline
    out = controller(sync_mod, proxy="true", pull_secrets=["suse-ai-registry"]).sync(
        ns("alice"), empty_attachments())
    assert pss_baseline.check(out["attachments"], {"alice"}) == []


def run_result(returncode=0, stdout="", stderr=""):
    return mock.Mock(returncode=returncode, stdout=stdout, stderr=stderr)


def test_aws_cli_shim_builds_s3api_and_iam_commands(sync_mod):
    with mock.patch.object(sync_mod.subprocess, "run", return_value=run_result()) as run:
        sync_mod._AwsCliClient("s3", "foobar", "http://seaweedfs.kubeflow:8333").put_bucket_policy(
            Bucket="mlpipeline", Policy="{}")
        sync_mod._AwsCliClient("iam", "foobar").put_user_policy(UserName="alice")
    s3_cmd, iam_cmd = (c.args[0] for c in run.call_args_list)
    assert s3_cmd[:3] == ["aws", "s3api", "put-bucket-policy"]
    assert s3_cmd[s3_cmd.index("--endpoint-url") + 1] == "http://seaweedfs.kubeflow:8333"
    assert json.loads(s3_cmd[-1]) == {"Bucket": "mlpipeline", "Policy": "{}"}
    assert iam_cmd[:3] == ["aws", "iam", "put-user-policy"] and "--endpoint-url" not in iam_cmd


def test_aws_cli_shim_returns_parsed_json(sync_mod):
    key = {"AccessKey": {"AccessKeyId": "AK", "SecretAccessKey": "SK"}}
    with mock.patch.object(sync_mod.subprocess, "run", return_value=run_result(stdout=json.dumps(key))):
        assert sync_mod._AwsCliClient("iam", "foobar").create_access_key(UserName="alice") == key
    with mock.patch.object(sync_mod.subprocess, "run", return_value=run_result(stdout="\n")):
        assert sync_mod._AwsCliClient("s3", "foobar").delete_bucket_lifecycle(Bucket="b") == {}


def test_aws_cli_shim_raises_botocore_style_errors(sync_mod):
    err = ("\nAn error occurred (NoSuchBucketPolicy) when calling the GetBucketPolicy operation: "
           "The bucket policy does not exist\n")
    with mock.patch.object(sync_mod.subprocess, "run", return_value=run_result(254, stderr=err)):
        with pytest.raises(sync_mod._AwsCliError) as exc:
            sync_mod._AwsCliClient("s3", "foobar").get_bucket_policy(Bucket="mlpipeline")
    assert exc.value.response["Error"]["Code"] == "NoSuchBucketPolicy"


def test_aws_cli_shim_raises_timeout_as_aws_cli_error(sync_mod):
    timeout = sync_mod.subprocess.TimeoutExpired(cmd="aws", timeout=60)
    with mock.patch.object(sync_mod.subprocess, "run", side_effect=timeout):
        with pytest.raises(sync_mod._AwsCliError) as exc:
            sync_mod._AwsCliClient("iam", "foobar").create_access_key(UserName="alice")
    assert exc.value.response["Error"]["Code"] == "Timeout"


def test_server_handles_requests_concurrently(sync_mod):
    # Each S3/IAM call starts an aws CLI process; a single-threaded server would queue syncs past
    # metacontroller's webhook timeout when there are many profiles.
    import http.server
    srv = sync_mod.server_factory(frontend_image="x", frontend_tag="1", disable_istio_sidecar=False,
                                  artifacts_proxy_enabled="false", artifact_retention_days="-1",
                                  image_pull_secrets=[], controller_port=0)
    try:
        assert isinstance(srv, http.server.ThreadingHTTPServer) and srv.daemon_threads
    finally:
        srv.server_close()
