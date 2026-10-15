import java.lang.reflect.*;
import java.nio.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.CRC32;
import org.json.*;
import se.krka.kahlua.j2se.J2SEPlatform;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;
import zombie.iso.*;
import zombie.iso.worldgen.utils.SquareCoord;
import zombie.network.GameServer;

/** Read-only indexing of copied B42/249 terrain with the actual game readers.
 * Never saves a game object. Python splices the original column byte ranges.
 */
public final class IndexTerrainColumns {
    private static Object field(Object instance, Class<?> type, String name) throws Exception {
        for (Class<?> parent = type; parent != null; parent = parent.getSuperclass()) {
            try {
                Field f = parent.getDeclaredField(name);
                f.setAccessible(true);
                return f.get(instance);
            } catch (NoSuchFieldException missing) { /* anonymous register subclasses */ }
        }
        throw new NoSuchFieldException(type.getName() + "." + name);
    }

    /** Read the binary registries themselves; the readable Lua export can be stale. */
    private static JSONObject dictionarySnapshot(Path path) throws Exception {
        require(Files.size(path) <= 64L * 1024 * 1024, "Dictionary exceeds 64 MiB");
        ByteBuffer bytes = ByteBuffer.wrap(Files.readAllBytes(path));
        require(bytes.remaining() >= 4 && bytes.getInt(0) == 1, "Unsupported dictionary version");
        for (Class<?> type : List.of(zombie.world.StringDictionary.class, zombie.world.ScriptsDictionary.class)) {
            Method reset = type.getDeclaredMethod("reset");
            reset.setAccessible(true);
            reset.invoke(null);
        }
        Class<?> type = Class.forName("zombie.world.DictionaryData");
        Constructor<?> ctor = type.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object data = ctor.newInstance();
        Method load = type.getDeclaredMethod("loadFromByteBuffer", ByteBuffer.class);
        load.setAccessible(true);
        load.invoke(data, bytes);
        require(!bytes.hasRemaining(), "Unconsumed dictionary bytes");
        JSONObject result = new JSONObject();
        int removed = 0;
        for (String name : List.of("itemIdToInfoMap", "entityIdToInfoMap", "objectIdToNameMap", "spriteIdToNameMap")) {
            JSONObject entries = new JSONObject();
            Map<?, ?> map = (Map<?, ?>) field(data, type, name);
            for (var entry : map.entrySet()) {
                Object value = entry.getValue();
                if (value instanceof zombie.world.DictionaryInfo<?> info) {
                    entries.put(entry.getKey().toString(), info.getFullType());
                    if (info.isRemoved() || info.isObsolete()) removed++;
                } else entries.put(entry.getKey().toString(), value);
            }
            result.put(name, entries);
        }
        for (Class<?> owner : List.of(zombie.world.StringDictionary.class, zombie.world.ScriptsDictionary.class)) {
            for (Object register : (List<?>) field(null, owner, "registers")) {
                boolean script = owner == zombie.world.ScriptsDictionary.class;
                JSONObject entries = new JSONObject();
                Map<?, ?> map = (Map<?, ?>) field(register, register.getClass(), script ? "idMap" : "idToStringMap");
                for (var entry : map.entrySet()) {
                    Object value = entry.getValue();
                    if (script) {
                        var info = (zombie.world.DictionaryScriptInfo<?>) value;
                        entries.put(entry.getKey().toString(), new JSONArray().put(info.getName()).put(Long.toString(info.getVersion())));
                    } else entries.put(entry.getKey().toString(), ((zombie.world.DictionaryStringInfo) value).getString());
                }
                result.put(owner.getSimpleName() + ":" + field(register, register.getClass(), "name"), entries);
            }
        }
        return new JSONObject().put("registries", result).put("removed_or_obsolete", removed);
    }

    private static void require(boolean ok, String reason) {
        if (!ok) throw new IllegalArgumentException(reason);
    }

