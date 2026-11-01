#!/usr/bin/env python3
"""FIFO des demandes vivantes de démarrage, arrêt et redémarrage.

Le mutex de registre n'est jamais détenu pendant l'attente WORLD. Les tâches
automatiques restent coordonnées par WORLD ; aucune demande morte n'est rejouée.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'internal'))
from writing_start_admission import (ConfigurationError, LAUNCH_KEYS, atomic_file, directory,
                                     launch_profile, live, process_birth,
                                     runtime_lock_path)

STATE = 'server-actions.json'
LIMIT = 1024 * 1024
LABELS = {'start': 'Démarrage', 'stop': 'Arrêt', 'restart': 'Redémarrage'}


def checked_file(parent, name, flags, private=True):
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or (private and info.st_mode & 0o077)):
        os.close(fd)
        raise ConfigurationError('État de la file non sûr')
    return fd


class Queue:
    def __init__(self, timeout):
        self.path = runtime_lock_path()
        _, self.parent = directory(self.path)
        self.mutex = checked_file(self.parent, 'server-actions.lock', os.O_RDWR | os.O_CREAT)
        self.world = checked_file(self.parent, self.path.name, os.O_RDWR | os.O_CREAT, private=False)
        self.deadline = time.monotonic() + timeout
        self.identity = {'pid': os.getpid(), 'birth': process_birth(os.getpid())}

    def close(self):
        for fd in (self.world, self.mutex, self.parent):
            os.close(fd)

    @contextlib.contextmanager
    def registry(self):
        # Le registre ne doit pas bloquer indéfiniment une annulation.
        while True:
            try:
                fcntl.flock(self.mutex, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                self.check_deadline()
                time.sleep(.1)
        try:
            raw = None
            try:
                fd = checked_file(self.parent, STATE, os.O_RDONLY)
            except FileNotFoundError:
                jobs = []
            else:
                with os.fdopen(fd, 'rb') as stream:
                    raw = stream.read(LIMIT + 1)
                if len(raw) > LIMIT:
                    raise ConfigurationError('File trop volumineuse')
                jobs = json.loads(raw)
                self.validate(jobs)
            for job in jobs:
                job['waiters'] = [w for w in job['waiters'] if live(w['pid'], w['birth'])]
                if job['state'] != 'done' and not live(job['owner']['pid'], job['owner']['birth']):
                    summary = ('Demande interrompue ; les actions déjà engagées peuvent avoir eu un effet. Aucune reprise automatique.'
                               if job['state'] == 'running' else 'Demande interrompue ; aucune reprise automatique.')
                    job.update(state='done', code=130, summary=summary)
            jobs[:] = [job for job in jobs if job['waiters']]
            yield jobs
            if len(jobs) > 1024 or any(len(job['waiters']) > 1024 for job in jobs):
                raise ConfigurationError('File pleine ; réessayer après les demandes en cours.')
            self.validate(jobs)
            payload = json.dumps(jobs, ensure_ascii=False).encode()
            if len(payload) > LIMIT:
                raise ConfigurationError('File pleine ; réessayer après les demandes en cours.')
            if payload != raw:
                atomic_file(self.parent, STATE, payload, 0o600)
        finally:
            fcntl.flock(self.mutex, fcntl.LOCK_UN)

    @staticmethod
    def validate(jobs):
        if not isinstance(jobs, list) or len(jobs) > 1024:
            raise ConfigurationError('Registre de file invalide')
        for job in jobs:
            if (not isinstance(job, dict) or set(job) != {'id', 'action', 'scope', 'owner', 'waiters', 'state', 'code', 'summary'}
                    or job['action'] not in LABELS or job['state'] not in {'pending', 'running', 'done'}
                    or not isinstance(job['id'], str) or len(job['id']) != 32
                    or not isinstance(job['scope'], str) or len(job['scope']) != 64
                    or not isinstance(job['waiters'], list) or len(job['waiters']) > 1024
                    or type(job['code']) is not int or not 0 <= job['code'] <= 255 or not isinstance(job['summary'], str)
                    or len(job['summary']) > 512):
                raise ConfigurationError('Demande de file invalide')
            for identity in [job['owner'], *job['waiters']]:
                if (not isinstance(identity, dict) or set(identity) != {'pid', 'birth'}
                        or any(type(identity[k]) is not int or identity[k] < 1 for k in identity)):
                    raise ConfigurationError('Propriétaire de demande invalide')

    def check_deadline(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('Attente expirée ; la demande est annulée, elle ne sera pas exécutée plus tard.')

    def take_world(self):
        # L'inode ouvert doit toujours être celui du chemin partagé, y compris
        # après l'acquisition. Aucun remplacement ni suppression de WORLD.
        before = os.stat(self.path.name, dir_fd=self.parent, follow_symlinks=False)
        opened = os.fstat(self.world)
        if ((before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
                or not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1):
            raise ConfigurationError('Identité de la protection du monde modifiée')
        try:
            fcntl.flock(self.world, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        after = os.stat(self.path.name, dir_fd=self.parent, follow_symlinks=False)
        if ((after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
                or after.st_uid != os.getuid() or after.st_nlink != 1):
            fcntl.flock(self.world, fcntl.LOCK_UN)
            raise ConfigurationError('Identité de la protection du monde modifiée')
        return True

    def remove_waiter(self, token, interrupted=False, code=130, summary='Demande interrompue ; aucune reprise automatique.'):
        # Un délai expiré n'empêche pas le nettoyage du registre.
        self.deadline = time.monotonic() + 5
        with self.registry() as jobs:
            for job in jobs:
                if job['id'] == token:
                    job['waiters'] = [w for w in job['waiters'] if w != self.identity]
                    if interrupted and job['owner'] == self.identity and job['state'] != 'done':
                        job.update(state='done', code=code, summary=summary)


def run(command, timeout):
    action = command[1]
    label = LABELS[action]
    # L'arrêt reste disponible avec une configuration native incohérente,
    # comme source_env --stop ; son empreinte ne donne aucun droit d'écriture.
    profile = ({key: os.environ.get(key, '') for key in LAUNCH_KEYS}
               if action == 'stop' else launch_profile())
    profile['service'] = os.environ.get('PZ_SERVICE_NAME', 'zomboid.service')
    profile['script'] = str(Path(command[0]).resolve())
    scope = hashlib.sha256(json.dumps(profile, sort_keys=True).encode()).hexdigest()
    queue = Queue(timeout)
    token = None
    worker = None
    leader = True
    interrupted = True
    failure_code = 130
    failure_summary = 'Demande interrompue ; aucune reprise automatique.'
    try:
        with queue.registry() as jobs:
            active = [j for j in jobs if j['state'] != 'done']
            if (action == 'restart' and active and active[-1]['action'] == action
                    and active[-1]['scope'] == scope):
                job = active[-1]
                job['waiters'].append(queue.identity)
                leader = False
            else:
                job = dict(id=uuid.uuid4().hex, action=action, scope=scope,
                           owner=queue.identity, waiters=[queue.identity],
                           state='pending', code=0, summary='')
                jobs.append(job)
                leader = True
            token = job['id']
        if not leader:
            print('ℹ️ Redémarrage regroupé avec la demande déjà reçue ; son délai et son motif sont conservés.', flush=True)
        announced = False
        running_announced = False
        while True:
            with queue.registry() as jobs:
                job = next(j for j in jobs if j['id'] == token)
                if job['state'] == 'done':
                    print(('ℹ️ Résultat du redémarrage partagé : ' if not leader else '') + job['summary'], flush=True)
                    interrupted = False
                    return job['code']
                if job['state'] == 'running':
                    queue.deadline = float('inf')
                else:
                    queue.check_deadline()
                running = job['state'] == 'running'
                head = next(j for j in jobs if j['state'] != 'done')['id'] == token
            if not leader and running and not running_announced:
                print('▶️ Redémarrage partagé en cours.', flush=True)
                running_announced = True
            if leader and head and queue.take_world():
                break
            if not running and not announced:
                print(f'⏳ {label} en attente : une autre opération est en cours. La demande sera exécutée automatiquement.', flush=True)
                announced = True
            time.sleep(.2)
        with queue.registry() as jobs:
            next(j for j in jobs if j['id'] == token)['state'] = 'running'
        queue.deadline = float('inf')
        print(f'▶️ {label} en cours.', flush=True)
        env = dict(os.environ, PZ_WORLD_LOCK_FD=str(queue.world), PZ_WORLD_LOCK_DEPTH='1')
        worker = subprocess.Popen(['bash', *command], env=env, pass_fds=(queue.world,))
        code = worker.wait()
        code = code if code >= 0 else 128 - code
        summary = f'{label} terminé.' if code == 0 else f'{label} échoué (code {code}) ; consulter le diagnostic de la demande initiale.'
        with queue.registry() as jobs:
            next(j for j in jobs if j['id'] == token).update(state='done', code=code, summary=summary)
        interrupted = False
        return code
    except (TimeoutError, InterruptedError) as error:
        failure_code = 124 if isinstance(error, TimeoutError) else 130
        failure_summary = ('Attente expirée ; la demande est annulée, elle ne sera pas exécutée plus tard.'
                           if failure_code == 124 else 'Demande interrompue ; aucune reprise automatique.')
        if token is not None and not leader:
            raise type(error)('Votre attente est interrompue ; le redémarrage partagé peut continuer pour les autres demandes.') from error
        if worker is not None:
            failure_summary = 'Demande interrompue ; les actions déjà engagées peuvent avoir eu un effet. Aucune reprise automatique.'
            raise type(error)(failure_summary) from error
        raise
    except (OSError, ValueError, TypeError, ConfigurationError, KeyError, StopIteration):
        failure_code = 1
        failure_summary = f'{label} échoué ; consulter le diagnostic de la demande initiale.'
        raise
    finally:
        if worker is not None and worker.poll() is None:
            worker.terminate()
            try: worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()
        try:
            if token is not None:
                queue.remove_waiter(token, interrupted, failure_code, failure_summary)
        except TimeoutError:
            detail = ('les actions déjà engagées peuvent continuer. Aucun rejeu automatique.'
                      if interrupted else "le résultat de l'action est conservé.")
            print('ℹ️ Nettoyage de la file différé ; ' + detail, flush=True)
        finally:
            queue.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == '--': command = command[1:]
    if len(command) < 2 or command[1] not in LABELS:
        parser.error('script et action serveur requis')
    try:
        timeout = int(os.environ.get('PZ_SERVER_QUEUE_TIMEOUT', '1800'))
        if not 1 <= timeout <= 86400:
            raise ValueError('Délai de file invalide')
        if 'PZ_SERVER_QUEUE_REMAINING' in os.environ:
            remaining = int(os.environ['PZ_SERVER_QUEUE_REMAINING'])
            if not 1 <= remaining <= 86400:
                raise ValueError('Délai de file restant invalide')
            timeout = min(timeout, remaining)
        def cancel(signum, frame):
            raise InterruptedError('Demande annulée ; aucune exécution différée.')
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        return run(command, timeout)
    except (OSError, ValueError, TypeError, ConfigurationError, KeyError, StopIteration) as error:
        print('ERREUR : ' + str(error), file=sys.stderr)
        return 130 if isinstance(error, InterruptedError) else 124 if isinstance(error, TimeoutError) else 1


if __name__ == '__main__':
    sys.exit(main())
