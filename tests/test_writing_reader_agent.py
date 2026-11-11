"""Signed game JAR: the reader agent keeps origin, signers and trace hooks.

A synthetic package reproduces the native loader layout. The audited agent is
compiled and packaged by the production helper, then run by a real JDK in a
private directory whose name contains '='. The game JAR is never opened; only
disposable fixtures are built, signed and hashed.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(os.environ.get('PZ_TEST_ROOT', Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(ROOT / 'data/scripts/lib'))
import terrain_tiles

INVENTORY_ITEM = """\
package zombie.inventory;
import java.nio.ByteBuffer;
public class InventoryItem {
    public void load(ByteBuffer buffer, int version) { buffer.get(); }
    public static InventoryItem loadItem(ByteBuffer buffer, int version, boolean present, InventoryItem item) {
        if (!present) return null;
        item.load(buffer, version);
        return item;
    }
}
"""

WRONG_LAYOUT_ITEM = """\
package zombie.inventory;
import java.nio.ByteBuffer;
public class InventoryItem {
    public void load(ByteBuffer buffer, int version) { }
    public static InventoryItem loadItem(ByteBuffer buffer, int version, boolean present, InventoryItem item) {
        return item;
    }
}
"""

ITEM_CONTAINER = """\
package zombie.inventory;
public final class ItemContainer { }
"""

NATIVE_ITEM_TRACE = """\
import java.nio.ByteBuffer;
import zombie.inventory.InventoryItem;
public class NativeItemTrace {
    public static int entered, loaded, exited;
    public static void enter(ByteBuffer buffer, int version) { entered++; }
    public static void consumed(ByteBuffer buffer) { loaded++; }
    public static void exit(InventoryItem item, ByteBuffer buffer) { exited++; }
}
"""

PROBE = """\
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.security.CodeSource;
import java.security.ProtectionDomain;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
public final class Probe {
    private static CodeSource source(Class<?> type) {
        ProtectionDomain domain = type.getProtectionDomain();
        return domain == null ? null : domain.getCodeSource();
    }
    private static int signers(Class<?> type) {
        CodeSource source = source(type);
        return source == null || source.getCodeSigners() == null ? 0 : source.getCodeSigners().length;
    }
    public static void main(String[] args) throws Exception {
        Path jar = Path.of(args[0]).toRealPath();
        boolean signed = Boolean.parseBoolean(args[1]);
        CodeSource origin = source(InventoryItem.class);
        if (origin == null || !Path.of(origin.getLocation().toURI()).toRealPath().equals(jar))
            throw new AssertionError("wrong origin JAR");
        if (signed != (signers(InventoryItem.class) > 0)) throw new AssertionError("wrong signer state");
        if (signers(InventoryItem.class) != signers(ItemContainer.class))
            throw new AssertionError("package signer mismatch");
        InventoryItem value = new InventoryItem();
        if (InventoryItem.loadItem(ByteBuffer.wrap(new byte[1]), 249, true, value) != value)
            throw new AssertionError("changed return");
        if (InventoryItem.loadItem(ByteBuffer.wrap(new byte[1]), 249, false, value) != null)
            throw new AssertionError("changed null return");
        if (NativeItemTrace.entered != 2 || NativeItemTrace.loaded != 1 || NativeItemTrace.exited != 2)
            throw new AssertionError("trace hooks did not run");
        System.out.println("ORIGIN=OK SIGNERS=" + signers(InventoryItem.class) + " TRACE=2,1,2");
    }
}
"""


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ReaderAgentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = {name: shutil.which(name) for name in ('java', 'javac', 'jar', 'keytool', 'jarsigner')}
        missing = [name for name, path in cls.tools.items() if not path]
        if missing:
            raise unittest.SkipTest('JDK tools unavailable: ' + ', '.join(missing))
        cls.temp = tempfile.TemporaryDirectory(prefix='reader-agent-')
        cls.addClassCleanup(cls.temp.cleanup)
        # '=' in the private root exercises both the fixed relative agent name
        # and the complete game JAR path carried after =jar=.
        cls.root = Path(cls.temp.name) / 'a=b'
        cls.root.mkdir()
        cls._build()

    @classmethod
    def tool(cls, *command):
        return subprocess.run([str(part) for part in command], cwd=cls.root,
                              capture_output=True, text=True)

    @classmethod
    def tool_ok(cls, *command):
        result = cls.tool(*command)
        if result.returncode:
            raise AssertionError('command failed: %s\n%s' % (command, result.stderr))
        return result

    @classmethod
    def _sign(cls, jar):
        cls.tool_ok(cls.tools['jarsigner'], '-keystore', cls.key, '-storepass', 'changeit',
                    '-keypass', 'changeit', jar, 'fixture')

    @classmethod
    def _build(cls):
        version = cls.tool(cls.tools['java'], '-version').stderr
        cls.release = re.search(r'version "(\d+)', version).group(1)
        source = cls.root / 'src'
        (source / 'zombie/inventory').mkdir(parents=True)
        (source / 'zombie/inventory/InventoryItem.java').write_text(INVENTORY_ITEM)
        (source / 'zombie/inventory/ItemContainer.java').write_text(ITEM_CONTAINER)
        (source / 'NativeItemTrace.java').write_text(NATIVE_ITEM_TRACE)
        (source / 'Probe.java').write_text(PROBE)
        game = cls.root / 'game'
        game.mkdir()
        cls.tool_ok(cls.tools['javac'], '-d', game, source / 'zombie/inventory/InventoryItem.java',
                    source / 'zombie/inventory/ItemContainer.java')
        cls.classes = cls.root / 'classes'
        cls.classes.mkdir()
        cls.tool_ok(cls.tools['javac'], '--release', cls.release, '-d', cls.classes,
                    ROOT / 'data/scripts/lib/InstrumentItemReads.java')
        cls.tool_ok(cls.tools['javac'], '-cp', game, '-d', cls.classes, source / 'NativeItemTrace.java')
        cls.tool_ok(cls.tools['javac'], '-cp', str(game) + os.pathsep + str(cls.classes),
                    '-d', cls.classes, source / 'Probe.java')
        cls.agent = terrain_tiles.instrumentation_agent(cls.classes, cls.root / 'instrumentation-agent.jar')
        cls.signed = cls.root / 'signed.jar'
        cls.tool_ok(cls.tools['jar'], 'cf', cls.signed, '-C', game, '.')
        cls.unsigned = cls.root / 'unsigned.jar'
        cls.tool_ok(cls.tools['jar'], 'cf', cls.unsigned, '-C', game, '.')
        cls.key = cls.root / 'test.p12'
        cls.tool_ok(cls.tools['keytool'], '-genkeypair', '-keystore', cls.key, '-storetype', 'PKCS12',
                    '-storepass', 'changeit', '-keypass', 'changeit', '-alias', 'fixture',
                    '-dname', 'CN=Fixture', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '1',
                    '-noprompt')
        cls._sign(cls.signed)
        wrong_source = cls.root / 'wrong-src/zombie/inventory'
        wrong_source.mkdir(parents=True)
        (wrong_source / 'InventoryItem.java').write_text(WRONG_LAYOUT_ITEM)
        (wrong_source / 'ItemContainer.java').write_text(ITEM_CONTAINER)
        wrong = cls.root / 'wrong'
        wrong.mkdir()
        cls.tool_ok(cls.tools['javac'], '-d', wrong, wrong_source / 'InventoryItem.java',
                    wrong_source / 'ItemContainer.java')
        cls.wrong = cls.root / 'wrong-layout.jar'
        cls.tool_ok(cls.tools['jar'], 'cf', cls.wrong, '-C', wrong, '.')
        cls._sign(cls.wrong)

    def probe(self, jar, signed, expected=None):
        options = terrain_tiles.item_trace_options(int(self.release), self.agent, expected or jar)
        return self.tool(self.tools['java'], '-XX:-CreateCoredumpOnCrash', *options,
                         '-cp', str(self.classes) + os.pathsep + str(jar),
                         'Probe', str(jar), str(signed).lower())

    def assert_refused(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn('ORIGIN=OK', result.stdout)

    def test_signed_jar_keeps_origin_signers_and_hooks(self):
        before = digest(self.signed)
        result = self.probe(self.signed, True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ORIGIN=OK SIGNERS=1 TRACE=2,1,2', result.stdout)
        self.assertEqual(digest(self.signed), before)

    def test_unsigned_jar_is_instrumented_without_signers(self):
        result = self.probe(self.unsigned, False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ORIGIN=OK SIGNERS=0 TRACE=2,1,2', result.stdout)

    def test_incompatible_layout_is_refused_before_the_reader(self):
        self.assert_refused(self.probe(self.wrong, True), 'Unsupported native loader layout')

    def test_class_from_another_jar_is_refused(self):
        self.assert_refused(self.probe(self.signed, True, expected=self.unsigned),
                            'does not come from the expected JAR')

    def test_tampered_signed_class_is_refused(self):
        tampered = self.root / 'tampered.jar'
        with zipfile.ZipFile(self.signed) as source, zipfile.ZipFile(tampered, 'w') as target:
            for info in source.infolist():
                data = source.read(info.filename)
                if info.filename == 'zombie/inventory/InventoryItem.class':
                    data = data[:-1] + bytes([data[-1] ^ 1])
                target.writestr(info, data)
        result = self.probe(tampered, True)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        # The JDK reports a modified signed entry as a digest/signature error.
        self.assertTrue('SecurityException' in output or 'signature' in output.lower(), output)
        self.assertNotIn('ORIGIN=OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
