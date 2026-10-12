#!/usr/bin/env python3
"""Remove book drawings offline, preserving serialized text and item framing.

Caller must prove the JVM is stopped (or run in ExecStartPre before the JVM).
Supported storage version: 249. Changes are prepared and backed up before any
world mutation. A pending manifest resumes only when every target matches its
recorded original or cleaned hash; conflicting changes refuse startup.
"""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from dataclasses import dataclass

VERSION = 249
MARKER = b"\x00\x00\x0bNeatWriting\x02"
LITERATURE_TYPES = frozenset("Base." + name for name in (
    "Notepad", "Notebook", "Journal", "Diary1", "Diary2", "SheetPaper2",
    "SheetPaper", "Card_Birthday", "Card_Christmas", "Card_Easter",
    "Card_Hanukkah", "Card_LunarYear", "Card_StPatrick", "Card_Valentine",
    "IndexCard", "GraphPaper", "MenuCard", "IDcard_Blank", "Card_Halloween",
    "Card_Sympathy"))

# Saved v249 pouch from Frockin Splendor Vol.5 (Workshop 3635394848),
# FSV_TannedLeather.txt ItemType=base:Container; independently validated by PZ loader.
VERIFIED_MOD_CONTAINERS=frozenset({"Base.Armour_PouchStrap"})

