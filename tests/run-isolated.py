#!/usr/bin/env python3
"""Exécuter toutes les suites dans une copie privée, jamais dans le Home actif.

Les anciens tests de métier ne simulent pas encore un cgroup : seule leur copie
locale du lecteur budget pointe vers des fichiers privés validés réellement.
Les suites du budget/routage/admission lisent le code original sans substitution.
Aucun drapeau de contournement n'est ajouté aux scripts de production.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    # Le protocole WORLD refuse tout ancêtre inscriptible par le groupe.
    # Garder les copies et fixtures privées même avec un umask appelant à 002.
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--only', action='append', help='Run a named suite (repeatable)')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
    args.results.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Les helpers privilégiés exigent aussi des ancêtres root non modifiables.
    # /var/tmp convient au manager, mais son mode sticky reste refusé en root.
    temporary_parent = '/run' if os.geteuid() == 0 else '/var/tmp'
    with tempfile.TemporaryDirectory(prefix='pz-tests-isolated-', dir=temporary_parent) as temporary:
        base = Path(temporary); root = base / 'repository'; root.mkdir()
        for name in names:
            if not name: continue
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts: raise ValueError('Chemin Git invalide')
            src = source / relative; dst = root / relative
            if src.is_file() and "__pycache__" not in relative.parts:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                if os.geteuid() == 0:
                    # Reproduire les droits du staging root, sans dépendre de
                    # l'umask du checkout source et sans changer son contenu.
                    dst.chmod(dst.stat().st_mode & ~0o022)
        # Même interprétation et mêmes contrôles, seuls les fichiers de preuve
        # du banc legacy sont substitués dans CETTE copie jetable.
        helper = root / 'data/scripts/lib/shared_memory_budget.py'
        original = helper.read_text()
        proc = base / 'proc-cgroup'; cg = base / 'cgroups'
        group = '/user.slice/user-1005.slice/user@1005.service/pz.slice'
        proc.write_text('0::' + group + '/fixture.scope\n')
        parent = cg / group.lstrip('/'); parent.mkdir(parents=True)
        for name, value in {'memory.max': str(20 * 2**30), 'memory.swap.max': '0', 'memory.current': '0'}.items():
            (parent / name).write_text(value)
        fixture = original.replace('Path("/proc/self/cgroup")', 'Path(' + repr(str(proc)) + ')').replace('Path("/sys/fs/cgroup")', 'Path(' + repr(str(cg)) + ')')
        test_home, test_runtime = base / 'home', base / 'runtime'
        test_home.mkdir(mode=0o700)
        test_runtime.mkdir(mode=0o700)
        env = dict(os.environ)
        # Isoler aussi les fichiers de démarrage et les verrous des enfants.
        # Héritage d'un vrai verrou/répertoire d'état interdit dans le banc.
        for key in list(env):
            if key.startswith(('PZ_', 'DISCORD_', 'BACKUP_', 'LOG_', 'STEAM_')) or key in {'BASH_ENV', 'ENV', 'XDG_RUNTIME_DIR', 'SSH_CLIENT', 'SSH_CONNECTION', 'SSH2_CLIENT'}: env.pop(key)
        env.update(PZ_TEST_ROOT=str(root), TMPDIR=str(base),
                   HOME=str(test_home), XDG_RUNTIME_DIR=str(test_runtime))
        results = []
        for test in sorted((root / 'tests').glob('test_*')):
            if test.suffix not in {'.py', '.sh'} or (args.only and test.name not in args.only): continue
            boundary_suite = test.name.startswith(('test_shared_', 'test_jvm_memory_', 'test_writing_', 'test_console_')) and test.name != 'test_writing_start_admission.py'
            helper.write_text(original if boundary_suite else fixture)
            start = time.monotonic()
            command = ['python3' if test.suffix == '.py' else 'bash', str(test)]
            with (args.results / (test.name + '.log')).open('w') as output:
                process = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL); process.wait()
                    output.write('\nSuite timed out after 180 seconds; process group terminated.\n')
                    code = 124
            results.append(dict(test=test.name, exit=code, seconds=round(time.monotonic() - start, 2),
                                budget_source='original' if boundary_suite else 'private fixture paths only'))
            (args.results / 'results.json').write_text(json.dumps(results, indent=2))
            print(test.name, code, flush=True)
        helper.write_text(original)
        failures = [row['test'] for row in results if row['exit']]
        (args.results / 'summary.json').write_text(json.dumps(dict(suites=len(results), failures=failures,
            helper_sha256=hashlib.sha256(original.encode()).hexdigest(), production_mutations=False), indent=2))
        print('Suites', len(results), 'échecs', failures, flush=True)
        return int(bool(failures))


if __name__ == '__main__': raise SystemExit(main())
