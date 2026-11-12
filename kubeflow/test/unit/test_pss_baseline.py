"""Unit tests for pss_baseline.py: the CI Pod Security 'baseline' checker must flag violations,
not only pass clean manifests (test_kfp_profile_controller.py covers the clean case)."""
import pss_baseline


def deployment(ns="alice", pod=None, container=None):
    return {
        "kind": "Deployment",
        "metadata": {"name": "d", "namespace": ns},
        "spec": {"template": {"spec": {**(pod or {}),
                                        "containers": [{"name": "c", "image": "i", **(container or {})}]}}},
    }


def test_clean_pod_passes():
    assert pss_baseline.check([deployment()], {"alice"}) == []


def test_istio_init_style_capabilities_are_flagged():
    # The classic istio-init container (NET_ADMIN/NET_RAW) is what global.istio.cni=true avoids.
    obj = deployment(container={"securityContext": {"capabilities": {"add": ["NET_ADMIN", "NET_RAW"]}}})
    errs = pss_baseline.check([obj], {"alice"})
    assert len(errs) == 1 and "NET_ADMIN" in errs[0] and "NET_RAW" in errs[0]


def test_baseline_violations_are_flagged():
    cases = [
        {"container": {"securityContext": {"privileged": True}}},
        {"pod": {"hostNetwork": True}},
        {"pod": {"volumes": [{"name": "h", "hostPath": {"path": "/"}}]}},
        {"container": {"ports": [{"containerPort": 80, "hostPort": 80}]}},
        {"pod": {"securityContext": {"seccompProfile": {"type": "Unconfined"}}}},
        {"pod": {"securityContext": {"sysctls": [{"name": "kernel.msgmax", "value": "1"}]}}},
    ]
    for case in cases:
        assert pss_baseline.check([deployment(**case)], {"alice"}), f"not flagged: {case}"


def test_only_listed_namespaces_are_checked():
    obj = deployment(ns="kube-system", container={"securityContext": {"privileged": True}})
    assert pss_baseline.check([obj], {"alice"}) == []
