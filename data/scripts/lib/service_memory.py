"""RSS agrégé d'un cgroup ; le CLI mesure uniquement le parent PZ partagé."""
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


def service_nonfile_rss_bytes(control_group, cgroup_root="/sys/fs/cgroup", proc_root="/proc"):
    """RSS anonyme + shmem des processus PZ ; exclut les pages file-backed récupérables.

    Indicateur d'affichage uniquement : ne modifie pas le RSS utilisé par le
    redémarrage préventif. Contrairement à VmRSS, RssAnon + RssShmem n'inclut
    pas RssFile (mappings de fichiers récupérables).
    """
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
                continue  # Processus terminé pendant la collecte.
            values = {}
            for line in status.splitlines():
                key, sep, raw = line.partition(":")
                if sep and key in ("RssAnon", "RssShmem"):
                    values[key] = int(raw.split()[0]) * 1024
            if "RssAnon" not in values or "RssShmem" not in values:
                return None  # Ne jamais remplacer par un VmRSS incluant du cache.
            total += values["RssAnon"] + values["RssShmem"]
        return total
    except (OSError, ValueError, IndexError):
        return None


if __name__ == "__main__":
    from shared_memory_budget import validate_slice, slice_group
    try:
        validate_slice(sys.argv[1])
        value = service_rss_bytes(slice_group(sys.argv[1]))
    except (OSError, ValueError):
        value = None
    if value is None:
        sys.exit(1)
    print(value)
