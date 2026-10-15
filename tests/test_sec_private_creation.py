#!/usr/bin/env python3
"""Création privée concurrente : fonctions extraites, fichiers jetables seulement."""
import concurrent.futures
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'data/scripts/lib'
FUNCTIONS = {
    'private_state_path': ('common.sh', 'marker'),
    'world_lock_path': ('world_lock.sh', 'world.lock'),
    'serverctl_lock_path': ('common.sh', 'serverctl.lock'),
}


class PrivateCreationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.functions = {}
        for name, (filename, _) in FUNCTIONS.items():
            matches = re.findall(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}',
                                 (LIB / filename).read_text(), re.MULTILINE | re.DOTALL)
            if len(matches) != 1:
                raise AssertionError(f'Fonction unique introuvable : {name}')
            cls.functions[name] = matches[0]

    def invoke(self, name, runtime, before=''):
        script = self.functions[name] + '\n' + before + '\n' + name
        if name == 'private_state_path':
            script += ' marker'
        env = dict(PATH='/usr/bin:/bin', HOME=str(runtime.parent),
                   XDG_RUNTIME_DIR=str(runtime), LC_ALL='C')
        return subprocess.run(['/bin/bash', '-e', '-u', '-o', 'pipefail', '-c', script],
                              env=env, cwd=runtime.parent, text=True,
                              capture_output=True, timeout=10)

    def exercise(self, name, scenario='normal'):
        # /tmp est sticky ; ne jamais prendre le chemin d'état réel du compte.
        with tempfile.TemporaryDirectory(prefix='pz-private-create-', dir='/tmp') as tmp:
            base = Path(tmp)
            runtime = base / 'runtime avec espaces'
            runtime.mkdir(mode=0o700)
            outside = base / 'outside'
            outside.mkdir(mode=0o750)
            sentinel = outside / 'sentinel'
            sentinel.write_text('inchange\n')
            state = runtime / 'pzmanager'
            before = ''
            if scenario == 'concurrent':
                # Reproduire exactement EEXIST après le test d'existence : un
                # autre processus légitime a gagné la création du répertoire.
                before = 'mkdir() { command mkdir "$@" || return; command mkdir "$@"; }'
            elif scenario in {'symlink', 'file', 'fifo', 'absent', 'foreign'}:
                action = {
                    'symlink': 'command ln -s -- "$HOME/outside" "${!#}"',
                    'file': 'printf hostile > "${!#}"',
                    'fifo': 'command mkfifo -- "${!#}"',
                    'absent': ':',
                    'foreign': 'command mkdir "$@" && command chown 65534 -- "${!#}"',
                }[scenario]
                before = 'mkdir() { ' + action + '; return 1; }'
            elif scenario == 'chmod-failure':
                before = 'chmod() { return 13; }'
            elif scenario == 'unsafe-parent':
                runtime.chmod(0o777)
            elif scenario.startswith('state-'):
                state.mkdir(mode=0o700)
                target = state / FUNCTIONS[name][1]
                kind = scenario.removeprefix('state-')
                if kind == 'symlink':
                    target.symlink_to(sentinel)
                elif kind == 'hardlink':
                    os.link(sentinel, target)
                elif kind == 'fifo':
                    os.mkfifo(target)
            result = self.invoke(name, runtime, before)
            self.assertEqual(sentinel.read_text(), 'inchange\n')
            self.assertEqual(outside.stat().st_mode & 0o777, 0o750,
                             'chmod ne doit jamais suivre un lien concurrent')
            if scenario in {'normal', 'concurrent'}:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(state / FUNCTIONS[name][1]) + '\n')
                self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            else:
                self.assertNotEqual(result.returncode, 0, scenario)
                self.assertEqual(result.stdout, '', scenario)
            if scenario in {'absent', 'unsafe-parent'}:
                self.assertFalse(state.exists())

    def test_creation_normale(self):
        for name in FUNCTIONS:
            with self.subTest(function=name):
                self.exercise(name)

    def test_creation_concurrente_legitime(self):
        for name in FUNCTIONS:
            with self.subTest(function=name):
                self.exercise(name, 'concurrent')

    def test_creation_concurrente_hostile_ou_absente(self):
        for name in FUNCTIONS:
            for scenario in ('symlink', 'file', 'fifo', 'absent'):
                with self.subTest(function=name, scenario=scenario):
                    self.exercise(name, scenario)

    def test_chmod_en_echec_reste_bloquant(self):
        for name in FUNCTIONS:
            with self.subTest(function=name):
                self.exercise(name, 'chmod-failure')

    def test_parent_remplacable_reste_refuse(self):
        for name in FUNCTIONS:
            with self.subTest(function=name):
                self.exercise(name, 'unsafe-parent')

    def test_fichier_prepositionne_reste_refuse(self):
        for name in FUNCTIONS:
            for kind in ('symlink', 'hardlink', 'fifo'):
                with self.subTest(function=name, kind=kind):
                    self.exercise(name, 'state-' + kind)

    @unittest.skipUnless(os.geteuid() == 0, 'Le changement de propriétaire exige root dans le bac jetable')
    def test_createur_etranger_reste_refuse(self):
        for name in FUNCTIONS:
            with self.subTest(function=name):
                self.exercise(name, 'foreign')

    def test_appels_repetes_et_createurs_reels(self):
        with tempfile.TemporaryDirectory(prefix='pz-private-parallel-', dir='/tmp') as tmp:
            runtime = Path(tmp) / 'runtime'
            runtime.mkdir(mode=0o700)
            names = list(FUNCTIONS) * 4
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                results = list(pool.map(lambda name: self.invoke(name, runtime), names))
            for name, result in zip(names, results):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(runtime / 'pzmanager' / FUNCTIONS[name][1]) + '\n')
            self.assertEqual((runtime / 'pzmanager').stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
