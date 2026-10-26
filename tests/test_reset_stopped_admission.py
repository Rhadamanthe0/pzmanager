#!/usr/bin/env python3
"""Reset must prove a quiescent service before generation and publication."""
from contextlib import contextmanager
import shutil
import unittest

import test_reset_wipe_safety as safety


@contextmanager
def fixture():
    case = safety.Safety()
    case.setUp()
    try:
        yield case
    finally:
        case.tearDown()


def service(case, state='inactive', main='0', control='0', load='loaded', error=False, late=False):
    marker = case.base / 'generated'
    case.env['FIXTURE_GENERATED'] = str(marker)
    case.executable(case.bin / 'systemctl', '''#!/bin/bash
if [[ " $* " == *" is-active "* ]]; then exit 3; fi
''' + ('exit 7\n' if error else '') + (
        'if [[ -e "$FIXTURE_GENERATED" ]]; then\n'
        'printf "%s\\n" LoadState=loaded ActiveState=activating SubState=start MainPID=23456 ControlPID=0\n'
        'exit 0\nfi\n' if late else '') +
        f'printf "%s\\n" LoadState={load} ActiveState={state} SubState=dead MainPID={main} ControlPID={control}\n')
    return marker


class ResetStoppedAdmission(unittest.TestCase):
    def test_absent_world_refuses_unproven_stop_before_generation(self):
        cases = [dict(state='activating', main='23456'), dict(state='deactivating'),
                 dict(state='failed'), dict(main='23456'), dict(control='23456'),
                 dict(load='not-found'), dict(error=True)]
        for values in cases:
            with self.subTest(values=values), fixture() as case:
                shutil.rmtree(case.live)
                marker = service(case, **values)
                game = case.install / 'start-server.sh'
                game.write_text(game.read_text().replace("(cachedir/'db').mkdir", "Path(os.environ['FIXTURE_GENERATED']).write_text('generated')\n(cachedir/'db').mkdir"))
                result = case.run_admin('resetServer.sh')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(case.live.exists(), result.stdout)
                self.assertFalse(marker.exists(), 'game generation began without proven stop')
                self.assertFalse(list(case.home.glob('Zomboid.new.*')), result.stdout)
                self.assertEqual(case.records(), [], result.stdout)

    def test_stop_is_rechecked_before_world_publication(self):
        for present in (False, True):
            with self.subTest(world_present=present), fixture() as case:
                if not present:
                    shutil.rmtree(case.live)
                marker = service(case, late=True)
                game = case.install / 'start-server.sh'
                game.write_text(game.read_text().replace('db.commit();db.close()', "db.commit();db.close()\nPath(os.environ['FIXTURE_GENERATED']).write_text('generated')"))
                result = case.run_admin('resetServer.sh')
                self.assertTrue(marker.exists(), result.stdout)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(case.live.exists(), present, result.stdout)
                if present:
                    self.assertEqual(case.image(case.live), case.before)
                self.assertEqual(case.records(), [], result.stdout)
                starts = case.base / 'starts'
                self.assertFalse(starts.exists(), result.stdout)


if __name__ == '__main__':
    unittest.main()
