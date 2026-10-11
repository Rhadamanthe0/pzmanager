import java.nio.file.*;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.vm.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
public class GuardLuaTest {
    public static void main(String[] args) throws Exception {
        var platform = J2SEPlatform.getInstance();
        var env = platform.newEnvironment();
        var thread = new KahluaThread(platform, env);
        thread.debugOwnerThread = Thread.currentThread();
        String guard = Files.readString(Path.of(args[0]));
        String test = Files.readString(Path.of(args[1]));
        test = test.replace("dofile(\"PZManagerWritingTextOnly.lua\")", "guardChunk()");
        env.rawset("guardChunk", LuaCompiler.loadstring(guard, "PZManagerWritingTextOnly", env));
        Object[] out = thread.pcall(LuaCompiler.loadstring(test, "guard-tests", env), new Object[0]);
        if (!Boolean.TRUE.equals(out[0])) throw new AssertionError(java.util.Arrays.toString(out));
    }
}
