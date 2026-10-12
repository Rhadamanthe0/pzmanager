"""Commande FIFO bornée et réponse liée à l'invocation systemd courante."""
import argparse
import errno
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

from service_process import identity


def game_line(line):
    """Retirer seulement un préfixe connu du journal du jeu, sans texte arbitraire."""
    prefix = re.fullmatch(
        r"(LOG|WARN|ERROR)\s*:\s*([A-Za-z]+)\s+"
        r"(?:f:[0-9]+\s+st:[0-9,\s]+|,\s*[0-9]+)>\s*(.*)", line)
    return (prefix[3], prefix[1], prefix[2]) if prefix else (line, None, None)


def console_echo(line):
    body, level, channel = game_line(line)
    if channel is not None and (level != 'LOG' or channel != 'General'):
        return None
    marker = re.fullmatch(r'command entered via server console \(System.in\): "(.*)"', body)
    return marker[1] if marker else None


def command_received(text, command):
    """Un écho exact prouve la lecture du FIFO, pas la fin du contrôle asynchrone."""
    return any(console_echo(line) == command for line in text.splitlines())


def response(text, command):
    capture = False
    lines = []
    for line in text.splitlines():
        marker = console_echo(line)
        if marker is not None:
            if capture:
                break
            capture = marker == command
            continue
        if not capture or re.search(r"ConnectionManager:|ChatMessage\{|User:.*is trying to connect", line):
            continue
        body, level, channel = game_line(line)
        # Un message Lua ressemblant au statut Workshop n'est pas son résultat.
        if command == "checkModsNeedUpdate" and channel is not None and (level != 'LOG' or channel != 'Mod'):
            continue
        if body.strip():
            lines.append(body)
    if command == "players":
        # Une ligne de jeu intercalée ne constitue pas une réponse au comptage.
        start = next((i for i, line in enumerate(lines)
                      if re.search(r"Players connected \([0-9]+\):", line)), None)
        if start is None:
            return ""
        lines = lines[start:]
    if command == "checkModsNeedUpdate":
        # « Checking... » accuse réception ; seul le statut final est un résultat.
        final = [line for line in lines if re.fullmatch(
            r"CheckModsNeedUpdate:\s*(?:Mods need update|Mods updated)\s*", line,
            re.IGNORECASE)]
        if not final or len({line.lower() for line in final}) != 1:
            return ""
        lines = final
    return "\n".join(lines)


def write_fifo(pipe, command, timeout):
    payload = (command + "\n").encode()
    deadline = time.monotonic() + timeout
    while True:
        try:
            fd = os.open(pipe, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except OSError as error:
            if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                raise
        else:
            try:
                if not stat.S_ISFIFO(os.fstat(fd).st_mode):
                    raise ValueError("Le contrôle PZ doit être un FIFO")
                if len(payload) > os.fpathconf(fd, "PC_PIPE_BUF"):
                    raise ValueError("Commande trop longue pour une écriture FIFO atomique")
                try:
                    if os.write(fd, payload) != len(payload):
                        raise ValueError("Écriture FIFO incomplète")
                    return
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise
            finally:
                os.close(fd)
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def execute(unit, pipe, command, write_timeout=10, output_timeout=8, no_output=False):
    before = identity(unit)
    stamp = time.time()
    write_fifo(pipe, command, write_timeout)
    if no_output:
        return f"Commande envoyée: {command}"
    deadline = time.monotonic() + output_timeout
    received = False
    while time.monotonic() < deadline:
        left = deadline - time.monotonic()
        result = subprocess.run(["journalctl", "--user", "--since", f"@{stamp:.6f}",
                                 "--no-pager", "-o", "cat",
                                 f"_SYSTEMD_INVOCATION_ID={before[0]}", "+",
                                 f"INVOCATION_ID={before[0]}"], capture_output=True,
                                text=True, check=True, timeout=min(2, left))
        output = response(result.stdout, command)
        received = received or command_received(result.stdout, command)
        if before != identity(unit, timeout=min(2, max(0.001, deadline - time.monotonic()))):
            raise ValueError("Invocation PZ changée pendant la commande")
        if output:
            return output
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    if command == "checkModsNeedUpdate" and received:
        return f"Commande reçue: {command} (aucun statut final capturé dans le délai borné)"
    return f"Commande envoyée: {command} (aucune sortie capturée dans le délai borné)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--pipe", required=True, type=Path)
    parser.add_argument("--write-timeout", type=float, default=10)
    parser.add_argument("--output-timeout", type=float, default=8)
    parser.add_argument("--no-output", action="store_true")
    parser.add_argument("command")
    args = parser.parse_args()
    try:
        if not 0 < args.write_timeout <= 30 or not 0 < args.output_timeout <= 30:
            raise ValueError("Les délais console doivent être compris entre 0 et 30 secondes")
        if not args.command or "\n" in args.command or "\r" in args.command:
            raise ValueError("Une commande console unique est requise")
        print(execute(args.unit, args.pipe, args.command, args.write_timeout,
                      args.output_timeout, args.no_output))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Commande PZ refusée : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