# Vanilla build42 script catalog: generated/items/container.txt, ItemType=base:container.
CONTAINER_TYPES = frozenset("Base." + name for name in (
    'Armour_PouchStrap',
    'Bag_GolfBag',
    'Bag_GolfBag_Melee',
    'Bag_Schoolbag',
    'Bag_Schoolbag_Kids',
    'Bag_NormalHikingBag',
    'Bag_BigHikingBag',
    'Bag_SurvivorBag',
    'Bag_ALICEpack',
    'Bag_ALICEpack_Army',
    'Bag_WeaponBag',
    'Bag_InmateEscapedBag',
    'Bag_MoneyBag',
    'Bag_WorkerBag',
    'Bag_DuffelBag',
    'Bag_BreakdownBag',
    'Bag_DuffelBagTINT',
    'Plasticbag',
    'Plasticbag_Clothing',
    'Garbagebag',
    'Tote',
    'Tote_Clothing',
    'Purse',
    'EmptySandbag',
    'Bag_DeadRats',
    'Bag_DeadMice',
    'Bag_DeadRoaches',
    'Bag_TreasureBag',
    'Suitcase',
    'Handbag',
    'Toolbox',
    'Toolbox_Farming',
    'Toolbox_Wooden',
    'FirstAidKit',
    'Lunchbox',
    'Lunchbox2',
    'Flightcase',
    'Guitarcase',
    'Bag_FannyPackFront',
    'Bag_FannyPackBack',
    'Briefcase',
    'Bag_Satchel',
    'Cooler',
    'PistolCase1',
    'PistolCase2',
    'PistolCase3',
    'RevolverCase1',
    'RevolverCase2',
    'RevolverCase3',
    'Bag_RifleCaseCloth',
    'Bag_RifleCaseCloth2',
    'Bag_ShotgunCaseCloth',
    'Bag_ShotgunCaseCloth2',
    'Bag_RifleCaseClothCamo',
    'Bag_RifleCase',
    'Bag_RifleCase_Police',
    'Bag_RifleCase_Police2',
    'Bag_RifleCase_Police3',
    'Bag_ShotgunCase_Police',
    'Bag_RifleCaseGreen',
    'Bag_RifleCaseGreen2',
    'Bag_ShotgunCaseGreen',
    'Bag_FluteCase',
    'Bag_ViolinCase',
    'Bag_TrumpetCase',
    'Bag_SaxophoneCase',
    'Bag_JanitorToolbox',
    'Toolbox_Mechanic',
    'Bag_ShotgunBag',
    'Bag_ShotgunSawnoffBag',
    'Bag_ShotgunDblBag',
    'Bag_ShotgunDblSawnoffBag',
    'Bag_BowlingBallBag',
    'Bag_ALICE_BeltSus',
    'Bag_ALICE_BeltSus_Camo',
    'Bag_ALICE_BeltSus_Green',
    'Bag_BurglarBag',
    'Bag_SatchelPhoto',
    'Bag_TrashBag',
    'Cooler_Beer',
    'Cooler_Meat',
    'Cooler_Soda',
    'Plasticbag_Bags',
    'Tote_Bags',
    'Bag_Dancer',
    'Briefcase_Money',
    'Toolbox_Fishing',
    'Toolbox_Gardening',
    'FirstAidKit_New',
    'FirstAidKit_NewPro',
    'Bag_ProtectiveCase',
    'Bag_ProtectiveCase_Survivalist',
    'Bag_ProtectiveCase_Tools',
    'Bag_ProtectiveCaseMilitary',
    'Bag_ProtectiveCaseMilitary_Medical',
    'Bag_ProtectiveCaseMilitary_Tools',
    'Bag_ProtectiveCaseSmall',
    'Bag_ProtectiveCaseSmall_Armorer',
    'Bag_ProtectiveCaseSmall_Electronics',
    'Bag_ProtectiveCaseSmall_Survivalist',
    'Bag_ProtectiveCaseSmall_WalkieTalkie',
    'Bag_ProtectiveCaseSmall_WalkieTalkiePolice',
    'Bag_ProtectiveCaseSmall_FirstAid',
    'Bag_ProtectiveCaseSmall_Pistol1',
    'Bag_ProtectiveCaseSmall_Pistol2',
    'Bag_ProtectiveCaseSmall_Pistol3',
    'Bag_ProtectiveCaseSmall_Revolver1',
    'Bag_ProtectiveCaseSmall_Revolver2',
    'Bag_ProtectiveCaseSmall_Revolver3',
    'Bag_ProtectiveCaseSmallMilitary',
    'Bag_ProtectiveCaseSmallMilitary_WalkieTalkie',
    'Bag_ProtectiveCaseSmallMilitary_FirstAid',
    'Bag_ProtectiveCaseSmallMilitary_Pistol1',
    'Bag_ProtectiveCaseBulky',
    'Bag_ProtectiveCaseBulky_SCBA',
    'Bag_ProtectiveCaseBulky_Audio',
    'Bag_ProtectiveCaseBulky_HAMRadio1',
    'Bag_ProtectiveCaseBulkyAmmo',
    'Bag_ProtectiveCaseBulkyAmmo_556',
    'Bag_ProtectiveCaseBulkyAmmo_308',
    'Bag_ProtectiveCaseBulkyAmmo_ShotgunShells',
    'Bag_ProtectiveCaseBulkyAmmo_9mm',
    'Bag_ProtectiveCaseBulkyAmmo_38',
    'Bag_ProtectiveCaseBulkyAmmo_44',
    'Bag_ProtectiveCaseBulkyAmmo_45',
    'Bag_ProtectiveCaseBulkyAmmo_Hunting',
    'Bag_ProtectiveCaseBulkyMilitary',
    'Bag_ProtectiveCaseBulky_Survivalist',
    'Bag_ProtectiveCaseBulkyMilitary_HAMRadio2',
    'Bag_ProtectiveCaseBulkyHazard',
    'Bag_Police',
    'Bag_Sheriff',
    'Bag_SWAT',
    'Tacklebox',
    'Bag_FishingBasket',
    'Bag_GardenBasket',
    'Bag_PicnicBasket',
    'Bag_BirthdayBasket',
    'Bag_Schoolbag_Patches',
    'Bag_Schoolbag_Travel',
    'Bag_BigHikingBag_Travel',
    'Bag_HikingBag_Travel',
    'Bag_Satchel_Fishing',
    'Bag_Satchel_Medical',
    'Bag_Satchel_Military',
    'Bag_Schoolbag_Medical',
    'Bag_Gunny',
    'Bag_Laundry',
    'Bag_LaundryLinen',
    'Bag_LaundryHospital',
    'Bag_Mail',
    'Bag_Satchel_Mail',
    'Bag_Satchel_Leather',
    'Bag_AmmoBox',
    'Bag_AmmoBox_308',
    'Bag_AmmoBox_ShotgunShells',
    'Bag_AmmoBox_9mm',
    'Bag_AmmoBox_38',
    'Bag_AmmoBox_44',
    'Bag_AmmoBox_45',
    'Bag_AmmoBox_Mixed',
    'Bag_AmmoBox_Hunting',
    'Bag_BaseballBag',
    'Bag_TennisBag',
    'Bag_FoodCanned',
    'Bag_FoodSnacks',
    'Bag_MedicalBag',
    'Bag_Military',
    'Bag_ToolBag',
    'GroceryBag1',
    'GroceryBag2',
    'GroceryBag3',
    'GroceryBag4',
    'GroceryBag5',
    'GroceryBagGourmet',
    'RifleCase1',
    'RifleCase2',
    'RifleCase3',
    'RifleCase4',
    'ShotgunCase1',
    'ShotgunCase2',
    'Bag_DoctorBag',
    'Parcel_ExtraSmall',
    'Parcel_Small',
    'Parcel_Medium',
    'Parcel_Large',
    'Parcel_ExtraLarge',
    'Present_ExtraSmall',
    'Present_Small',
    'Present_Medium',
    'Present_Large',
    'Present_ExtraLarge',
    'HollowBook',
    'HollowFancyBook',
    'HollowBook_Handgun',
    'HollowBook_Kids',
    'HollowBook_Prison',
    'HollowBook_Valuables',
    'HollowBook_Whiskey',
    'Wallet',
    'Wallet_Female',
    'Wallet_Male',
    'Lunchbag',
    'PaperBag',
    'Paperbag_Jays',
    'Paperbag_Spiffos',
    'SeedBag',
    'SeedBag_Farming',
    'SewingKit',
    'KeyRing',
    'KeyRing_CarDealer',
    'KeyRing_Bass',
    'KeyRing_BlueFox',
    'KeyRing_Bug',
    'KeyRing_Clover',
    'KeyRing_EagleFlag',
    'KeyRing_EightBall',
    'KeyRing_Hotdog',
    'KeyRing_Kitty',
    'KeyRing_Large',
    'KeyRing_Nolans',
    'KeyRing_Panther',
    'KeyRing_PineTree',
    'KeyRing_PrayingHands',
    'KeyRing_RabbitFoot',
    'KeyRing_RainbowStar',
    'KeyRing_RubberDuck',
    'KeyRing_SecurityPass',
    'KeyRing_Sexy',
    'KeyRing_Spiffos',
    'KeyRing_StinkyFace',
    'KeyRing_WestMaple',
    'KeyRing_Racing12',
    'KeyRing_Racing34',
    'KeyRing_Racing58',
    'WheatSack',
    'WheatSeedSack',
    'GemBag',
    'DiceBag',
    'TakeoutBox_Styrofoam',
    'TakeoutBox_Chinese',
    'PencilCase',
    'PencilCase_Gaming',
    'Humidor',
    'CigarBox',
    'CigarBox_Gaming',
    'CigarBox_Keepsakes',
    'CigarBox_Kids',
    'CookieJar',
    'CookieJar_Bear',
    'JewelleryBox',
    'JewelleryBox_Fancy',
    'FirstAidKit_Camping',
    'FirstAidKit_Camping_New',
    'FirstAidKit_Military',
    'HalloweenCandyBucket',
    'MakeupCase_Professional',
    'Cashbox',
    'ToolRoll_Leather',
    'ToolRoll_Fabric',
    'Hatbox',
    'Shoebox',
    'PhotoAlbum',
    'PhotoAlbum_Old',
    'ProduceBox_ExtraSmall',
    'ProduceBox_Small',
    'ProduceBox_Medium',
    'ProduceBox_Large',
    'ProduceBox_ExtraLarge',
    'Cooler_Seafood',
    'Bag_ALICEpack_DesertCamo',
    'Bag_ChestRig',
    'Bag_ProtectiveCaseSmall_KeyCutting',
    'Bag_ChestRig_Tarp',
    'Bag_ClothSatchel_Burlap',
    'Bag_ClothSatchel_Cotton',
    'Bag_ClothSatchel_Denim',
    'Bag_ClothSatchel_DenimBlack',
    'Bag_ClothSatchel_DenimLight',
    'Bag_CrudeLeatherBag',
    'Bag_CrudeTarpBag',
    'Bag_HideSlingBag',
    'Bag_FannyPackFront_Hide',
    'Bag_FannyPackBack_Hide',
    'Bag_FannyPackFront_Tarp',
    'Bag_FannyPackBack_Tarp',
    'Bag_HideSack',
    'Bag_TarpSack',
    'Bag_HideSatchel',
    'Bag_SheetSlingBag',
    'Bag_TarpSlingBag',
    'KeyRing_Forged',
    'KeyRing_Forged_Gold',
    'KeyRing_Forged_Silver',
    'Wallet_Hide',
    'Bag_CraftedFramepack_Large',
    'Bag_CraftedFramepack_Small',
    'Bag_CraftedFramepack_Large2',
    'Bag_CraftedFramepack_Large3',
    'Bag_TarpFramepack_Small',
    'Bag_TarpFramepack_Large',
    'AmmoStrap_Bullets',
    'AmmoStrap_Brown_Bullets',
    'AmmoStrap_Bullets_308',
    'AmmoStrap_Shells',
    'AmmoStrap_Brown_Shells',
    'HolsterShoulder',
    'Bag_HydrationBackpack',
    'Bag_HydrationBackpack_Camo',
))

