"""Synthetic offline storage fixtures; contains no player/server data."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor as RealThreadPoolExecutor
import unittest
from unittest.mock import patch
import zlib

MODULE=Path(__file__).resolve().parents[1]/'data/scripts/internal/cleanWritingDrawings.py'
spec=importlib.util.spec_from_file_location('writing_cleanup',MODULE)
cleaner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=cleaner;spec.loader.exec_module(cleaner)
REGISTRY={1:'Base.Diary2',2:'Base.Bag_SurvivorBag',3:'Base.RosewoodMap',4:'Unsupported.Book',5:'Base.StoneAxeHead'}

def lua(value):
    if isinstance(value,bool):return bytes([3,int(value)])
    if isinstance(value,(int,float)):return b'\x01'+struct.pack('>d',value)
    if isinstance(value,str):value=value.encode()
    if isinstance(value,bytes):return b'\x00'+struct.pack('>H',len(value))+value
    return b'\x02'+struct.pack('>i',len(value))+b''.join(lua(key)+lua(item) for key,item in value.items())

def document(dirty=True):
    page={'note':{1:{'t':'Synthetic note','tc':'blue','textpos':12}},'t':'Page text','ink_metadata':{'ink':{1:'Preserve nested unrelated key'}}}
    if dirty:page.update(ink={1:{'p':{1:1.5,2:2.5},'c':'red','w':2}},sym={1:{'id':'fixture'}})
    result={'v':1,'t':{'40':'Additional page'},'p':{'1':page},'tc':'black'}
    if dirty:result.update(ink={1:{'p':{1:3.5,2:4.5}}},sym={1:{'id':'legacy'}})
    return result

def item(rid=1,ident=1001,doc=None,body=b'custom-page-sentinel'):
    payload=struct.pack('>i',ident)+body+lua({'NeatWriting':doc if doc is not None else document(),'Other':'Unchanged'})
    return struct.pack('>i',len(payload)+3)+struct.pack('>hB',rid,255)+payload

def nested(dirty=True):
    # Envelope protocol and ancestor-length geometry; real PZ body layouts are
    # validated separately with copied JAR fixtures, not invented by this test.
    book=item(doc=document(dirty))
    body=struct.pack('>i',2001)+b'bag-metadata'+struct.pack('>i',1)+book
    bag=struct.pack('>i',len(body)+3)+struct.pack('>hB',2,255)+body
    return struct.pack('>i',1)+bag+b'world-tail-sentinel'

def chunk(body):return b'\0'+struct.pack('>iiq',249,len(body)+17,zlib.crc32(body))+body

class OfflineCleanup(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pz-offline-test-')
        self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name);self.world=self.root/'world';self.world.mkdir(mode=0o700);self.backups=self.root/'backups'
        self.validations=[]
        def validate(stage,files,rows):
            fixture=stage/'synthetic-validation'
            if fixture.exists():
                import shutil;shutil.rmtree(fixture)
            manifest,count=cleaner.validation_manifest(stage,files,rows,fixture)
            records=json.loads(manifest.read_text())['records']
            self.assertGreater(count,0);self.assertEqual({r['class'] for r in records},{'Literature','InventoryContainer'})
            for record in records:
                for key in ('before','after'):
                    blob=Path(record[key]).read_bytes();self.assertEqual(struct.unpack_from('>i',blob)[0],len(blob)-4)
            self.validations.append(count)
        self.validator=validate
        (self.world/'WorldDictionaryReadable.lua').write_text('\n'.join(f'{{ registryID = {i}, fulltype = "{name}" }}' for i,name in REGISTRY.items()))
        self.path=self.world/'map/1/2.bin';self.path.parent.mkdir(parents=True);self.path.write_bytes(chunk(nested()))
        db=sqlite3.connect(self.world/'players.db')
        for table in ('networkPlayers','localPlayers'):db.execute(f'CREATE TABLE {table}(id INTEGER PRIMARY KEY,worldversion INTEGER,data BLOB,name TEXT)')
        db.execute('INSERT INTO networkPlayers VALUES(1,249,?,?)',(nested(),'Synthetic character'))
        db.execute('INSERT INTO localPlayers VALUES(2,249,?,?)',(b'no writing','Synthetic local'))
        db.commit();db.close()
    def sources(self):return {str(p.relative_to(self.world)):p.read_bytes() for p in self.world.rglob('*') if p.is_file()}
    def test_nested_storage_and_opaque_text_preservation(self):
        original=chunk(nested());new,detail=cleaner.clean_blob(original,REGISTRY,chunk=True)
        self.assertEqual(new,chunk(nested(False)))
        self.assertEqual(len(detail),1);self.assertEqual(detail[0]['drawing_fields_removed'],4)
        self.assertEqual(struct.unpack_from('>i',new,5)[0],len(new));self.assertEqual(struct.unpack_from('>q',new,9)[0],zlib.crc32(new[17:]))
        self.assertEqual(cleaner.clean_blob(new,REGISTRY,chunk=True),(new,[]))
        map_record=struct.pack('>i',1)+item(rid=3,doc={'v':1,'ink':{1:{'p':{1:5}}},'sym':{1:'map annotation'}})
        self.assertEqual(cleaner.clean_blob(map_record,REGISTRY),(map_record,[]))
    def test_whole_plan_backup_sqlite_atomicity_and_idempotence(self):
        before=self.sources();summary=cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.assertEqual(summary['files'],2);stage=Path(summary['backup']);manifest=json.loads((stage/'manifest.json').read_text())
        self.assertEqual(manifest['state'],'complete')
        for entry in manifest['files']:self.assertEqual((stage/'original'/entry['path']).read_bytes(),before[entry['path']])
        self.assertEqual(self.path.read_bytes(),chunk(nested(False)))
        db=sqlite3.connect(self.world/'players.db')
        self.assertEqual(db.execute('SELECT data,name FROM networkPlayers').fetchone(),(nested(False),'Synthetic character'))
        self.assertEqual(db.execute('SELECT data FROM localPlayers').fetchone()[0],b'no writing');db.close()
        after=self.sources();self.assertEqual(cleaner.cleanup(self.world,self.backups,validator=self.validator)['files'],0);self.assertEqual(self.sources(),after)
        self.assertEqual(len(list(self.backups.glob('cleanup-*'))),1)
    def test_refuses_entire_plan_before_mutation(self):
        for bad in (chunk(nested())[:-1], bytes([1])+chunk(nested())[1:], chunk(nested()).replace(struct.pack('>i',249),struct.pack('>i',248),1), chunk(struct.pack('>i',1)+item(rid=4)),chunk(struct.pack('>i',1)+item(rid=1,ident=0))):
            with self.subTest(case=len(bad)):
                self.path.write_bytes(bad);before=self.sources()
                with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
                self.assertEqual(self.sources(),before);self.assertFalse(self.backups.exists())
        self.path.write_bytes(chunk(nested()));(self.world/'players.db-wal').write_bytes(b'not checkpointed');before=self.sources()
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.assertEqual(self.sources(),before)
    def test_resume_interrupted_commit_and_refuse_conflicts(self):
        actual=cleaner.atomic_copy;replaces=[]
        def interrupted(path,source,mode=0o600):
            if self.world in path.parents:
                replaces.append(path)
                if len(replaces)==2:raise OSError('Synthetic interrupted commit')
            return actual(path,source,mode)
        with patch.object(cleaner,'atomic_copy',side_effect=interrupted),self.assertRaises(OSError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        stage=next(self.backups.glob('cleanup-*'));self.assertEqual(json.loads((stage/'manifest.json').read_text())['state'],'prepared')
        cleaner.cleanup(self.world,self.backups,validator=self.validator);self.assertEqual(self.path.read_bytes(),chunk(nested(False)))
        self.assertEqual(json.loads((stage/'manifest.json').read_text())['state'],'complete')
    def test_dry_run_and_path_safety(self):
        before=self.sources();self.assertEqual(cleaner.cleanup(self.world,self.backups,True)['files'],2)
        self.assertEqual(self.sources(),before);self.assertFalse(self.backups.exists())
        external=self.root/'external';external.mkdir();self.path.unlink();self.path.symlink_to(external/'missing')
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.assertFalse(self.backups.exists())
        self.path.unlink();self.path.write_bytes(chunk(nested()))
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.world/'backups')
    def test_admission_required_even_for_first_world_and_real_validation_before_mutation(self):
        from types import SimpleNamespace
        before=self.sources()
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.backups)
        self.assertEqual(self.sources(),before);self.assertFalse(self.backups.exists())
        with patch.dict(sys.modules,writing_start_admission=SimpleNamespace(validate_worker_admission=lambda unit: (_ for _ in ()).throw(ValueError('active JVM')))):
            self.assertEqual(cleaner.main(['--world-dir',str(self.root/'missing'), '--backup-dir',str(self.backups)]),1)
        with patch.dict(sys.modules,writing_start_admission=SimpleNamespace(validate_worker_admission=lambda unit: 123)):
            self.assertEqual(cleaner.main(['--world-dir',str(self.root/'missing/deep/world'), '--backup-dir',str(self.backups)]),0)
        self.assertFalse((self.root/'missing').exists())
        empty=self.root/'empty';empty.mkdir(mode=0o700)
        self.assertEqual(cleaner.cleanup(empty,self.backups)['files'],0)
        db=sqlite3.connect(empty/'players.db');db.execute('CREATE TABLE networkPlayers(id INTEGER,data BLOB)');db.commit();db.close()
        self.assertEqual(cleaner.cleanup(empty,self.backups)['files'],0)
        db=sqlite3.connect(empty/'players.db');db.execute("INSERT INTO networkPlayers VALUES(1,?)",(b'character',));db.commit();db.close()
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(empty,self.backups)
    def test_conflicting_pending_world_refuses_and_unproven_ancestors_rejected(self):
        actual=cleaner.atomic_copy
        def interrupted(path,source,mode=0o600):
            if self.world in path.parents:raise OSError('Synthetic interruption')
            return actual(path,source,mode)
        with patch.object(cleaner,'atomic_copy',side_effect=interrupted),self.assertRaises(OSError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.path.write_bytes(b'concurrent replacement');before=self.sources()
        with self.assertRaises(cleaner.CleanupError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.assertEqual(self.sources(),before)
        unsupported=dict(REGISTRY);unsupported[2]='Base.StoneAxeHead'
        with self.assertRaises(cleaner.CleanupError):cleaner.clean_blob(chunk(nested()),unsupported,chunk=True)

    def test_sqlite_uri_and_catalog_classes_preserved_for_special_paths(self):
        moved=self.root/'world #? fixture'
        self.world.rename(moved);self.world=moved;self.path=self.world/'map/1/2.bin'
        before=self.sources()
        scripts=self.root/'scripts';scripts.mkdir(mode=0o700)
        (scripts/'fixture.txt').write_text("module Base { item ProofBag { ItemType = base:Container, } item Diary2 { ItemType = base:Literature, } item Weapon { ItemType = base:Weapon, } }")
        classes=cleaner.script_classes(scripts)
        self.assertEqual(classes,{'Base.ProofBag':'container','Base.Diary2':'literature','Base.Weapon':'weapon'})
        summary=cleaner.cleanup(self.world,self.backups,validator=self.validator,scripts_dir=scripts)
        self.assertEqual(summary['players'],1)
        self.assertEqual(self.path.read_bytes(),chunk(nested(False)))
        self.assertEqual((Path(summary['backup'])/'original/players.db').read_bytes(),before['players.db'])

    def test_catalog_literature_does_not_expand_direct_record_admission(self):
        # A non-item world field can resemble a Tailoring magazine envelope.
        # Its negative preceding count and invalid body must not make it an
        # ancestor solely because the script catalog classifies it Literature.
        scripts=self.root/'scripts';scripts.mkdir(mode=0o700)
        (scripts/'fixture.txt').write_text('module Base { item TailoringMag10 { ItemType = base:Literature, } }')
        with (self.world/'WorldDictionaryReadable.lua').open('a') as stream:stream.write('\n{ registryID = 6, fulltype = "Base.TailoringMag10" }')
        prefix=struct.pack('>iihBiB',-1,len(nested())+8,6,255,7777,4)
        original=chunk(prefix+nested());self.path.write_bytes(original)
        cleaner.cleanup(self.world,self.backups,validator=self.validator,scripts_dir=scripts)
        self.assertEqual(self.path.read_bytes(),chunk(prefix+nested(False)))

    def test_scan_cache_skips_unchanged_but_rereads_changed_and_replaced_files(self):
        path = self.world/'plain.bin';path.write_bytes(b'no writing')
        time.sleep(cleaner.CACHE_QUIET_NS / 1e9 + .02)
        cached = {};first = dict(cleaner.drawing_files(self.world, {}, cached))
        self.assertIsNone(first[Path('plain.bin')]);self.assertIn('plain.bin', cached)
        original = cleaner.read_file
        reads = []
        def tracked(file):
            reads.append(file);return original(file)
        with patch.object(cleaner, 'read_file', side_effect=tracked):
            retained = {};dict(cleaner.drawing_files(self.world, cached, retained))
        self.assertNotIn(path, reads);self.assertIn('plain.bin', retained)
        # Une horloge reculée derrière les dates du fichier impose une relecture.
        reads.clear();retained={}
        with patch.object(cleaner.time,'time_ns',return_value=time.time_ns()-5_000_000_000), \
                patch.object(cleaner,'read_file',side_effect=tracked):
            dict(cleaner.drawing_files(self.world,cached,retained))
        self.assertIn(path,reads);self.assertNotIn('plain.bin',retained)
        path.write_bytes(cleaner.MARKER)
        with patch.object(cleaner, 'read_file', side_effect=tracked):
            self.assertEqual(dict(cleaner.drawing_files(self.world, cached, {}))[Path('plain.bin')], cleaner.MARKER)
        self.assertIn(path, reads)
        path.unlink();path.write_bytes(b'new file')
        reads.clear()
        with patch.object(cleaner, 'read_file', side_effect=tracked):
            dict(cleaner.drawing_files(self.world, cached, {}))
        self.assertIn(path, reads)

    def test_successful_clean_scan_persists_cache_and_next_scan_skips_plain_file(self):
        self.path.write_bytes(b'no writing')
        db=sqlite3.connect(self.world/'players.db');db.execute("UPDATE networkPlayers SET data=?",(b'no writing',));db.commit();db.close()
        cache=self.root/'cache.json'
        time.sleep(cleaner.CACHE_QUIET_NS / 1e9 + .02)
        self.assertEqual(cleaner.cleanup(self.world,self.backups,scan_cache=cache)['files'],0)
        self.assertEqual(cache.stat().st_mode & 0o777,0o600)
        data=json.loads(cache.read_text());self.assertIn(str(self.path.relative_to(self.world)),data['files'])
        actual=cleaner.read_file;reads=[]
        def tracked(path):reads.append(path);return actual(path)
        with patch.object(cleaner,'read_file',side_effect=tracked):
            cleaner.cleanup(self.world,self.backups,scan_cache=cache)
        self.assertNotIn(self.path,reads)
        cache.write_text('[]')
        self.assertEqual(cleaner.load_scan_cache(cache,self.world),{})

    def test_invalid_cache_falls_back_and_symlink_is_never_trusted(self):
        cache = self.root/'cache.json';cache.write_text('invalid')
        self.assertEqual(cleaner.load_scan_cache(cache, self.world), {})
        cache.unlink();cache.symlink_to(self.path)
        self.assertEqual(cleaner.load_scan_cache(cache, self.world), {})
        with self.assertRaises(cleaner.CleanupError):
            cleaner.cleanup(self.world,self.backups,scan_cache=self.world/'cache.json')

    def test_recent_negative_is_not_cached_even_when_read_is_slow(self):
        path = self.world/'fresh.bin';path.write_bytes(b'no writing')
        actual = cleaner.read_file
        def slow(file):
            if file == path: time.sleep(cleaner.CACHE_QUIET_NS / 1e9 + .02)
            return actual(file)
        scanned = {}
        with patch.object(cleaner,'read_file',side_effect=slow):
            dict(cleaner.drawing_files(self.world,{},scanned))
        self.assertNotIn('fresh.bin',scanned)

    def test_legacy_cache_cannot_reuse_unproven_absence(self):
        path=self.world/'plain.bin';path.write_bytes(b'no writing')
        cache=self.root/'legacy-cache.json'
        cache.write_text(json.dumps({'schema':1,'world':str(self.world),'version':249,
            'files':{'plain.bin':cleaner.file_identity(path.stat())}}));cache.chmod(0o600)
        self.assertEqual(cleaner.load_scan_cache(cache,self.world),{})

    def test_persisted_cache_same_tick_rewrite_is_detected_after_delay(self):
        # Vrai tmpfs : aucun utime, faux stat, cache forgé ni écriture concurrente.
        # Deux nettoyages séquentiels séparés par une édition offline du monde.
        with tempfile.TemporaryDirectory(prefix='pz-cache-tick-',dir='/dev/shm') as tmp:
            root=Path(tmp);world=root/'world';world.mkdir(mode=0o700)
            (world/'WorldDictionaryReadable.lua').write_text('\n'.join(
                f'{{ registryID = {i}, fulltype = "{name}" }}' for i,name in REGISTRY.items()))
            path=world/'map/1/2.bin';path.parent.mkdir(parents=True)
            dirty=chunk(nested());plain=chunk(bytes(len(dirty)-17));cache=root/'cache.json'
            equal=False
            for _ in range(128):
                path.write_bytes(plain)
                first=cleaner.cleanup(world,root/'backups',scan_cache=cache)
                self.assertEqual(first['files'],0)
                self.assertNotIn('map/1/2.bin',json.loads(cache.read_text())['files'])
                before=cleaner.file_identity(path.stat())
                path.write_bytes(dirty)
                equal=before==cleaner.file_identity(path.stat())
                if equal:break
            self.assertTrue(equal,'La fixture doit reproduire la même tick, sans faux stat')
            time.sleep(cleaner.CACHE_QUIET_NS / 1e9 + .02)
            # Après ce délai, un simple refus des hits récents serait insuffisant.
            # Les dessins doivent être détectés et exiger la validation réelle.
            with self.assertRaisesRegex(cleaner.CleanupError,'genuine PZ record validator'):
                cleaner.cleanup(world,root/'backups',scan_cache=cache)
            self.assertEqual(path.read_bytes(),dirty)
            self.assertFalse((root/'backups').exists())

    def test_unavailable_optional_cache_parent_falls_back_to_full_scan(self):
        self.path.write_bytes(chunk(nested(False)))
        with sqlite3.connect(self.world/'players.db') as db:
            db.execute('UPDATE networkPlayers SET data=?',(nested(False),))
        before = self.sources()
        parent = self.root/'unavailable-cache-parent'
        parent.write_text('A stale file blocks the optional directory')
        self.assertEqual(cleaner.cleanup(self.world,self.backups,
            scan_cache=parent/'cache.json')['files'],0)
        self.assertEqual(self.sources(),before)
        self.assertFalse(self.backups.exists())
        self.assertEqual(parent.read_text(),'A stale file blocks the optional directory')
        cache = self.root/'optional-cache/cache.json'
        actual = cleaner.safe_root
        def denied(path,create=False):
            if Path(path) == cache.parent: raise PermissionError('Private cache fixture')
            return actual(path,create)
        with patch.object(cleaner,'safe_root',side_effect=denied):
            self.assertEqual(cleaner.cleanup(self.world,self.backups,scan_cache=cache)['files'],0)
        self.assertEqual(self.sources(),before)
        self.assertFalse(self.backups.exists())

    def test_clean_world_does_not_require_compiler_but_dirty_apply_does(self):
        validator = cleaner.JavaValidator(str(self.root/'missing.jar'),str(self.root/'java'),str(self.root/'javac'))
        empty = self.root/'empty';empty.mkdir(mode=0o700)
        self.assertEqual(cleaner.cleanup(empty,self.backups,validator=validator)['files'],0)
        before = self.sources()
        with self.assertRaises((FileNotFoundError,cleaner.CleanupError)):
            cleaner.cleanup(self.world,self.backups,validator=validator)
        self.assertEqual(self.sources(),before)

    def test_clean_saved_notes_do_not_require_compiler(self):
        validator = cleaner.JavaValidator(str(self.root/'missing.jar'),str(self.root/'java'),str(self.root/'javac'))
        self.path.write_bytes(chunk(nested(False)))
        db=sqlite3.connect(self.world/'players.db')
        db.execute('UPDATE networkPlayers SET data=?',(nested(False),));db.commit();db.close()
        before=self.sources()
        self.assertEqual(cleaner.cleanup(self.world,self.backups,validator=validator)['files'],0)
        self.assertEqual(self.sources(),before)

    def test_parallel_read_ahead_is_bounded_ordered_and_errors_leave_world_unchanged(self):
        paths=[Path(str(i)+'.bin') for i in range(64)]
        for rel in paths:
            (self.world/rel).write_bytes(b'fixture')
        release=threading.Event();queued=threading.Event();mutex=threading.Lock()
        submitted=0;running=0;peak=0;results=[];errors=[]
        class Pool(RealThreadPoolExecutor):
            def submit(pool,fn,*args,**kwargs):
                nonlocal submitted
                with mutex:
                    submitted+=1
                    if submitted==16:queued.set()
                return super().submit(fn,*args,**kwargs)
        def read(path):
            nonlocal running,peak
            with mutex:running+=1;peak=max(peak,running)
            try:
                if not release.wait(5):raise RuntimeError('Test gate timeout')
                return cleaner.MARKER if path.stem in ('1','33') else b'no writing'
            finally:
                with mutex:running-=1
        def consume():
            try:results.extend(cleaner.drawing_files(self.world))
            except BaseException as error:errors.append(error)
        with patch.object(cleaner,'world_files',return_value=iter(paths)),patch.object(cleaner,'ThreadPoolExecutor',Pool),patch.object(cleaner,'read_file',side_effect=read):
            worker=threading.Thread(target=consume);worker.start()
            try:
                self.assertTrue(queued.wait(5))
                with mutex:self.assertEqual(submitted,16)
            finally:release.set();worker.join(5)
            self.assertFalse(worker.is_alive());self.assertFalse(errors)
        self.assertEqual([rel for rel,_ in results],paths)
        self.assertEqual([str(rel) for rel,blob in results if blob is not None],['1.bin','33.bin'])
        self.assertLessEqual(peak,8)
        bad=self.world/'map/1/late.bin';bad.write_bytes(b'no writing')
        before=self.sources();actual=cleaner.read_file
        def failed(path):
            if path==bad:raise OSError('Synthetic unreadable world file')
            return actual(path)
        with patch.object(cleaner,'read_file',side_effect=failed),self.assertRaises(OSError):cleaner.cleanup(self.world,self.backups,validator=self.validator)
        self.assertEqual(self.sources(),before);self.assertFalse(self.backups.exists())

    def test_skip_drawing_children_does_not_allocate_nodes(self):
        blob=lua({'p':{'1':{'ink':{i:{'p':{1:i,2:i+1}} for i in range(10000)}}}})
        parser=cleaner.Parser(blob);node=parser.value()
        drawing=cleaner.field(cleaner.field(node,b'p').value[0][1],b'ink')
        self.assertIsNone(drawing.value);self.assertGreater(parser.nodes,50000)
        cleaned,count=cleaner.clean_document(node,blob)
        self.assertEqual(cleaned,lua({'p':{'1':{}}}));self.assertEqual(count,1)

if __name__=='__main__':unittest.main()
