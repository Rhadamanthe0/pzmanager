Run tests/writing_text_only/run.sh --jdk-bin /path/to/compatible/jdk/bin.
Optional --jar, --guard and --stdlib choose alternate inputs. The runner copies
all inputs into a fresh Linux mktemp directory, sets a temporary user.home,
and removes the copies on success or failure. It never launches the server.

GuardLuaTest runs test_guard.lua on PZ's real Kahlua runtime. The legacy Lua
entry point is intentionally inert: repeated loads register zero callbacks.
There is no continuous drawing/symbol purge during the session.

SandboxProbe invokes actual PZ LoadDirBase/loadServerLuaFile/saveServerLuaFile:
- Any file in media/lua/server changes the checksum, even with SandboxVars.lua
  as a suffix (relative paths are lowercased before the case-sensitive check).
- A server sandbox configuration does not change that checksum.
- Even a legacy inline reference to the inert entry point registers no hooks.
- Sandbox rewriting does not create any cleanup callbacks.

Actual offline data cleanup and text preservation are covered separately by
Python/Java fixtures in tests/test_writing_restart_cleanup.py. Startup admission
is covered by tests/test_writing_start_admission.py with real flock/SCM_RIGHTS,
including termination of the pzm parent while the cleanup worker holds WORLD.
Native ProjectWriting.Freehand=false/VanillaMap=true remain configured.