class CleanupError(ValueError): pass

@dataclass
class Node:
    kind: int
    start: int
    end: int
    value: object

class Parser:
    def __init__(self, blob): self.blob = blob; self.pos = 0; self.nodes = 0
    def number(self, fmt):
        size = struct.calcsize(fmt)
        if self.pos + size > len(self.blob): raise CleanupError("Truncated Lua value")
        value = struct.unpack_from(fmt, self.blob, self.pos)[0]; self.pos += size
        return value
    def value(self, depth=0):
        self.nodes += 1
        if depth > 32 or self.nodes > 2000000: raise CleanupError("Lua table safety bound exceeded")
        start = self.pos; kind = self.number(">B")
        if kind == 0:
            length = self.number(">H")
            if self.pos + length > len(self.blob): raise CleanupError("Truncated Lua string")
            value = self.blob[self.pos:self.pos+length]; self.pos += length
        elif kind == 1: value = self.number(">d")
        elif kind == 3:
            value = self.number(">B")
            if value not in (0, 1): raise CleanupError("Invalid Lua boolean")
        elif kind == 2:
            length = self.number(">i")
            if not 0 <= length <= 100000: raise CleanupError("Invalid Lua table size")
            value = []
            for _ in range(length):
                key = self.value(depth+1)
                child = self.skip_value(depth+1) if key.kind == 0 and key.value in (b"ink", b"sym") else self.value(depth+1)
                value.append((key, child))
            keys = [(key.kind, key.value) for key, _ in value]
            if any(key.kind not in (0, 1, 3) for key, _ in value) or len(set(keys)) != len(keys):
                raise CleanupError("Ambiguous Lua table keys")
        else: raise CleanupError("Unsupported Lua value type")
        return Node(kind, start, self.pos, value)

    def skip_value(self, depth=0):
        """Validate framing without allocating coordinate tables/float nodes."""
        self.nodes += 1
        if depth > 32 or self.nodes > 2000000: raise CleanupError("Lua drawing safety bound exceeded")
        start = self.pos; kind = self.number(">B")
        if kind == 0:
            size = self.number(">H"); self.pos += size
        elif kind == 1: self.pos += 8
        elif kind == 3:
            if self.number(">B") not in (0,1): raise CleanupError("Invalid Lua boolean")
        elif kind == 2:
            length = self.number(">i")
            if not 0 <= length <= 100000: raise CleanupError("Invalid drawing table size")
            for _ in range(length):
                if self.skip_value(depth+1).kind not in (0,1,3): raise CleanupError("Invalid drawing table key")
                self.skip_value(depth+1)
        else: raise CleanupError("Unsupported drawing value type")
        if self.pos > len(self.blob): raise CleanupError("Truncated drawing value")
        return Node(kind,start,self.pos,None)


