Run from a disposable Linux copy of the repository:
  tests/writing_text_only/run.sh --jdk-bin /path/to/a/compatible/jdk/bin

Optional --jar, --guard and --stdlib choose an alternate PZ JAR, Lua policy,
and matching stdlib.lua. The runner copies all inputs into a fresh Linux
mktemp directory; it never starts PZ or reads .env/world saves. Copies are
removed after both successful and failed runs. The Java fixture compiles
and runs the Lua fixture on the real Kahlua compiler/runtime in the PZ JAR.
No system Python dependency or Lua installation is needed.

API evidence checked against the installed PZ projectzomboid.jar:
- LuaManager$Exposer.exposeAll registers IsoGridSquare at bytecode offsets
  3299/3302 and IsoObject at 3397/3400 via setExposed.
- exposeAll iterates the exposed set and calls exposeLikeJavaRecursively
  at 7008. This path is not conditioned on GameClient.client.
- LuaJavaClassExposer.exposeLikeJava calls exposeMethods; exposeMethods
  uses Class.getMethods(), checks public modifiers, skips HiddenFromLua
  annotations, and exposes eligible instance methods.
- IsoObject.getContainerCount() is public, returning int.
- IsoGridSquare.getStaticMovingObjects() is public, returning ArrayList.
  The no-argument overload used by the guard therefore enters Lua exposure.
- Both methods are instance methods with no HiddenFromLua annotation
  (checked with javap -v), so neither is excluded by that filter.
- LuaManager.init invokes exposer.exposeAll for the server as well; the
  GameServer startup invokes LuaManager.init before Lua scripts are loaded.

Synchronization limitation:
Ground items with InventoryItem.getContainer()==null cannot be sent via
syncItemModData: ContainerID.set(null) creates Undefined container identity.
The guard still removes their persisted drawing/symbol data. A nearby
client may retain an old rendering until the item is resynchronized/reloaded.
The guard must not resend AddItemToMap blindly (duplicate-object risk).

Save ordering limitation:
Tick hooks precede ordinary NetworkPlayerManager player autosaves, but a
queued global save inside ServerMap.preupdate may happen before tick hooks.
ProjectWriting.Freehand=false prevents stock clients making strokes; this
server guard supplements native prevention and is not a packet firewall.

Real loader/checksum regression fixture (SandboxProbe.java):
The runner additionally invokes PZ LuaManager.LoadDirBase and
SandboxOptions.loadServerLuaFile in its disposable copy. It checks:
- A policy file in media/lua/server changes the game checksum.
- Adding a SandboxVars.lua suffix does not prevent that change: searchFolders
  lowercases relative paths before a case-sensitive contains check.
- Inline policy appended after the cache/Server/probe_SandboxVars.lua table
  registers all six callbacks while leaving the game checksum unchanged.
- PZ saveServerLuaFile removes the appended block when regenerating the file,
  while the registered tick callback remains identical and callable.
- The policy still removes drawings and preserves text after that rewrite.
The startup helper must re-inject its marked block before every server boot.
Default guard source is data/scripts/internal/PZManagerWritingTextOnly.lua,
kept with the manager scripts rather than runtime media autoload directories.
