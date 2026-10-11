"""Le banc de marqueurs privés ne doit jamais reprendre le repli d'un compte."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TARGET = Path(os.environ.get("PZ_PRIVATE_STATE_BASELINE_SCRIPT", ROOT / "tests/test_sec_privatestate.sh"))


class PrivateStateFixtureIsolation(unittest.TestCase):
    def test_previous_fallback_directory_is_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tempfile.mkdtemp(prefix="pzmanager-pz-secps-probe-", dir="/tmp"))
            marker = old / "prior-state"
            marker.write_text("preserve")
            fake_user = old.name.removeprefix("pzmanager-")
            setup = Path(tmp) / "bash-env"
            setup.write_text(f'''id() {{
    if [[ "$*" == "-un" ]]; then printf '%s\\n' "{fake_user}"
    else command id "$@"; fi
}}
export -f id
''')
            env = {**os.environ, "BASH_ENV": str(setup), "PZ_TEST_ROOT": str(ROOT)}
            try:
                result = subprocess.run(["bash", str(TARGET)], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertTrue(marker.exists(), "Le test a effacé un état antérieur : " + result.stderr)
                self.assertEqual(marker.read_text(), "preserve")
                self.assertIn("repli : chemin sous /tmp/pzmanager-", result.stdout)
                # Le cas chown réel est testé séparément sous root ; ce test
                # d'isolation peut être joué sans privilège ni identité réelle.
            finally:
                # Ce nom aléatoire a été créé par cette fixture seulement.
                if old.exists() and not old.is_symlink() and old.stat().st_uid == os.getuid():
                    shutil.rmtree(old)


if __name__ == "__main__":
    unittest.main()