    private static void initialize(Path dictionary, JSONObject request) throws Exception {
        zombie.core.random.RandStandard.INSTANCE.init();
        zombie.core.random.RandLua.INSTANCE.init();
        GameServer.server = true;
        LuaManager.platform = J2SEPlatform.getInstance();
        LuaManager.env = LuaManager.platform.newTable();
        ZomboidFileSystem.instance.setCacheDir(Path.of("cache").toAbsolutePath().toString());
        ZomboidFileSystem.instance.init();
        LuaManager.init();
        // Use the installed script definitions with the saved registry IDs.
        // An unresolved world item returns early in PZ's loader and can leave
        // its entity/fluid bytes unread, desynchronizing the remaining terrain.
        List<String> folders = new ArrayList<>();
        Method discover = ZomboidFileSystem.class.getDeclaredMethod("getAllModFoldersAux", String.class, List.class);
        discover.setAccessible(true);
        for (Object root : request.optJSONArray("mod_roots", new JSONArray())) discover.invoke(ZomboidFileSystem.instance, (String) root, folders);
        Field modFolders = ZomboidFileSystem.class.getDeclaredField("modFolders");
        modFolders.setAccessible(true); modFolders.set(ZomboidFileSystem.instance, folders);
        List<String> mods = new ArrayList<>();
        for (Object mod : request.optJSONArray("mods", new JSONArray())) mods.add((String) mod);
        for (String mod : mods)
            require(zombie.gameStates.ChooseGameInfo.getAvailableModDetails(mod) != null,
                    "Installed mod definition unavailable: " + mod);
        ZomboidFileSystem.instance.loadMods(mods);
        zombie.scripting.ScriptManager.instance.Load();
        Class<?> type = Class.forName("zombie.world.DictionaryData");
        Constructor<?> ctor = type.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object data = ctor.newInstance();
        Method load = type.getDeclaredMethod("loadFromByteBuffer", ByteBuffer.class);
        load.setAccessible(true);
        load.invoke(data, ByteBuffer.wrap(Files.readAllBytes(dictionary)));
        Field field = zombie.world.WorldDictionary.class.getDeclaredField("data");
        field.setAccessible(true);
        field.set(null, data);
        Field itemScript = zombie.world.ItemInfo.class.getDeclaredField("scriptItem");
        itemScript.setAccessible(true);
        Field entityScript = zombie.world.DictionaryInfo.class.getDeclaredField("entityScript");
        entityScript.setAccessible(true);
        Field loaded = zombie.world.DictionaryInfo.class.getDeclaredField("isLoaded");
        loaded.setAccessible(true);
        for (Object info : ((Map<?, ?>) field(data, type, "itemIdToInfoMap")).values()) {
            var item = (zombie.world.ItemInfo) info;
            var script = zombie.scripting.ScriptManager.instance.getSpecificItem(item.getFullType());
            itemScript.set(item, script);
            entityScript.set(item, script);
            loaded.setBoolean(item, script != null);
            if (script != null) script.setRegistry_id(item.getRegistryID());
        }
        for (Object info : ((Map<?, ?>) field(data, type, "entityIdToInfoMap")).values()) {
            var entity = (zombie.world.EntityInfo) info;
            var script = zombie.scripting.ScriptManager.instance.getSpecificEntity(entity.getFullType());
            entityScript.set(entity, script);
            loaded.setBoolean(entity, script != null);
            if (script != null) script.setRegistry_id(entity.getRegistryID());
        }
        Method bind = zombie.world.ScriptsDictionary.class.getDeclaredMethod("parseRegisters");
        bind.setAccessible(true);
        bind.invoke(null);
        new zombie.erosion.season.ErosionIceQueen(zombie.iso.sprite.IsoSpriteManager.instance);
        zombie.erosion.ErosionRegions.init();
    }

    private static IsoChunk chunk(int x, int y) {
        IsoCell cell = new IsoCell(1, 1);
        IsoWorld.instance.currentCell = cell;
        IsoChunk chunk = new IsoChunk(cell);
        chunk.wx = x;
        chunk.wy = y;
        return chunk;
    }

