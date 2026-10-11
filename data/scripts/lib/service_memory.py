"""RAM résidente des processus d'un service, sans son cache disque récupérable."""
from pathlib import Path
import sys


def service_rss_bytes(control_group, cgroup_root="/sys/fs/cgroup", proc_root="/proc"):
    if not control_group.startswith("/") or control_group == "/" or ".." in control_group.split("/"):
        return None
    group = Path(cgroup_root) / control_group.lstrip("/")
    try:
        files = [group / "cgroup.procs", *group.rglob("*/cgroup.procs")]
        pids = {int(pid) for f in files for pid in f.read_text().split()}
        total = 0
        for pid in pids:
            try:
                status = (Path(proc_root) / str(pid) / "status").read_text()
            except FileNotFoundError:
                continue  # Processus terminé entre les deux lectures.
            for line in status.splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1]) * 1024
                    break
        return total
    except (OSError, ValueError):
        return None


if __name__ == "__main__":
    value = service_rss_bytes(sys.argv[1])
    if value is None:
        sys.exit(1)
    print(value)