def script_classes(root):
    """Classify static script item definitions; unclassified types remain refused."""
    root=safe_root(root);classes={}
    for path in root.rglob("*.txt"):
        if path.is_symlink():raise CleanupError("Script catalog symlink refused")
        text=read_file(path).decode("utf-8-sig")
        text=re.sub(r"/\*.*?\*/|//[^\n]*","",text,flags=re.S)
        modules=re.findall(r"\bmodule\s+(\w+)\s*\{",text)
        if len(modules)!=1:continue
        for name,body in re.findall(r"\bitem\s+(\w+)\s*\{([^{}]*)\}",text):
            types=re.findall(r"\b(?:ItemType|Type)\s*=\s*([\w:]+)\s*,",body)
            if len(types)!=1:continue
            kind=types[0].split(":")[-1].lower();fulltype=modules[0]+"."+name
            if fulltype in classes and classes[fulltype]!=kind:raise CleanupError("Conflicting script item classes")
            classes[fulltype]=kind
    if not classes:raise CleanupError("No static item classes found in script catalog")
    return classes

class Registry(dict):
    def __init__(self,items,classes):super().__init__(items);self.classes=classes

def dictionary(path,scripts_dir=None):
    entries = re.findall(r'registryID\s*=\s*(\d+)\s*,\s*fulltype\s*=\s*"([^"]+)"', read_file(path).decode("utf-8"))
    result = {}
    for ident, name in entries:
        ident = int(ident)
        if ident > 32767 or ident in result: raise CleanupError("Ambiguous item registry")
        result[ident] = name
    if not result: raise CleanupError("Readable item registry is missing or unsupported")
    classes=script_classes(scripts_dir) if scripts_dir else {}
    classes.update({name:"container" for name in CONTAINER_TYPES})
    classes.update({name:"literature" for name in LITERATURE_TYPES})
    return Registry(result,classes)


def field(table, key):
    if table.kind != 2: return None
    return next((value for name, value in table.value if name.kind == 0 and name.value == key), None)


def clean_document(node, blob):
    pages = field(node, b"p")
    if pages is None: return blob[node.start:node.end], 0
    if pages.kind != 2: raise CleanupError("Book pages must be a Lua table")
    targets = {node.start}
    for _, page in pages.value:
        if page.kind != 2: raise CleanupError("Book page must be a Lua table")
        targets.add(page.start)
    removed = 0
    def encode(value):
        nonlocal removed
        if value.kind != 2 or value.value is None: return blob[value.start:value.end]
        entries = []
        for key, child in value.value:
            if value.start in targets and key.kind == 0 and key.value in (b"ink", b"sym"):
                if child.kind != 2: raise CleanupError("Drawing list must be a Lua table")
                removed += 1
                continue
            entries.append(blob[key.start:key.end] + encode(child))
        return b"\x02" + struct.pack(">i", len(entries)) + b"".join(entries)
    output = encode(node)
    return output, removed


def is_class(registry,rid,kind):
    name=registry[rid]
    value=getattr(registry,"classes",{}).get(name)
    if value is not None:return value==kind
    return name in (LITERATURE_TYPES if kind=="literature" else CONTAINER_TYPES)


