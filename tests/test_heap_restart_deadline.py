"""Longest public warning through the real memory monitor and lifecycle CLI."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

import test_silent_start as support

ROOT=Path(os.environ['PZ_TEST_ROOT'])


def unit_seconds(name, property_name):
    text=(ROOT/'data/setupTemplates'/name).read_text()
    match=re.search(r'^'+property_name+r'=(\d+)$',text,re.M)
    if not match:
        raise AssertionError(f'{name}: {property_name} must be finite seconds')
    return int(match[1])


def public_delays():
    example=(ROOT/'data/setupTemplates/.env.example').read_text()
    line=next(line for line in example.splitlines() if line.startswith('export HEAP_RESTART_DELAY='))
    return {delay:int(number)*(60 if suffix=='m' else 1)
            for delay,number,suffix in re.findall(r'\b((\d+)([ms]))\b',line)}


class HeapRestartDeadline(unittest.TestCase):
    def test_finite_unit_covers_public_delay_and_restart_envelopes(self):
        delays=public_delays()
        core=(ROOT/'data/scripts/core/pz.sh').read_text()
        accepted=set(re.findall(r'\["(\d+[ms])"\]=',core))
        self.assertLessEqual(set(delays),accepted)
        self.assertGreaterEqual(max(delays.values()),30*60)
        readiness=int(re.search(r'boot_deadline=\$\(\(SECONDS \+ (\d+)\)\)',core)[1])
        stop_source=(ROOT/'data/scripts/lib/stop_diagnostics.py').read_text()
        fifo=int(re.search(r'write_fifo\(args.pipe, "quit", (\d+)\)',stop_source)[1])
        # The hourly backup's budget is an operating envelope here, not an
        # individual timeout on dataBackup.sh called directly by pz.sh.
        envelope=(readiness+max(delays.values())+5+fifo+5
                  +unit_seconds('zomboid.service','TimeoutStopSec')
                  +unit_seconds('pz-backup.service','TimeoutStartSec')
                  +unit_seconds('zomboid.service','TimeoutStartSec'))
        limit=unit_seconds('pz-heapcheck.service','TimeoutStartSec')
        self.assertGreater(limit,envelope)
        self.assertLessEqual(limit,2*60*60)

    def test_longest_warning_finishes_before_unit_deadline_and_restarts(self):
        case=support.SilentStart();case.setUp();self.addCleanup(case.doCleanups)
        case.write_state('active',support.A)
        shutil.copy2(ROOT/'pzm',case.repo/'pzm')
        sleeps=case.base/'sleeps';commands=case.base/'commands'
        case.executable(case.bin/'sleep', '#!/bin/bash\nprintf "%s\\n" "$1" >> "$HEAP_TEST_SLEEPS"\ntotal=$(awk \'{s+=$1} END{print s}\' "$HEAP_TEST_SLEEPS")\n(( total < HEAP_TEST_DEADLINE )) || exit 124\n')
        path=case.bin/'systemctl';source=path.read_text()
        needle="path=Path(os.environ['SILENT_TEST_STATE']);"
        self.assertIn(needle,source)
        path.write_text(source.replace(needle,"Path(os.environ['HEAP_TEST_COMMANDS']).open('a').write(' '.join(sys.argv[1:])+'\\n');"+needle))
        logs=case.repo/'logs/zomboid';logs.mkdir(parents=True)
        (logs/'gc.log').write_text('Major Collection (Timer) 20000M(98%)->18000M(96%) 0.1s\n')
        delays=public_delays();delay=max(delays,key=delays.get)
        with (case.repo/'.env').open('a') as stream:
            stream.write('export HEAP_RESTART_DELAY='+delay+'\n')
        limit=unit_seconds('pz-heapcheck.service','TimeoutStartSec')
        case.env.update(HEAP_TEST_SLEEPS=str(sleeps),HEAP_TEST_COMMANDS=str(commands),HEAP_TEST_DEADLINE=str(limit))
        result=subprocess.run(['bash',str(case.repo/'data/scripts/internal/checkHeapAndRestart.sh')],env=case.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        requested=list(map(int,sleeps.read_text().split()))
        self.assertEqual(requested[:6],[900,600,180,90,30,5])
        self.assertEqual(sum(requested[:6]),1805)
        controls=[line.split() for line in commands.read_text().splitlines()]
        self.assertTrue(any('stop' in args for args in controls))
        self.assertTrue(any('start' in args for args in controls))
        self.assertEqual(json.loads(case.state.read_text())['ActiveState'],'active')


if __name__=='__main__':unittest.main()