    private static JSONObject index(Path path, int cx, int cy, boolean trace) throws Exception {
        require(Files.size(path) <= 64L * 1024 * 1024, "Terrain file exceeds 64 MiB");
        byte[] bytes = Files.readAllBytes(path);
        ByteBuffer b = ByteBuffer.wrap(bytes);
        require(b.remaining() >= 17 && b.get() == 0 && b.getInt() == 249, "Expected non-debug B42/249 terrain");
        require(b.getInt() == bytes.length, "Terrain length mismatch");
        long checksum = b.getLong();
        CRC32 crc = new CRC32();
        crc.update(bytes, 17, bytes.length - 17);
        require(checksum == crc.getValue(), "Terrain checksum mismatch");

        // Validate the complete record, including the chunk-wide suffix, with PZ.
        IsoChunk whole = chunk(cx, cy);
        Method load = IsoChunk.class.getDeclaredMethod("LoadFromDiskOrBufferInternal", ByteBuffer.class);
        load.setAccessible(true);
        ByteBuffer full = ByteBuffer.wrap(bytes);
        if(trace) NativeItemTrace.begin(full);
        try { load.invoke(whole, full); }
        catch (Exception error) { throw new IllegalArgumentException("Terrain " + path + " at byte " + full.position() + "/" + bytes.length, error); }
        require(full.position() == bytes.length, "Unparsed terrain bytes");
        JSONArray items=trace?NativeItemTrace.finish():new JSONArray();

        // Version-249 prefix, followed by 64 X-major/Y-minor columns. Each
        // column has a 64-bit floor-presence mask and native square records.
        b.get(); // blendingDoneFull
        int blending = Byte.toUnsignedInt(b.get());
        boolean partial = b.get() != 0;
        if ((blending & 15) != 15 && partial) b.position(b.position() + 4);
        b.get(); // attachmentsDoneFull
        b.get(); // attachmentsState
        int attachments = b.getShort();
        require(attachments >= 0, "Negative attachment count");
        for (int i = 0; i < attachments; i++) SquareCoord.load(b);
        int levelOffset = b.position();
        int max = b.getInt(), min = b.getInt();
        require(min >= -32 && max <= 31 && min <= max, "Unsupported floor range");
        int blood = b.getInt();
        require(blood >= 0 && blood <= 1000, "Invalid blood record count");
        for (int i = 0; i < blood; i++) new IsoFloorBloodSplat().load(b, 249);
        IsoChunk current = chunk(cx, cy);
        current.setMinMaxLevel(min, max);
        long allowed = 0;
        for (int z = min; z <= max; z++) allowed |= 1L << (z + 32);
        JSONArray columns = new JSONArray();
        for (int x = 0; x < 8; x++) {
            for (int y = 0; y < 8; y++) {
                int start = b.position();
                long flags = b.getLong();
                require((flags & ~allowed) == 0, "Floor mask outside saved range");
                for (int z = min; z <= max; z++) {
                    if ((flags & (1L << (z + 32))) == 0) continue;
                    IsoGridSquare square = IsoGridSquare.getNew(IsoWorld.instance.currentCell, null,
                            cx * 8 + x, cy * 8 + y, z);
                    square.chunk = current;
                    current.setSquare(x, y, z, square);
                    square.load(b, 249, false);
                }
                columns.put(new JSONArray().put(start).put(b.position()).put(Long.toUnsignedString(flags)));
            }
        }
        return new JSONObject().put("sha256", HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)))
                .put("level_offset", levelOffset).put("min_level", min).put("max_level", max)
                .put("columns", columns).put("items",items);
    }

    private static JSONObject storage(JSONObject entry) throws Exception {
        Path path=Path.of(entry.getString("file"));
        require(Files.size(path)<=64L*1024*1024,"Storage exceeds 64 MiB");
        byte[] bytes=Files.readAllBytes(path);ByteBuffer input=ByteBuffer.wrap(bytes);
        require(entry.getInt("version")==249,"Unsupported storage version");
        IsoWorld.instance.currentCell=new IsoCell(1,1);
        // Native characters query ServerMap while being constructed. A private,
        // empty meta grid supplies the same absent-square result as unloaded
        // terrain, without starting server threads or reading another world.
        IsoMetaGrid meta=IsoWorld.instance.metaGrid;
        meta.minX=0; meta.maxX=0; meta.minY=0; meta.maxY=0;
        // ServerMap.init also starts unrelated stash initialization, requiring
        // Lua gameplay state. Only its empty grid lookup state is needed here.
        var serverMap=zombie.network.ServerMap.instance;
        for(String name:List.of("grid","width","height","cellMap")) {
            Field f=zombie.network.ServerMap.class.getDeclaredField(name);f.setAccessible(true);
            if(name.equals("grid")) f.set(serverMap,meta);
            else if(name.equals("cellMap")) f.set(serverMap,Array.newInstance(f.getType().getComponentType(),16));
            else f.setInt(serverMap,4);
        }
        NativeItemTrace.begin(input);
        if(entry.getString("kind").equals("player")) {
            // A neutral constructor visual avoids random character creation
            // (Lua's common hair palette is not loaded by this offline reader).
            // The saved visual is subsequently consumed by the real load method.
            zombie.core.skinnedmodel.population.HairStyles.init();
            zombie.core.skinnedmodel.population.BeardStyles.init();
            var descriptor=new zombie.characters.SurvivorDesc();
            var visual=descriptor.getHumanVisual();
            visual.setHairColor(zombie.core.ImmutableColor.white);
            visual.setBeardColor(zombie.core.ImmutableColor.white);
            visual.setNaturalHairColor(zombie.core.ImmutableColor.white);
            visual.setNaturalBeardColor(zombie.core.ImmutableColor.white);
            visual.setSkinColor(zombie.core.ImmutableColor.white);
            visual.setHairModel("Bald");visual.setBeardModel("");visual.setSkinTextureName("offline-constructor");
            var player=new zombie.characters.IsoPlayer(IsoWorld.instance.currentCell,descriptor,0,0,0);
            player.load(input,249,false);
        } else if(entry.getString("kind").equals("reanimated")) {
            require(input.remaining()>=8 && input.getInt(0)==249 && input.getInt(4)>=0 && input.getInt(4)<=100000,"Invalid reanimated header");
            Method load=zombie.ReanimatedPlayers.class.getDeclaredMethod("loadReanimatedPlayers",ByteBuffer.class);
            load.setAccessible(true);load.invoke(zombie.ReanimatedPlayers.instance,input);
        } else throw new IllegalArgumentException("Unsupported storage kind");
        require(!input.hasRemaining(),"Unparsed storage bytes");
        return new JSONObject().put("sha256",HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)))
            .put("items",NativeItemTrace.finish());
    }

    public static void main(String[] args) throws Exception {
        require(args.length == 2, "Usage: IndexTerrainColumns INPUT_JSON OUTPUT_JSON");
        JSONObject request = new JSONObject(Files.readString(Path.of(args[0])));
        if (request.has("dictionaries")) {
            JSONArray results = new JSONArray();
            for (Object path : request.getJSONArray("dictionaries"))
                results.put(dictionarySnapshot(Path.of((String) path)));
            Files.writeString(Path.of(args[1]), new JSONObject().put("dictionaries", results).toString());
            return;
        }
        initialize(Path.of(request.getString("dictionary")), request);
        if(request.has("storage")) {
            JSONArray results=new JSONArray();
            for(Object entry:request.getJSONArray("storage")) results.put(storage((JSONObject)entry));
            Files.writeString(Path.of(args[1]),new JSONObject().put("storage",results).toString());return;
        }
        JSONArray chunks = request.getJSONArray("chunks"), results = new JSONArray();
        for (int i = 0; i < chunks.length(); i++) {
            JSONObject entry = chunks.getJSONObject(i);
            results.put(index(Path.of(entry.getString("file")), entry.getInt("x"), entry.getInt("y"),request.optBoolean("trace_items")));
        }
        Files.writeString(Path.of(args[1]), new JSONObject().put("chunks", results).toString());
    }
}