def clean_blob(blob, registry, version=VERSION, chunk=False):
    documents = []; pos = 0
    while True:
        found = blob.find(MARKER, pos)
        if found < 0: break
        parser = Parser(blob); parser.pos = found + len(MARKER) - 1
        node = parser.value(); pos = node.end
        new, removed = clean_document(node, blob)
        if removed: documents.append((found, node.start, node.end, new, removed))
    if not documents: return blob, []
    if version != VERSION: raise CleanupError("Unsupported storage version; expected 249")
    if chunk:
        if len(blob) < 17 or blob[0] != 0: raise CleanupError("Unsupported chunk header")
        stored_version, length, crc = struct.unpack_from(">iiq", blob, 1)
        if stored_version != VERSION or length != len(blob) or crc != zlib.crc32(blob[17:]):
            raise CleanupError("Chunk version, length or checksum mismatch")
    records = {}
    for match in re.finditer(b"\xff", blob):
        start = match.start() - 6
        if start < 0 or start+11 > len(blob): continue
        length, rid = struct.unpack_from(">ih", blob, start); end = start + 4 + length
        if rid not in registry or length < 8 or end > len(blob): continue
        if struct.unpack_from(">i", blob, start+7)[0] in (0, -1): continue
        covered = [doc for doc in documents if start+11 <= doc[0] and doc[2] <= end]
        if not covered: continue
        # Keep every plausible covering envelope. Ignoring a non-container
        # could mistake an item serialized inside opaque text for a real child.
        # World floor items are direct records. Nested/compressed inventory
        # records have a positive item count immediately before their envelope.
        count_valid = start >= 4 and 1 <= struct.unpack_from(">i", blob, start-4)[0] <= 100000
        # Direct world-floor records are supported only for explicit NeatWriting
        # layouts. Script classification must not admit arbitrary magazines here.
        if not count_valid and registry[rid] not in LITERATURE_TYPES: continue
        records[start] = (end, rid, covered)
    for doc in documents:
        containing = sorted((start, end, rid) for start, (end, rid, docs) in records.items() if doc in docs)
        if not containing: raise CleanupError("Book drawing has no validated inventory envelope")
        for outer, inner in zip(containing, containing[1:]):
            if not outer[0] < inner[0] < inner[1] <= outer[1]: raise CleanupError("Ambiguous nested inventory framing")
            if not is_class(registry,outer[2],"container"): raise CleanupError("Unproven container ancestor type: "+registry[outer[2]])
        if not is_class(registry,containing[-1][2],"literature"):
            raise CleanupError("Unsupported dirty item type: " + registry[containing[-1][2]])
    replacements = [(at, end, new) for _, at, end, new, _ in documents]
    for start, (end, _, docs) in records.items():
        delta = sum(len(doc[3])-(doc[2]-doc[1]) for doc in docs)
        replacements.append((start, start+4, struct.pack(">i", end-start-4+delta)))
    replacements.sort(); parts = []; cursor = 0
    for start, end, new in replacements:
        if start < cursor: raise CleanupError("Overlapping serialization changes")
        parts.extend((blob[cursor:start], new)); cursor = end
    parts.append(blob[cursor:]); output = b"".join(parts)
    def shifted(at): return at + sum(len(new)-(end-start) for start, end, new in replacements if end <= at)
    def record_metadata(start):
        end,rid,_ = records[start]
        return {"itemType":registry[rid], "itemId":struct.unpack_from(">i",blob,start+7)[0],
                "class":"Literature" if is_class(registry,rid,"literature") else "InventoryContainer",
                "record_start":start,"record_end":end,
                "new_record_start":shifted(start),"new_record_end":shifted(end)}
    details = []
    for doc in documents:
        _, start, rid = min((end-start, start, rid) for start, (end, rid, docs) in records.items() if doc in docs)
        end = records[start][0]
        detail=record_metadata(start)
        detail.update(drawing_fields_removed=doc[4],preserved_document_sha256=digest(doc[3]),
                      ancestors=[record_metadata(ancestor) for ancestor,(ancestor_end,_,docs) in records.items()
                                 if ancestor != start and doc in docs])
        details.append(detail)
    for start, (end, _, _) in records.items():
        new_start, new_end = shifted(start), shifted(end)
        if struct.unpack_from(">i", output, new_start)[0] != new_end-new_start-4:
            raise CleanupError("Inventory size postcondition failed")
        if output[new_start+4:new_start+11] != blob[start+4:start+11]: raise CleanupError("Item identity changed")
    if chunk:
        output = bytearray(output); struct.pack_into(">iq", output, 5, len(output), zlib.crc32(output[17:])); output = bytes(output)
    # Re-parsing proves idempotence of the resulting documents, independently
    # of the envelope scan that selected them for mutation.
    pos = 0
    while True:
        found = output.find(MARKER, pos)
        if found < 0: break
        parser = Parser(output); parser.pos = found+len(MARKER)-1; node = parser.value(); pos = node.end
        if clean_document(node, output)[1]: raise CleanupError("Drawing cleanup postcondition failed")
    return output, details


def digest(data): return hashlib.sha256(data).hexdigest()

def read_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode): raise CleanupError("Expected a regular file")
        return stream.read()

def safe_root(path, create=False):
    path = Path(os.path.abspath(path)); current = Path(path.anchor)
    trusted = {os.getuid(), os.stat("/").st_uid}; private_anchor = False
    for part in path.parts[1:]:
        current /= part
        if not current.exists():
            if not create: raise CleanupError("Storage directory missing")
            current.mkdir(mode=0o700)
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in trusted:
            raise CleanupError("Storage path is a symlink or owned by another user")
        sticky_root = info.st_uid == os.stat("/").st_uid and info.st_mode & stat.S_ISVTX
        if info.st_mode & 0o002 and not sticky_root:
            raise CleanupError("Storage directory is world-writable")
        if info.st_mode & 0o020 and not private_anchor and not sticky_root:
            raise CleanupError("Group-writable storage lacks a private ancestor")
        if info.st_uid == os.getuid() and not info.st_mode & 0o077: private_anchor = True
    return path

