#!/usr/bin/env python3
"""Characterize actual process death, only in disposable synthetic Linux worlds.

A passing case asserts the observed interrupted state, NOT crash safety or native
PZ readability. Game readers and service boundaries are explicitly doubled.
No package installation, no production service, no source/recovery mutation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch


def killed_worker(action, log: Path, expected: int = signal.SIGKILL) -> int:
    """Run a forked worker, reap it and require its real signal termination."""
    sys.stdout.flush(); sys.stderr.flush()
    pid = os.fork()
    if pid == 0:
        with log.open('wb') as output:
            os.dup2(output.fileno(), 1); os.dup2(output.fileno(), 2)
            try:
                action()
            except BaseException:
                import traceback
                traceback.print_exc()
                sys.stdout.flush(); sys.stderr.flush()
                os._exit(70)
            sys.stdout.flush(); sys.stderr.flush()
            os._exit(0)
    deadline = time.monotonic() + 20
    while True:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
            break
        if time.monotonic() >= deadline:
            os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
            raise AssertionError('worker timed out, not the expected injected crash')
        time.sleep(.01)
    if expected == signal.SIGKILL:
        assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == expected, (status, log.read_text())
    else:
        # Production main translates TERM into KeyboardInterrupt and rolls back.
        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 70, (status, log.read_text())
    return status


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def zone_case(fixture, phase: str, results: Path) -> dict:
    case = fixture.WorldSafety('test_whole_chunk_success_installs_validated_bytes_only')
    case.setUp()
    try:
        case.args.x2 = 15
        real = fixture.zone.replace_file
        real_write = Path.write_text
        target = case.live / 'map/0/0.bin'
        def replace(source, destination, *args, **kwargs):
            installing = Path(destination) == target and 'staged' in Path(source).parts
            if installing and phase == 'before_first_install':
                os.kill(os.getpid(), signal.SIGKILL)
            result = real(source, destination, *args, **kwargs)
            if installing and phase in {'after_first_install', 'term_after_first_install'}:
                os.kill(os.getpid(), signal.SIGTERM if phase.startswith('term') else signal.SIGKILL)
            if phase.startswith('term') and 'before' in Path(source).parts and Path(destination) == target:
                # Repeated interruptions must remain ignored throughout rollback.
                os.kill(os.getpid(), signal.SIGTERM); os.kill(os.getpid(), signal.SIGINT)
            return result
        def write(path, data, *args, **kwargs):
            if phase == 'before_commit' and path.name == '.manifest.pending' and json.loads(data)['status'] == 'complete':
                os.kill(os.getpid(), signal.SIGKILL)
            return real_write(path, data, *args, **kwargs)
        def action():
            with patch.object(fixture.zone, 'replace_file', replace), patch.object(Path, 'write_text', write):
                if phase.startswith('term'):
                    sys.argv = ['restore-zone', '--live-root', str(case.root/'live'),
                                '--backup-root', str(case.root), '--recovery-root', str(case.recovery),
                                '--staging-root', str(case.root), 'backup', '0', '0', '15', '7', '--apply']
                    fixture.zone.main()
                else:
                    case.run_restore()
        killed_worker(action, results / ('zone-' + phase + '.log'),
                      signal.SIGTERM if phase.startswith('term') else signal.SIGKILL)
        state = fixture.snapshot(case.live)
        changed = sorted(k for k in case.before if state.get(k) != case.before[k])
        expected = {
            'before_first_install': [],
            'after_first_install': ['map/0/0.bin'],
            'before_commit': ['isoregiondata/datachunk_0_0.bin', 'isoregiondata/datachunk_1_0.bin',
                              'map/0/0.bin', 'map/1/0.bin'],
            'term_after_first_install': [],
        }[phase]
        assert changed == expected, (phase, changed)
        assert fixture.snapshot(case.source) == case.backup_before
        case.assert_untouched()
        recovery = next(case.recovery.glob('zone-rollback-*'))
        manifest = json.loads((recovery/'manifest.json').read_text())
        expected_status = 'reverted' if phase.startswith('term') else 'applying'
        assert manifest['status'] == expected_status
        root=case.live.parents[2]
        if phase.startswith('term'):
            fixture.zone.transactions.check_clean(root)
        else:
            with case.assertRaisesRegex(ValueError,'unfinished'):
                fixture.zone.transactions.check_clean(root)
        for entry in manifest['files']:
            for root, key in ((recovery/'before/Saves/Multiplayer/test', 'before_sha256'),
                              (recovery/'staged', 'after_sha256')):
                path = root/entry['path']
                assert (sha(path) if path.exists() else None) == entry[key]
        return dict(scenario='zone:'+phase, manifest=manifest['status'], changed_files=changed,
                    source_unchanged=True, recovery_images_verified=True,
                    native_reader='synthetic protocol double', startup_journal_gate_verified=True)
    finally:
        case.doCleanups()


def writing_case(fixture, phase: str, results: Path) -> dict:
    case = fixture.WritingApplyBoundary('test_corrupt_install_copy_does_not_replace_live')
    case.setUp()
    try:
        real = fixture.writing.atomic_copy
        target = case.world/'map/0/0.bin'
        def copy(destination, source, *args, **kwargs):
            installing = Path(destination) == target
            if installing and phase == 'before_first_install':
                os.kill(os.getpid(), signal.SIGKILL)
            result = real(destination, source, *args, **kwargs)
            if installing and phase == 'after_first_install':
                os.kill(os.getpid(), signal.SIGKILL)
            return result
        def action():
            with patch.object(fixture.writing, 'atomic_copy', copy):
                case.recover()
        killed_worker(action, results/('writing-'+phase+'.log'))
        changed = sorted(k for k,v in case.before.items() if fixture.files(case.world).get(k) != v)
        assert changed == ([] if phase == 'before_first_install' else ['map/0/0.bin'])
        case.assert_pending()
        from world_transaction import check_clean
        with case.assertRaisesRegex(ValueError,'unfinished'):check_clean(case.world)
        assert fixture.files(case.stage/'original') == case.original_copies
        # Explicit test-only resume. Never invoke the production startup path.
        case.recover()
        state = fixture.files(case.world)
        for entry in case.entries:
            assert sha(case.world/entry['path']) == entry['new_sha256']
        for name in ('vehicles.db', 'unrelated.txt'):
            assert state[name] == case.before[name]
        assert fixture.files(case.stage/'original') == case.original_copies
        assert json.loads((case.stage/'manifest.json').read_text())['state'] == 'complete'
        check_clean(case.world)
        return dict(scenario='writing:'+phase, manifest_at_crash='prepared',
                    changed_files_at_crash=changed, explicit_fixture_resume='complete',
                    original_images_unchanged=True, unrelated_sentinels_unchanged=True,
                    native_reader='synthetic protocol double', restart_tested=False)
    finally:
        case.doCleanups()


def full_restore_case(fixture, results: Path) -> dict:
    case = fixture.FullRestorePreflight('test_stopped_existing_live_retains_original_recovery')
    case.setUp()
    try:
        case.live_world()
        (case.backup/'Saves/Multiplayer/test/another.bin').write_bytes(b'another synthetic file')
        before = fixture.snapshot(case.live)
        source = fixture.snapshot(case.backup)
        bin_dir = case.root/'bin'; bin_dir.mkdir()
        rsync = bin_dir/'rsync'
        real_rsync = shutil.which('rsync')
        rsync.write_text('#!'+sys.executable+'\n'+
            'import os,signal,subprocess,sys\nfrom pathlib import Path\n'+
            'source,dest=map(Path,sys.argv[-2:])\n'+
            'if dest==Path(os.environ["PZ_SOURCE_DIR"]):\n'+
            '    rel="Saves/Multiplayer/test/sentinel.bin"\n'+
            '    out=dest/rel;out.parent.mkdir(parents=True,exist_ok=True)\n'+
            '    subprocess.run(['+repr(real_rsync)+',"-a",str(source/rel),str(out)],check=True)\n'+
            '    os.killpg(os.getpgrp(),signal.SIGKILL)\n'+
            'os.execv('+repr(real_rsync)+',['+repr(real_rsync)+']+sys.argv[1:])\n')
        rsync.chmod(0o700)
        env = dict(case.env, PATH=str(bin_dir)+':'+os.environ['PATH'])
        with (results/'full-restore-after-first-file.log').open('wb') as output:
            process = subprocess.Popen(['bash',str(case.script),str(case.backup)], env=env,
                        cwd=case.repo, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait();raise
        assert code == -signal.SIGKILL, code
        recovered = list((case.home/'OLD').glob('ZomboidBROKEN_*'))
        assert len(recovered) == 1
        assert fixture.snapshot(recovered[0]) == before
        assert fixture.snapshot(case.backup) == source
        installed = fixture.snapshot(case.live)
        assert installed == {'Saves/Multiplayer/test/sentinel.bin': source['Saves/Multiplayer/test/sentinel.bin']}
        sys.path.insert(0,str(case.repo/'data/scripts/lib'))
        from world_transaction import check_clean
        with case.assertRaisesRegex(ValueError,'unfinished'):check_clean(case.live)
        stages = list(case.home.glob('.restore-staging-*'))
        assert len(stages) == 1 and fixture.snapshot(stages[0]) == source
        return dict(scenario='full_restore:kill_process_group_after_first_file',
                    exit=code, current_directory='incomplete', recovery_old='intact',
                    staging='intact', backup_source='unchanged', restart_tested=False,
                    service_boundary='explicit test double', copying='real rsync on selected fixture file')
    finally:
        case.doCleanups()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or not shutil.which('rsync'):
        raise RuntimeError('Linux and existing rsync required; no installation')
    args.results.mkdir(mode=0o700,parents=True,exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='pz-crash-characterization-') as temp:
        root = Path(temp)/'repository'
        shutil.copytree(args.repository, root, ignore=shutil.ignore_patterns('.git', '__pycache__', '.env'))
        sys.path.insert(0,str(root/'tests'))
        import test_world_data_safety as zones
        import test_writing_apply_safety as writing
        import test_full_restore_preflight as full
        facts = []
        for phase in ('before_first_install','after_first_install','before_commit','term_after_first_install'):
            facts.append(zone_case(zones,phase,args.results));print(facts[-1],flush=True)
        for phase in ('before_first_install','after_first_install'):
            facts.append(writing_case(writing,phase,args.results));print(facts[-1],flush=True)
        facts.append(full_restore_case(full,args.results));print(facts[-1],flush=True)
        (args.results/'results.json').write_text(json.dumps(dict(scenarios=len(facts),
            production_access=False, game_engine_available=False, characterization_not_safety_certification=True,
            results=facts),indent=2)+'\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
