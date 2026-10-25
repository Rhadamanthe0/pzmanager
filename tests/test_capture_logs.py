"""Real logger entrypoint with isolated bus/journal and persistent file witnesses."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT=Path(os.environ['PZ_TEST_ROOT'])

class CaptureLogs(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=ROOT.parent);self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.repo=self.base/'repo'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        self.logs=self.base/'logs';self.bin=self.base/'bin';self.bin.mkdir()
        (self.repo/'.env').write_text('PZ_HOME='+shlex.quote(str(self.base))+'\nLOG_ZOMBOID_DIR='+shlex.quote(str(self.logs))+'\nLOG_RETENTION_DAYS=7\n')
        self.command('systemctl','#!/bin/sh\ncase " $* " in *InvocationID*) printf "%s\\n" "$CAPTURE_TEST_IID";; *ActiveEnterTimestamp*) printf "%s\\n" "$CAPTURE_TEST_START";; *) exit 99;; esac\n')
        self.command('journalctl', '#!/usr/bin/python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["CAPTURE_TEST_CALLS"]).write_text(json.dumps(sys.argv[1:]))\nprint("startup "+os.environ["CAPTURE_TEST_IID"])\n')
        self.command('sleep','#!/bin/sh\nexit 0\n')
        self.calls=self.base/'calls'
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],CAPTURE_TEST_CALLS=str(self.calls))
    def command(self,name,text):
        path=self.bin/name;path.write_text(text);path.chmod(0o700)
    def capture(self,iid,start=''):
        return subprocess.run(['bash',str(self.repo/'data/scripts/internal/captureLogs.sh')],env=dict(self.env,CAPTURE_TEST_IID=iid,CAPTURE_TEST_START=start),capture_output=True,text=True,timeout=6)
    def test_failed_boots_without_active_timestamp_keep_both_captures(self):
        for iid in ('a'*32,'b'*32):
            result=self.capture(iid);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        files=list(self.logs.glob('zomboid_*.log'))
        self.assertEqual(len(files),2,'different failed boots must retain separate captures')
        self.assertEqual({p.read_text() for p in files},{'startup '+'a'*32+'\n','startup '+'b'*32+'\n'})
        for path in files:
            self.assertRegex(path.name,r'^zomboid_\d{4}-\d{2}-\d{2}_\d{2}h\d{2}m\d{2}_[ab]{32}_[A-Za-z0-9]+\.log$')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
    def test_restarted_logger_same_boot_and_timestamp_never_truncates(self):
        iid='c'*32
        result=self.capture(iid,'2026-10-25 12:34:56 UTC');self.assertEqual(result.returncode,0,result.stderr)
        first=next(self.logs.glob('*.log'));first.write_text('previous capture sentinel\n')
        result=self.capture(iid,'2026-10-25 12:34:56 UTC');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(first.read_text(),'previous capture sentinel\n')
        self.assertEqual(len(list(self.logs.glob('*.log'))),2)
        self.assertEqual(json.loads(self.calls.read_text()),['-n','all','-f','INVOCATION_ID='+iid,'+','_SYSTEMD_INVOCATION_ID='+iid])
    def test_invalid_or_missing_invocation_creates_no_capture(self):
        for iid in ('','../outside','a'*31):
            with self.subTest(iid=iid):
                result=self.capture(iid);self.assertNotEqual(result.returncode,0)
                self.assertFalse(self.calls.exists());self.assertEqual(list(self.logs.glob('*.log')),[])

if __name__=='__main__':unittest.main()
