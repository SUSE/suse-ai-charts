"""Kubernetes Pod Security Standards 'baseline' checker for rendered manifests.

Implements the baseline controls from https://kubernetes.io/docs/concepts/security/pod-security-standards/
(HostProcess, host namespaces, privileged, capabilities, hostPath, host ports, AppArmor, SELinux,
/proc mount, seccomp, sysctls). Used by CI to ensure everything the chart renders into profile
namespaces is admissible when global.istio.cni=true enforces 'baseline' there.

Usage: python3 pss_baseline.py <rendered.yaml> <namespace> [<namespace> ...]
Exit 1 with one line per violation.
"""
import sys

ALLOWED_CAPS = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD",
                "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"}
SAFE_SYSCTLS = {"kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range",
                "net.ipv4.ip_unprivileged_port_start", "net.ipv4.tcp_syncookies",
                "net.ipv4.ping_group_range", "net.ipv4.ip_local_reserved_ports",
                "net.ipv4.tcp_keepalive_time", "net.ipv4.tcp_fin_timeout",
                "net.ipv4.tcp_keepalive_intvl", "net.ipv4.tcp_keepalive_probes"}
SELINUX_TYPES = {None, "", "container_t", "container_init_t", "container_kvm_t", "container_engine_t"}


def pod_spec(obj):
    kind = obj.get("kind")
    spec = obj.get("spec") or {}
    if kind == "Pod":
        return obj.get("metadata", {}), spec
    if kind == "CronJob":
        tpl = spec.get("jobTemplate", {}).get("spec", {}).get("template", {})
        return tpl.get("metadata", {}), tpl.get("spec", {})
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        tpl = spec.get("template", {})
        return tpl.get("metadata", {}), tpl.get("spec", {})
    return None, None


def check_sc(where, sc, errs, pod_level=False):
    sc = sc or {}
    if (sc.get("windowsOptions") or {}).get("hostProcess"):
        errs.append(f"{where}: windowsOptions.hostProcess")
    if not pod_level:
        if sc.get("privileged"):
            errs.append(f"{where}: privileged")
        add = set((sc.get("capabilities") or {}).get("add") or [])
        if add - ALLOWED_CAPS:
            errs.append(f"{where}: capabilities.add {sorted(add - ALLOWED_CAPS)}")
        if sc.get("procMount") not in (None, "Default"):
            errs.append(f"{where}: procMount {sc.get('procMount')}")
    if (sc.get("seccompProfile") or {}).get("type") == "Unconfined":
        errs.append(f"{where}: seccompProfile Unconfined")
    if (sc.get("appArmorProfile") or {}).get("type") == "Unconfined":
        errs.append(f"{where}: appArmorProfile Unconfined")
    sel = sc.get("seLinuxOptions") or {}
    if sel.get("type") not in SELINUX_TYPES or sel.get("user") or sel.get("role"):
        errs.append(f"{where}: seLinuxOptions {sel}")
    if pod_level:
        bad = [s["name"] for s in sc.get("sysctls") or [] if s.get("name") not in SAFE_SYSCTLS]
        if bad:
            errs.append(f"{where}: unsafe sysctls {bad}")


def check(docs, namespaces):
    errs = []
    for obj in docs:
        if not obj or obj.get("metadata", {}).get("namespace") not in namespaces:
            continue
        meta, spec = pod_spec(obj)
        if spec is None:
            continue
        name = f"{obj['kind']} {obj['metadata']['namespace']}/{obj['metadata']['name']}"
        for k in ("hostNetwork", "hostPID", "hostIPC"):
            if spec.get(k):
                errs.append(f"{name}: {k}")
        for v in spec.get("volumes") or []:
            if "hostPath" in v:
                errs.append(f"{name}: hostPath volume {v.get('name')}")
        for ann, val in (meta.get("annotations") or {}).items():
            if ann.startswith("container.apparmor.security.beta.kubernetes.io/") and val == "unconfined":
                errs.append(f"{name}: {ann}=unconfined")
        check_sc(name, spec.get("securityContext"), errs, pod_level=True)
        for c in (spec.get("initContainers") or []) + (spec.get("containers") or []) \
                + (spec.get("ephemeralContainers") or []):
            where = f"{name} container {c.get('name')}"
            check_sc(where, c.get("securityContext"), errs)
            for p in c.get("ports") or []:
                if p.get("hostPort"):
                    errs.append(f"{where}: hostPort {p['hostPort']}")
    return errs


if __name__ == "__main__":
    import yaml  # only the CLI needs it; check() works on parsed objects

    docs = list(yaml.safe_load_all(open(sys.argv[1])))
    errs = check(docs, set(sys.argv[2:]))
    for e in errs:
        print("PSS baseline violation:", e)
    sys.exit(1 if errs else 0)
