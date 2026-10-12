"""Capturer une fermeture lente avant SIGKILL, sans modifier le délai d'arrêt."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import select
import signal
import subprocess
import sys
import tempfile
import time

from console_command import write_fifo
from service_process import identity, find_in_group


def same(unit, expected):
    try:
        return identity(unit, ("deactivating",)) == expected
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def resolve_jcmd(candidate):
    candidates = [candidate, shutil.which("jcmd"), *Path("/usr/lib/jvm").glob("*/bin/jcmd")]
    return next((str(p) for p in candidates if p and Path(p).is_file() and os.access(p, os.X_OK)), None)


def wait_until_slow(unit, expected, delay):
    # pidfd signale la fin immédiatement : ne pas laisser une sleep maintenir
    # le cgroup vivant après la fin normale du MainPID (shell ou JVM).
    try:
        fd = os.pidfd_open(expected[1])
    except OSError:
        return False
    try:
        deadline = time.monotonic() + delay
        while time.monotonic() < deadline:
            if not same(unit, expected):
                return False
            if select.select([fd], [], [], min(1, max(0, deadline - time.monotonic())))[0]:
                return False
        return same(unit, expected)
    finally:
        os.close(fd)


def capture_threads(jcmd, pid, output, unit, expected):
    main_fd = os.pidfd_open(expected[1])
    tool = None
    try:
        if not same(unit, expected) or select.select([main_fd], [], [], 0)[0]:
            return
        tool = subprocess.Popen([jcmd, str(pid), "Thread.print", "-l"], stdout=output,
                                stderr=subprocess.STDOUT, close_fds=True, start_new_session=True)
        deadline = time.monotonic() + 8
        while tool.poll() is None and time.monotonic() < deadline:
            if select.select([main_fd], [], [], min(.1, max(0, deadline - time.monotonic())))[0]:
                output.write("JVM terminée : arrêt du seul outil de diagnostic.\n")
                break
        if tool.poll() is None:
            output.write("Thread.print interrompu ou délai de 8s atteint.\n")
    finally:
        if tool is not None and tool.poll() is None:
            # Nouvelle session réservée à jcmd : ces signaux ne peuvent viser
            # ni la JVM PZ ni un processus qui hérite de WORLD/SERVERCTL.
            try:
                os.killpg(tool.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            tool.wait(timeout=1)
        os.close(main_fd)


def watch(unit, expected, logs, jcmd, delay=60):
    if not wait_until_slow(unit, expected, delay):
        return
    # Les répertoires logs sont déjà gérés par l'installation ; jamais de mkdir
    # ni d'écriture hors de ce répertoire privé et possédé par le manager.
    if logs.is_symlink() or not logs.is_dir() or logs.stat().st_uid != os.getuid():
        raise ValueError("Répertoire de diagnostics d'arrêt invalide")
    fd, name = tempfile.mkstemp(prefix="stop-stall-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") ,
                                suffix=".txt", dir=logs)
    with os.fdopen(fd, "w") as output:
        output.write(f"Fermeture PZ au-delà de {delay}s ; invocation {expected[0]}\n")
        output.flush()
        for sample in range(2):
            if not same(unit, expected):
                output.write("Invocation terminée ou changée : capture interrompue.\n")
                return
            pid = find_in_group(expected[2], os.getuid())
            output.write(f"Capture {sample + 1}, JVM {pid}\n")
            if pid is None:
                output.write("JVM de l'unité indisponible ; aucune cible de remplacement.\n")
                return
            for field in ("status", "wchan", "stack"):
                try:
                    output.write(f"--- /proc/{pid}/{field} ---\n" + Path(f"/proc/{pid}/{field}").read_text() + "\n")
                except OSError as error:
                    output.write(f"{field} indisponible : {error}\n")
            if not same(unit, expected):
                output.write("Invocation changée avant jcmd ; diagnostic abandonné.\n")
                return
            output.flush()
            if jcmd:
                try:
                    capture_threads(jcmd, pid, output, unit, expected)
                except (OSError, subprocess.SubprocessError) as error:
                    output.write(f"Thread.print indisponible : {error}\n")
            else:
                output.write("jcmd absent : aucun thread dump disponible.\n")
            if sample == 0 and not wait_until_slow(unit, expected, 2):
                output.write("JVM terminée avant la seconde capture.\n")
                return
    print(f"Diagnostic de fermeture lente capturé : {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["stop", "watch"])
    parser.add_argument("--unit", required=True)
    parser.add_argument("--pipe", type=Path)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--jcmd", default="")
    parser.add_argument("--invocation")
    parser.add_argument("--main-pid", type=int)
    parser.add_argument("--group")
    args = parser.parse_args()
    try:
        if args.action == "stop":
            # Une sortie spontanée appelle aussi ExecStop avec MainPID=0 :
            # aucune JVM n'attend quit, ne rien mettre en tampon pour le boot.
            try:
                expected = identity(args.unit, ("deactivating",), allow_zero=True)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                expected = None
                print(f"Identité du diagnostic indisponible : {error}", file=sys.stderr)
            if expected and expected[1] == 0:
                return 0
            if args.pipe is None:
                raise ValueError("FIFO requis pour l'arrêt")
            write_fifo(args.pipe, "quit", 10)
            if expected is None:
                return 0  # Le diagnostic optionnel ne doit jamais empêcher quit.
            # Aucun FD monde hérité, aucun worker en dehors du budget de l'unité.
            # Le moniteur quitte dès MainPID=0 ; il ne prolonge pas un arrêt sain.
            try:
                subprocess.Popen([sys.executable, __file__, "watch", "--unit", args.unit,
                                  "--logs", str(args.logs), "--jcmd", args.jcmd,
                                  "--invocation", expected[0], "--main-pid", str(expected[1]),
                                  "--group", expected[2]], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 close_fds=True, start_new_session=True)
            except OSError as error:
                print(f"Moniteur d'arrêt indisponible après quit : {error}", file=sys.stderr)

        else:
            expected = (args.invocation, args.main_pid, args.group)
            watch(args.unit, expected, args.logs, resolve_jcmd(args.jcmd))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Diagnostic d'arrêt PZ : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
