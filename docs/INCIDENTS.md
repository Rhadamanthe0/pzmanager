# Incident Log

Post-mortems worth keeping: each one corrects a belief that looked reasonable
at the time. They are here so the same wrong conclusion is not reached twice.

For the *standing* rules these incidents produced, see
[ADVANCED.md](ADVANCED.md) (memory and JVM) and
[HOST_ENVIRONMENT.md](HOST_ENVIRONMENT.md) (hardware).

## Contents

- [2026-07-19 — the predicted OS OOM-kill happened](#2026-07-19--the-predicted-os-oom-kill-happened)
- [The RAM budget was wrong twice, and the OOM proved it](#the-ram-budget-was-wrong-twice-and-the-oom-proved-it)
- [2026-09-01 — PZ Studio serialisation overflow](#2026-09-01--pz-studio-serialisation-overflow)
- [2026-09-02 — a stop that could not be executed](#2026-09-02--a-stop-that-could-not-be-executed)

## 2026-07-19 — the predicted OS OOM-kill happened

Kernel `global_oom` (`constraint=CONSTRAINT_NONE`) killed `ProjectZomboid6` pid 133115: `anon-rss 1.29 GiB + shmem-rss 7.93 GiB ≈ 9.2 GiB` resident, `oom_score_adj:200` (systemd's default for a user service — PZ is *always* the designated victim, whoever caused the pressure). The `.env` had already been set to `PZ_XMX_GB=8` earlier that evening but the **running JVM was still the old 9g** (the JSON is read only at JVM start, and the restart had been deferred to avoid kicking 29 players) — deferring the restart is what left the box exposed. systemd restarted the service at 22:34; the box then went down **uncleanly** at ~22:39 (`last` shows the prior session ending in `crash`) and came back at 22:41 now running `-Xmx8g` (confirmed in `vmArgs (json) 6`). **Lesson: after changing `PZ_XMX_GB` (either direction), schedule the restart — the change is inert until then.**

## The RAM budget was wrong twice, and the OOM proved it

(1) **ZGC's heap is shmem-backed, not anon** — `shmem-rss` ≈ `-Xmx` (7.9 GiB of 9g pre-touched), and `anon-rss` was only ~1.3 GiB. So the "~5.1 GiB native/shmem" figure was **double-counting the heap**: real PZ total resident ≈ `-Xmx` + ~1.3 GiB, i.e. **~9.2 GiB on 9g, ~8.8 GiB on 8g** — not 13.6. (2) The **"OS baseline ≈ 0.5 GiB" is far too low**: at the OOM, ~5.7 GiB was held by everything *except* PZ. Confirmed contributors beyond the documented Docker/Pi-hole: `fail2ban` (~50 MiB), `journald` (~75 MiB), the `pz-discord-bot` venv (~50 MiB), plus **an interactive Claude Code session on the same box (~600 MiB: two `claude` processes ~290+264 MiB and a `node` ~67 MiB)**. **Running an agent session on the server host measurably eats the OOM headroom** — treat it as a real consumer when diagnosing memory, and prefer not to hold a long session open while the server is near its heap ceiling.

## 2026-09-01 — PZ Studio serialisation overflow

A mod pushed a single Lua string past the **32 767-byte signed-short limit** in
`zombie.GameWindow$StringUTF.save(ByteBuffer,String)` (an `i2s` narrowing before
`putShort`, while the full payload is still written). That corrupted
`global_mod_data.bin` and crash-looped the boot with `invalid lua table type 83`.

Removing the mod did **not** fix the follow-on symptom (invisible players):
characters keep a `pzstudio:profession_N` reference in their serialised BLOB, so
dropping the mod removes the resolver while the reference remains, and
`Registry.getLocation()` returns null → NPE in `SurvivorDesc.save` →
`sendPlayerConnected` fails → clients never instantiate those players.

Full write-up, the recovered configuration and the recovery snippet:
[`versionning/pzstudio/README.md`](../versionning/pzstudio/README.md).

## 2026-09-02 — a stop that could not be executed

A `pzm server restart now` ended in `zomboid.service: Failed with result 'timeout'`
and a SIGKILL. The obvious reading — "the shutdown save took more than the 120 s
of `TimeoutStopSec`" — was wrong, and acting on it (raising the timeout) would
have changed nothing.

**What the evidence actually showed.** During the whole 120 s the game emitted
**zero log lines**, used **13 % CPU**, and had **no players**. A save that slow
would log and burn CPU. Cross-checking the console marker
(`command entered via server console`) settled it: the game acknowledged a command
on every *successful* stop, and **none at all** on the failed one. The `quit` was
never read.

It had been broken for a while. Between that session's boot and the failed stop,
the console acknowledged exactly **one** command — at 13:33 — while `pz-modcheck`
sends one every 5 minutes. Its own log had recorded the silence twice
(`aucune sortie capturée` at 13:38 and 13:43) and nobody was told. The write to
the FIFO *succeeds* in that state, because a pipe accepts data into its 64 KB
buffer whether or not anyone reads it — so the `quit` was buffered and ignored.

**Why the freeze detector did not help — the more useful finding.**
`pz-stallwatch` had detected it at 13:35 and dismissed it as a false positive.
It had been doing that constantly: **294 detections over 30 days, 292 dismissed**
with the identical message, each dismissal blinding it for 600 s. Two separate
defects:

- It counted connected clients by counting distinct `client="…"` label series in
  the Prometheus output. **A Prometheus series is never removed when a client
  disconnects** — 35 series for 29 connected players, measured. So on a server
  that empties out, the packet counter stops moving *legitimately* while the
  detector still believes players are present, and its "no players, cannot
  conclude" guard never fires again after the first connection. Fixed by reading
  the live `game{parameter="players"}` gauge instead.
- On a dismissal it **deleted the thread dump**. The one document that would have
  said what the main loop was blocked on was erased seconds after being written.
  Captures are now kept and aged with the other logs.

The verdict logic itself is not wrong — a main thread that is *not* runnable and
burns ~1 % CPU is what a world save looks like, and SIGKILLing on that would be
reckless. It just must not be silent about it.

**Still unexplained**: *why* the console reader stopped consuming the FIFO. The
evidence was deleted. The next occurrence will keep its dump.
