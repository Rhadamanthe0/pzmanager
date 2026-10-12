"""Identifier une JVM de l'unité PZ, sans emprunter celle d'un autre service."""
import argparse
import os
from pathlib import Path
import re
import subprocess


def properties(unit, timeout=2):
    result = subprocess.run(["systemctl", "--user", "show", "-p",
                             "ActiveState,MainPID,InvocationID,ControlGroup", "--", unit],
                            capture_output=True, text=True, check=True, timeout=timeout)
    fields = {}
    for line in result.stdout.splitlines():
        key, sep, value = line.partition("=")
        if not sep or key in fields:
            raise ValueError("Identité systemd ambiguë")
        fields[key] = value
    if set(fields) != {"ActiveState", "MainPID", "InvocationID", "ControlGroup"}:
        raise ValueError("Identité systemd incomplète")
    if fields["ActiveState"] not in {"active", "activating", "deactivating", "inactive", "failed"} or not fields["MainPID"].isdigit():
        raise ValueError("État systemd invalide")
    return fields


def identity_fields(fields, unit, states=("active",), allow_zero=False):
    group = fields["ControlGroup"]
    if (fields["ActiveState"] not in states or not fields["MainPID"].isdigit()
            or int(fields["MainPID"]) < (0 if allow_zero else 1)
            or not re.fullmatch(r"[0-9a-f]{32}", fields["InvocationID"])
            or not group.startswith("/") or group == "/"
            or ".." in group.split("/") or not group.endswith("/" + unit)):
        raise ValueError("Unité PZ sans processus identifié")
    return fields["InvocationID"], int(fields["MainPID"]), group


def identity(unit, states=("active",), timeout=2, allow_zero=False):
    return identity_fields(properties(unit, timeout), unit, states, allow_zero)


def jvm_status(unit, cgroup_root=Path("/sys/fs/cgroup"), proc_root=Path("/proc")):
    """Une panne de bus est inconnue, jamais une preuve que le jeu est arrêté."""
    try:
        fields = properties(unit)
        state = fields["ActiveState"]
        if state in {"inactive", "failed"} and int(fields["MainPID"]) == 0:
            return {"pid": None, "service_state": "inactive", "invocation": None}
        if state in {"activating", "deactivating"}:
            return {"pid": None, "service_state": state, "invocation": fields["InvocationID"]}
        before = identity_fields(fields, unit)
        pid = find_in_group(before[2], os.getuid(), cgroup_root, proc_root)
        if before == identity(unit) and pid is not None:
            return {"pid": pid, "service_state": "active", "invocation": before[0]}
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {"pid": None, "service_state": "unknown", "invocation": None}


def find_in_group(group, uid, cgroup_root=Path("/sys/fs/cgroup"), proc_root=Path("/proc")):
    if not group.startswith("/") or group == "/" or ".." in group.split("/"):
        return None
    best, best_rss = None, -1
    path = cgroup_root / group.lstrip("/")
    try:
        pids = {int(pid) for file in [path / "cgroup.procs", *path.rglob("*/cgroup.procs")]
                for pid in file.read_text().split()}
        for pid in sorted(pids):
            try:
                proc = proc_root / str(pid)
                status = dict(line.split(":", 1) for line in (proc / "status").read_text().splitlines()
                              if ":" in line)
                if any(int(value) != uid for value in status["Uid"].split()):
                    continue
                groups = [line[3:] for line in (proc / "cgroup").read_text().splitlines()
                          if line.startswith("0::")]
                if len(groups) != 1 or not (groups[0] == group or groups[0].startswith(group + "/")):
                    continue
                comm = (proc / "comm").read_text().strip()
                if not comm.startswith("ProjectZomboid"):
                    if comm != "java" or b"zombie.network.GameServer" not in (proc / "cmdline").read_bytes():
                        continue
                rss = int(status.get("VmRSS", "0 kB").split()[0])
                if rss > best_rss:
                    best, best_rss = pid, rss
            except (OSError, KeyError, ValueError):
                continue  # Processus disparu ou identité illisible : jamais de repli global.
    except (OSError, ValueError):
        return None
    return best


def find_jvm(unit, states=("active",), cgroup_root=Path("/sys/fs/cgroup"), proc_root=Path("/proc")):
    try:
        before = identity(unit, states)
        pid = find_in_group(before[2], os.getuid(), cgroup_root, proc_root)
        return pid if before == identity(unit, states) else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("unit")
    args = parser.parse_args()
    pid = find_jvm(args.unit)
    if pid is None:
        raise SystemExit(1)
    print(pid)
