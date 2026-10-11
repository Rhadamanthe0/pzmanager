"""Archive puis pose seulement la slice et ses drop-ins, avec CAS des fichiers."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

UNITS = ["zomboid.service", "zomboid_logger.service", "pz-discord-bot.service",
         "pz-backup.service", "pz-maintenance.service", "pz-modcheck.service",
         "pz-heapcheck.service", "pz-stallwatch.service", "pz-creation-date-init.service"]
GUARD = ("[Service]\nSlice=pz.slice\n"
         "ExecStartPre=/usr/bin/python3 %h/pzmanager/data/scripts/lib/shared_memory_budget.py check\n")


def snapshot(path):
    if not path.exists() and not path.is_symlink():
        return None
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Fichier non régulier ou propriétaire inattendu : {path}")
    data = path.read_bytes()
    return dict(sha256=hashlib.sha256(data).hexdigest(), inode=info.st_ino,
                device=info.st_dev, uid=info.st_uid, gid=info.st_gid,
                mode=stat.S_IMODE(info.st_mode))


def install(templates, unit_dir, archive_root):
    # Refuser AVANT toute copie, pas tenter de déplacer un processus vivant.
    for unit in [*UNITS, "zomboid.socket"]:
        result = subprocess.run(["systemctl", "--user", "show", unit, "-p", "ActiveState", "--value"],
                                capture_output=True, text=True, timeout=5, check=True)
        if result.stdout.strip() not in {"inactive", "failed"}:
            raise ValueError(f"Arrêter le service/socket avant migration : {unit}")
    if not (unit_dir / "zomboid.service").is_file():
        raise ValueError("Unité jeu absente : effectuer d'abord le bootstrap serveur.")
    targets = {unit_dir / "pz.slice": (templates / "pz.slice").read_bytes()}
    for unit in UNITS:
        if (unit_dir / unit).exists():
            targets[unit_dir / (unit + ".d") / "90-pz-shared-budget.conf"] = GUARD.encode()
    if (unit_dir / "zomboid.socket").exists():
        targets[unit_dir / "zomboid.socket.d" / "90-pz-shared-budget.conf"] = b"[Socket]\nSlice=pz.slice\n"
    # Les anciens réglages restent en place et sont archivés sans être écrasés.
    paths = set(targets)
    for unit in [*UNITS, "zomboid.socket"]:
        paths.add(unit_dir / unit)
        paths.update((unit_dir / (unit + ".d")).glob("*.conf"))
    before = {path: snapshot(path) for path in paths}
    archive_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    if archive_root.is_symlink() or archive_root.stat().st_uid != os.getuid():
        raise ValueError("Répertoire d'archive privé invalide.")
    archive_root.chmod(0o700)
    archive = Path(tempfile.mkdtemp(prefix="shared-budget-", dir=archive_root))
    rows = []
    for index, path in enumerate(sorted(paths)):
        info = before[path]
        row = dict(path=str(path), before=info)
        if info is not None:
            dest = archive / f"original-{index:02d}"
            dest.write_bytes(path.read_bytes())
            dest.chmod(0o600)
            if hashlib.sha256(dest.read_bytes()).hexdigest() != info["sha256"]:
                raise ValueError("Source modifiée pendant archivage.")
            row["archive"] = str(dest)
        rows.append(row)
    manifest = archive / "manifest.json"
    manifest.write_text(json.dumps(dict(rows=rows, applied=[]), indent=2))
    manifest.chmod(0o600)
    applied = []
    for path, data in targets.items():
        # CAS complet avant CHAQUE mutation ; après nos écritures, mettre à jour
        # la référence attendue pour ne pas confondre notre modification et autrui.
        if any(snapshot(p) != expected for p, expected in before.items()):
            raise ValueError("Modification concurrente : arrêt, archive et journal partiel conservés.")
        if path.parent.is_symlink():
            raise ValueError("Répertoire drop-in symbolique refusé.")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as staged:
            tmp = Path(staged.name)
            staged.write(data)
            staged.flush()
            os.fsync(staged.fileno())
        try:
            if any(snapshot(p) != expected for p, expected in before.items()):
                raise ValueError("Modification concurrente avant rename : refus.")
            if before[path]:
                os.chown(tmp, before[path]["uid"], before[path]["gid"])
            tmp.chmod(before[path]["mode"] if before[path] else 0o644)
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)
        before[path] = snapshot(path)
        applied.append(str(path))
        manifest.write_text(json.dumps(dict(rows=rows, applied=applied), indent=2))
    return archive


if __name__ == "__main__":
    try:
        if os.getuid() == 0:
            raise ValueError("Exécuter comme manager PZ, pas root.")
        print(install(*(Path(arg) for arg in sys.argv[1:])))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Migration budget PZ refusée : {error}", file=sys.stderr)
        sys.exit(1)
