import java.nio.file.*;
import java.util.List;
import zombie.ZomboidFileSystem;
import zombie.Lua.LuaManager;
import zombie.network.GameServer;
import zombie.network.NetChecksum;
import zombie.SandboxOptions;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.vm.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.converter.KahluaConverterManager;
import se.krka.kahlua.integration.LuaCaller;

/** Real PZ loader/checksummer probe. Run only inside run.sh's disposable copy. */
public class SandboxProbe {
    private static final Path SERVER_LUA = Path.of("media/lua/server");
    private static final List<String> POLICY_NAMES = List.of(
        "PZManagerWritingTextOnly.lua", "PZManagerWritingTextOnlySandboxVars.lua");

    private static String checksum(String policyName, String source) throws Exception {
        Files.createDirectories(SERVER_LUA);
        for (String name : POLICY_NAMES) Files.deleteIfExists(SERVER_LUA.resolve(name));
        Files.writeString(SERVER_LUA.resolve("baseline.lua"), "local baseline = true\n");
        if (policyName != null) Files.writeString(SERVER_LUA.resolve(policyName), source);
        ZomboidFileSystem.instance.init();
        LuaManager.checksumDone = false;
        NetChecksum.GroupOfFiles.initChecksum();
        NetChecksum.checksummer.reset();
        LuaManager.LoadDirBase("server", true);
        LuaManager.finishChecksum();
        return GameServer.checksum;
    }

    private static void execute(KahluaThread thread, KahluaTable env, String source) throws Exception {
        Object[] result = thread.pcall(LuaCompiler.loadstring(source, "sandbox-probe", env), new Object[0]);
        if (!Boolean.TRUE.equals(result[0])) throw new AssertionError(java.util.Arrays.toString(result));
    }

    public static void main(String[] args) throws Exception {
        String policy = Files.readString(Path.of(args[0]));
        Path cwd = Path.of("").toAbsolutePath();
        GameServer.server = true;
        String baseline = checksum(null, policy);
        String normal = checksum(POLICY_NAMES.get(0), policy);
        String suffix = checksum(POLICY_NAMES.get(1), policy);
        if (baseline.equals(normal)) throw new AssertionError("Autoload policy must change checksum");
        if (!normal.equals(suffix)) throw new AssertionError("SandboxVars suffix cannot bypass lowercased loader paths");
        checksum(null, policy); // Remove both media autoload names before sandbox load.
        ZomboidFileSystem.instance.setCacheDir(cwd.resolve("cache").toString());

        var platform = J2SEPlatform.getInstance();
        var env = platform.newEnvironment();
        var thread = new KahluaThread(platform, env);
        thread.debugOwnerThread = Thread.currentThread();
        LuaManager.platform = platform;
        LuaManager.env = env;
        LuaManager.thread = thread;
        LuaManager.caller = new LuaCaller(new KahluaConverterManager());
        execute(thread, env, """
            isServer = function() return true end
            Events = {}; registered = {}; regCount = 0
            local function event(name)
                return { Add = function(f) registered[name] = f; regCount = regCount + 1 end }
            end
            for _, name in ipairs({ 'OnTickEvenPaused', 'LoadGridsquare', 'OnObjectAdded',
                    'OnFillContainer', 'OnClientCommand', 'OnContainerUpdate' }) do
                Events[name] = event(name)
            end
            getOnlinePlayers = function() return { size = function() return 0 end } end
            """);
        Path config = cwd.resolve("cache/Server/probe_SandboxVars.lua");
        Files.createDirectories(config.getParent());
        Files.writeString(config, "SandboxVars = { VERSION = 5, Zombies = 3 }\n"
            + "-- PZMANAGER WRITING TEXT ONLY BEGIN\n" + policy
            + "\n-- PZMANAGER WRITING TEXT ONLY END\n");
        if (!SandboxOptions.instance.loadServerLuaFile("probe")) throw new AssertionError("Sandbox load failed");
        execute(thread, env, """
            assert(PZManagerWritingTextOnly == nil and regCount == 0)
            assert(registered.OnTickEvenPaused == nil)
            """);
        if (!SandboxOptions.instance.saveServerLuaFile("probe")) throw new AssertionError("Sandbox save failed");
        if (Files.readString(config).contains("PZMANAGER WRITING TEXT ONLY BEGIN"))
            throw new AssertionError("Expected PZ to regenerate the sandbox without the manager block");
        execute(thread, env, """
            assert(PZManagerWritingTextOnly == nil and regCount == 0)
            assert(registered.OnTickEvenPaused == nil)
            """);
        String after = checksum(null, policy);
        if (!baseline.equals(after)) throw new AssertionError("Sandbox policy changed checksum");
        System.out.println("PASS: real PZ sandbox loader; no continuous callbacks; checksum baseline="
            + baseline + " after=" + after + " autoload=" + normal + " suffix=" + suffix);
    }
}