def atomic_file(path, data, mode=0o600):
    fd, temp = tempfile.mkstemp(prefix="."+path.name+".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fchmod(stream.fileno(), mode); os.fsync(stream.fileno())
        os.replace(temp, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(parent)
        finally: os.close(parent)
    finally:
        if os.path.exists(temp): os.unlink(temp)


def world_files(world):
    # No symlink traversal, and refuse unknown dirty binary paths rather than
    # silently leaving a drawing that might be loaded later.
    for root, dirs, files in os.walk(world, followlinks=False):
        for name in dirs:
            if (Path(root)/name).is_symlink(): raise CleanupError("World directory symlink refused")
        for name in files:
            path = Path(root)/name
            if path.is_symlink(): raise CleanupError("World file symlink refused")
            rel = path.relative_to(world)
            if name.endswith(".bin") and name != "WorldDictionary.bin": yield rel


def file_identity(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def load_scan_cache(path, world):
    """A cache is only a hint; unavailable or malformed hints trigger full reads."""
    if path is None:
        return {}
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return {}
        data = json.loads(read_file(path))
        if not isinstance(data, dict) or data.get('schema') != 1 or data.get('world') != str(world) or data.get('version') != VERSION:
            return {}
        files = data['files']
        if not isinstance(files, dict) or any(not isinstance(v, list) or len(v) != 5
                or any(type(n) is not int for n in v) for v in files.values()):
            return {}
        return files
    except (OSError, ValueError, TypeError, KeyError):
        return {}


def drawing_files(world, cached=None, scanned=None):
    """Read ahead at most 16 files, with eight readers and ordered results.

    Workers only read and find the marker. Lua parsing, staging and mutation
    remain in the calling thread, after the same complete validation plan.
    """
    def read(rel):
        path = world/rel
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise CleanupError('World file must be regular')
        identity = file_identity(before)
        if cached is not None and cached.get(str(rel)) == identity:
            if scanned is not None:
                scanned[str(rel)] = identity
            return rel, None
        blob=read_file(path)
        if identity != file_identity(path.lstat()):
            raise CleanupError('World file changed during scan')
        # Cache only absence of Writing data. Files containing Writing are
        # always parsed, including clean notes and previously cleaned drawings.
        if MARKER not in blob and scanned is not None:
            scanned[str(rel)] = identity
        return rel,blob if MARKER in blob else None
    paths=iter(world_files(world));waiting=deque()
    with ThreadPoolExecutor(max_workers=8) as pool:
        def schedule():
            try:rel=next(paths)
            except StopIteration:return False
            waiting.append(pool.submit(read,rel));return True
        for _ in range(16):
            if not schedule():break
        while waiting:
            result=waiting.popleft().result()
            schedule()
            yield result


def check_database_files(world):
    for suffix in ("-wal", "-journal"):
        path = world/("players.db"+suffix)
        if path.exists() and (path.is_symlink() or path.stat().st_size):
            raise CleanupError("SQLite sidecar must be checkpointed before offline cleanup")


def file_digest(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,"rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise CleanupError("Expected regular storage file")
        sha=hashlib.sha256()
        for chunk in iter(lambda:stream.read(1024*1024),b""): sha.update(chunk)
        return sha.hexdigest()

def stage_change(stage,world,rel,original,new,items=None):
    for folder,data in (("original",original),("new",new)):
        target=stage/folder/rel;target.parent.mkdir(parents=True,exist_ok=True,mode=0o700);atomic_file(target,data)
    return {"path":str(rel),"original_sha256":digest(original),"new_sha256":digest(new),"mode":stat.S_IMODE((world/rel).stat().st_mode),"items":items or []}

def prepare(world,stage,scripts_dir=None,cached=None,scanned=None):
    registry=dictionary(world/"WorldDictionaryReadable.lua",scripts_dir);files=[];rows=[]
    db=world/"players.db";check_database_files(world)
    if db.exists():
        original_hash=file_digest(db);reader=sqlite3.connect(db.resolve().as_uri()+"?mode=ro",uri=True);writer=None
        try:
            if reader.execute("PRAGMA quick_check").fetchone()[0]!="ok":raise CleanupError("SQLite integrity check failed")
            for table in ("networkPlayers","localPlayers"):
                for ident,version,blob in reader.execute(f"SELECT id,worldversion,data FROM {table}"):
                    new,detail=clean_blob(blob,registry,version)
                    if not detail:continue
                    if writer is None:
                        for folder in ("original","new"):
                            target=stage/folder/"players.db";target.parent.mkdir(parents=True,exist_ok=True,mode=0o700);shutil.copyfile(db,target)
                        writer=sqlite3.connect(stage/"new/players.db");writer.execute("BEGIN IMMEDIATE")
                    writer.execute(f"UPDATE {table} SET data=? WHERE id=?",(new,ident))
                    rows.append({"table":table,"id":ident,"version":version,"original_sha256":digest(blob),"new_sha256":digest(new),"items":detail})
            if writer is not None:
                writer.commit()
                if writer.execute("PRAGMA integrity_check").fetchone()[0]!="ok":raise CleanupError("Cleaned SQLite integrity check failed")
        finally:
            reader.close()
            if writer is not None:writer.close()
        if rows:
            if file_digest(db)!=original_hash or file_digest(stage/"original/players.db")!=original_hash:raise CleanupError("Player database changed during planning")
            files.append({"path":"players.db","original_sha256":original_hash,"new_sha256":file_digest(stage/"new/players.db"),"mode":stat.S_IMODE(db.stat().st_mode),"items":[]})
    for rel,original in drawing_files(world,cached,scanned):
        if original is None:continue
        known=rel.parts[0]=="map" or rel==Path("reanimated.bin")
        new,detail=clean_blob(original,registry,VERSION,chunk=rel.parts[0]=="map")
        if detail:
            if not known:raise CleanupError("Unsupported dirty world file: "+str(rel))
            files.append(stage_change(stage,world,rel,original,new,detail))
    return files,rows


def atomic_copy(path,source,mode=0o600):
    fd,temp=tempfile.mkstemp(prefix="."+path.name+".",dir=path.parent)
    try:
        with os.fdopen(fd,"wb") as writer:
            reader_fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(reader_fd,"rb") as reader:shutil.copyfileobj(reader,writer,1024*1024)
            writer.flush();os.fchmod(writer.fileno(),mode);os.fsync(writer.fileno())
        os.replace(temp,path)
        parent=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(parent)
        finally:os.close(parent)
    finally:
        if os.path.exists(temp):os.unlink(temp)


def manifest_path(stage): return stage/"manifest.json"

def write_manifest(stage, manifest):
    atomic_file(manifest_path(stage), json.dumps(manifest,indent=2,sort_keys=True).encode()+b"\n")

def recover(world, stage, validator=None):
    manifest = json.loads(read_file(manifest_path(stage)))
    if manifest.get("schema") != 1 or manifest.get("world") != str(world) or manifest.get("version") != VERSION:
        raise CleanupError("Pending cleanup belongs to another world or format")
    entries = manifest["files"]
    for entry in entries:
        rel = Path(entry["path"])
        if rel.is_absolute() or ".." in rel.parts or not rel.parts: raise CleanupError("Invalid cleanup manifest path")
        safe_root(stage/"original"/rel.parent);safe_root(stage/"new"/rel.parent);safe_root(world/rel.parent)
        if file_digest(stage/"original"/rel) != entry["original_sha256"] or file_digest(stage/"new"/rel) != entry["new_sha256"]:
            raise CleanupError("Cleanup backup/staging integrity mismatch")
        if file_digest(world/rel) not in (entry["original_sha256"],entry["new_sha256"]):
            raise CleanupError("World changed during interrupted cleanup; manual recovery required")
    check_database_files(world)
    if validator is None: raise CleanupError("A genuine PZ record validator is required before applying cleanup")
    validator(stage,entries,manifest["players"])
    for entry in entries:
        rel = Path(entry["path"])
        if file_digest(world/rel) == entry["original_sha256"]:
            atomic_copy(world/rel, stage/"new"/rel, entry["mode"])
    manifest["state"] = "complete"; manifest["completed_at"] = time.time(); write_manifest(stage,manifest)
    return len(entries)


def cleanup(world_dir, backup_dir, dry_run=False, validator=None, scripts_dir=None, scan_cache=None):
    world_path=Path(os.path.abspath(world_dir))
    if world_path.is_symlink():raise CleanupError("World symlink refused")
    if not world_path.exists():
        ancestor=world_path.parent
        while not ancestor.exists() and not ancestor.is_symlink():ancestor=ancestor.parent
        safe_root(ancestor)
        return {"files":0,"players":0,"version":VERSION,"dry_run":dry_run}
    world = safe_root(world_path); backups = Path(os.path.abspath(backup_dir))
    if not (world/"WorldDictionaryReadable.lua").exists():
        saved=any(world.rglob("*.bin"))
        db=world/"players.db"
        if db.exists():
            check_database_files(world);read_file(db)
            reader=sqlite3.connect(db.resolve().as_uri()+"?mode=ro",uri=True)
            try:
                if reader.execute("PRAGMA quick_check").fetchone()[0]!="ok":raise CleanupError("SQLite integrity check failed")
                tables={row[0] for row in reader.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                for table in ("networkPlayers","localPlayers"):
                    if table in tables and reader.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone():saved=True
            finally:reader.close()
        if saved:raise CleanupError("Saved world data exists without its readable item dictionary")
        return {"files":0,"players":0,"version":VERSION,"dry_run":dry_run}
    if backups == world or world in backups.parents: raise CleanupError("Backup directory must be outside the world")
    cache_path = None
    if scan_cache is not None and not dry_run:
        cache_path = Path(os.path.abspath(scan_cache))
        if cache_path == world or world in cache_path.parents:
            raise CleanupError('Scan cache must be outside the world')
        # Apply is admitted under WORLD; the cache never replaces player DB
        # checks, pending transaction recovery or real record validation.
        safe_root(cache_path.parent, create=not dry_run)
    cached = load_scan_cache(cache_path, world)
    scanned = {}

    def save_cache():
        if cache_path is None or dry_run:
            return
        try:
            atomic_file(cache_path, json.dumps({'schema': 1, 'world': str(world),
                'version': VERSION, 'files': scanned}, separators=(',', ':')).encode())
        except OSError:
            # An optimization cannot prevent an otherwise successful startup.
            print('ProjectWriting scan cache unavailable; next scan will reread files', file=sys.stderr)
    if backups.exists():
        backups = safe_root(backups)
        for pending in sorted(backups.glob("cleanup-*")):
            if pending.is_symlink(): raise CleanupError("Cleanup backup symlink refused")
            if not manifest_path(pending).exists(): continue
            manifest = json.loads(read_file(manifest_path(pending)))
            if manifest.get("state") == "prepared":
                if dry_run: raise CleanupError("Pending cleanup requires recovery before dry-run")
                recover(world,pending,validator)
    # Planning lives in a disposable private directory. No source changes occur
    # until all formats, SQLite data and chunk checksums have been validated.
    with tempfile.TemporaryDirectory(prefix="pz-writing-plan-") as temporary:
        files, rows = prepare(world, Path(temporary),scripts_dir,cached,scanned)
        summary = {"files":len(files),"players":len(rows),"version":VERSION,"dry_run":dry_run}
        if dry_run or not files:
            save_cache()
            return summary
        if validator is None: raise CleanupError("A genuine PZ record validator is required before applying cleanup")
        validator(Path(temporary),files,rows)
        backups = safe_root(backups,create=True)
        stage = Path(tempfile.mkdtemp(prefix="cleanup-",dir=backups))
        entries = files
        for entry in entries:
            rel=Path(entry["path"])
            for folder in ("original","new"):
                target=stage/folder/rel;target.parent.mkdir(parents=True,exist_ok=True,mode=0o700);atomic_copy(target,Path(temporary)/folder/rel)
        manifest = {"schema":1,"world":str(world),"version":VERSION,"created_at":time.time(),"state":"prepared","files":entries,"players":rows}
        write_manifest(stage,manifest)
        recover(world,stage,validator)
        summary["backup"] = str(stage)
        save_cache()
        return summary


def validation_manifest(stage,files,rows,fixtures):
    """Write ephemeral record slices; private player data never enters the repository."""
    fixtures.mkdir(mode=0o700)
    records=[]
    def add(before,after,details,version):
        seen=set()
        for item in details:
            for meta in [item]+item["ancestors"]:
                start,end=meta["record_start"],meta["record_end"]
                if start in seen: continue
                seen.add(start)
                record=dict(meta,worldVersion=version,bodyOffset=7)
                for name,blob,lo,hi in (("before",before,start,end),("after",after,meta["new_record_start"],meta["new_record_end"])):
                    path=fixtures/(str(len(records))+"-"+name+".bin")
                    atomic_file(path,blob[lo:hi]);record[name]=str(path)
                records.append(record)
    for entry in files:
        if entry["path"]=="players.db":continue
        rel=Path(entry["path"])
        add(read_file(stage/"original"/rel),read_file(stage/"new"/rel),entry["items"],VERSION)
    if rows:
        before=sqlite3.connect((stage/"original/players.db").resolve().as_uri()+"?mode=ro",uri=True)
        after=sqlite3.connect((stage/"new/players.db").resolve().as_uri()+"?mode=ro",uri=True)
        try:
            for row in rows:
                table=row["table"]
                if table not in ("networkPlayers","localPlayers"):raise CleanupError("Invalid validation player table")
                sql=f"SELECT data FROM {table} WHERE id=?"
                add(before.execute(sql,(row["id"],)).fetchone()[0],after.execute(sql,(row["id"],)).fetchone()[0],row["items"],row["version"])
        finally:before.close();after.close()
    manifest=fixtures/"records.json"
    atomic_file(manifest,json.dumps({"records":records}).encode())
    return manifest,len(records)

class JavaValidator:
    """Compile auditable source and run real PZ loaders with bounded heap."""
    def __init__(self,jar,java,javac=None,lock_fd=None):
        if not all((jar,java)):raise CleanupError("Dirty APPLY requires --jar and --java")
        self.jar=jar;self.java=java;self.javac=javac
        self.lock_fd=lock_fd
    def tools(self):
        self.jar=str(Path(self.jar).resolve(strict=True))
        self.java=str(Path(self.java).resolve(strict=True))
        # An explicit compiler is authoritative: never silently replace a bad
        # operator override. A bundled JRE otherwise uses the installed JDK.
        compiler=self.javac
        if compiler is None:
            sibling=Path(self.java).with_name("javac")
            compiler=str(sibling) if os.access(sibling,os.X_OK) else shutil.which("javac")
        if not compiler or not os.path.isfile(compiler) or not os.access(compiler,os.X_OK):
            raise CleanupError("Dirty ProjectWriting cleanup requires a JDK compiler; "
                               "install a compatible JDK and set PZ_WRITING_CLEANUP_JAVAC "
                               "to its executable javac (missing: "+str(compiler)+")")
        self.javac=str(Path(compiler).resolve(strict=True))
        result=subprocess.run([self.java,"-version"],stdin=subprocess.DEVNULL,
                              capture_output=True,timeout=20)
        match=re.search(rb'version\s+"([0-9]+)',result.stdout+result.stderr)
        if result.returncode or not match or int(match[1])<17:
            raise CleanupError("Cannot determine a supported cleanup JVM version (17 or newer required)")
        return str(int(match[1]))
    def __call__(self,stage,files,rows):
        # A JRE-only bootstrap with no dirty record must not require a compiler.
        # Resolve all tools before the first actual validation, before mutation.
        release=self.tools()
        source=Path(__file__).with_name("ValidateWritingRecords.java")
        if not source.is_file():raise CleanupError("PZ validation Java source is missing")
        with tempfile.TemporaryDirectory(prefix="pz-writing-validator-") as temp:
            root=Path(temp);manifest,count=validation_manifest(stage,files,rows,root/"records")
            if not count:raise CleanupError("No real item records selected for a dirty cleanup")
            classes=root/"classes";classes.mkdir()
            # Keep bytecode compatible with the selected runtime. An older
            # compiler fails before any mutation rather than skipping validation.
            self.run([self.javac,"--release",release,"-cp",self.jar,"-d",str(classes),str(source)],root)
            self.run([self.java,"-Xmx512m","-cp",self.jar+os.pathsep+str(classes),"ValidateWritingRecords",str(manifest)],root)
    def run(self,command,cwd):
        result=subprocess.run(command,cwd=cwd,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                              pass_fds=() if self.lock_fd is None else (self.lock_fd,),timeout=180)
        if result.returncode:
            # Java diagnostics can expose serialized player text; emit only status.
            raise CleanupError("Genuine PZ record validation failed (exit "+str(result.returncode)+")")


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--world-dir",required=True)
    parser.add_argument("--backup-dir",required=True)
    parser.add_argument("--dry-run",action="store_true")
    parser.add_argument("--jar")
    parser.add_argument("--java")
    parser.add_argument("--javac")
    parser.add_argument("--unit")
    parser.add_argument("--scripts-dir")
    parser.add_argument("--scan-cache", help="Private cache of unchanged files without Writing data")
    args=parser.parse_args(argv)
    try:
        validator=None
        if not args.dry_run:
            from writing_start_admission import validate_worker_admission
            lock_fd=validate_worker_admission(args.unit)
            if all((args.jar,args.java)):validator=JavaValidator(args.jar,args.java,args.javac,lock_fd)
        scripts=args.scripts_dir
        if scripts is None and args.jar:scripts=Path(args.jar).resolve().parent.parent/"media/scripts"
        print(json.dumps(cleanup(args.world_dir,args.backup_dir,args.dry_run,validator,scripts,args.scan_cache),sort_keys=True)); return 0
    except (CleanupError,OSError,sqlite3.Error,ValueError,TypeError,KeyError,ImportError,subprocess.SubprocessError) as error:
        print("ProjectWriting offline cleanup refused: "+str(error),file=sys.stderr); return 1

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
    from shared_memory_budget import check_process
    check_process()
    sys.exit(main())
