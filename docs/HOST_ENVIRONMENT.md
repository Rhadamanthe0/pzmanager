# Host Environment

Facts about **the machine this server runs on**, as opposed to the pzmanager
software. Nothing here is configured by this repo — it is recorded because it
has repeatedly been mistaken for a pzmanager bug.

> **Ownership.** The network configuration belongs to the separate
> [`infra-deploy`](#networking) repo. pzmanager deliberately configures **no**
> network: two repos laying down the same profile would be two conflicting
> sources of truth. A `configure_network()` was proposed here and rejected.
> Do not re-add it.

## Contents

- [Memory budget](#memory-budget)
- [Hard freezes and the watchdog](#hard-freezes-and-the-watchdog)
- [Networking](#networking)
- [Wake-on-LAN](#wake-on-lan)

## Memory budget

The generic rule — keep `-Xmx` at about **half of physical RAM** — is the default
in `configureJvm.sh` and is what [ADVANCED.md](ADVANCED.md#ram--jvm-configuration)
documents. **This box deliberately breaks it**, so use the *slack* as your guide
instead.

- **RAM**: 32 GB (`MemTotal` 32130864 kB ≈ **30.6 GiB usable**), upgraded
  2026-08-19 from 15 GiB.
- **`PZ_XMX_GB=20`** — above half, on purpose.

Resident budget at that setting:

| Component | Size |
|---|---|
| Java heap (shmem-backed, pre-touched by `AlwaysPreTouch`) | 20 GiB |
| PZ native / anon | ~1.3 GiB |
| Everything else on the box | ~5.7 GiB |
| **Total** | **~27 GiB of 30.6 → ~3.6 GiB slack** |

That is 2.7× the slack the old 8g-on-15 GiB configuration had.

> **The operating rule: watch the slack, not the half-RAM ratio.** If an abrupt
> SIGKILL, a kernel OOM or an unexplained shutdown ever appears, **lower
> `PZ_XMX_GB` until slack is back above ~3 GiB.**

Two things that are *not* levers here:

- `HEAP_RESTART_PERCENT` (90 vs 95) changes only the **Java-heap** OOM trigger. It
  has no effect on OS-OOM-kill exposure.
- A bigger heap lengthens the `HeapDumpOnOutOfMemoryError` pause — the dump is
  roughly `-Xmx` GB written to disk.

**History**: 8 → 9 GB on 2026-07-17; **reverted 9 → 8 on 2026-07-19** after the
OOM-kill (0.3 GiB slack was far too tight); 8 → 20 on 2026-08-19 with the RAM
upgrade. The two figures that turned out to be wrong in the original budget, and
the kill that proved it, are in
[INCIDENTS.md](INCIDENTS.md#the-ram-budget-was-wrong-twice-and-the-oom-proved-it).

> ⚠️ **Changing `PZ_XMX_GB` is inert until the server restarts** — the JSON is read
> only at JVM start. Deferring that restart is exactly what left the box exposed on
> 2026-07-19. Schedule it.

The ~5.7 GiB of "everything else" includes Docker + Pi-hole (Pi-hole runs *in*
Docker, alongside a `rhada-docker.service` compose stack — **leave Docker alone**),
`fail2ban` (~50 MiB), `journald` (~75 MiB) and the Discord bot venv (~50 MiB).
An interactive Claude Code session on this host costs **~600 MiB** and is a real
consumer when diagnosing memory — prefer not to hold one open while the server is
near its heap ceiling.

## Hard freezes and the watchdog

The mini-PC (AMD) intermittently freezes hard — the power LED stays on but SSH *and* the server are both dead until a manual power-cycle (12× between 2026-07-17 and 07-23, often ~05:05–05:25, i.e. just after the nightly maintenance reboot, but not only). This is **hardware / kernel-lockup, NOT software** — PZManager can neither cause nor fix it: the journal ends mid-line with **zero trace** (no `oom-kill`, no panic, no thermal/MCE; `journalctl -b <crashed-boot-id>` just stops). Confirm via `last -x reboot | grep crash` and by reading the tail of the crashed boot. **Mitigation enabled 2026-07-23: the hardware watchdog** — `sp5100_tco` (`/dev/watchdog`) was present but unused; set `RuntimeWatchdogSec=30` + `RebootWatchdogSec=10min` in `/etc/systemd/system.conf` (+ `systemctl daemon-reexec`). Since the box stays **powered** while frozen, the watchdog hard-resets it in ~30 s instead of leaving it down for hours (won't help a true power/PSU cut). Root cause of the freeze itself (PSU/thermal/kernel) is still open — a temp-logging + PSU/UPS check is the next step.

## Networking

Since 2026-08-27 `/etc/network/interfaces` describes only `lo`; `enp1s0` (static `192.168.1.5/24` via `192.168.1.1`, DNS `1.1.1.1`) and `macvlan-shim` are both NM keyfile profiles, alongside `docker0`, the bridges and `wg0`. **The owner is the `infra-deploy` repo** (`/root/infra-deploy`, `system/nm/` + `system/99-disable-ipv6.conf`, deployed by its `install.sh` from `/home/rhada/.env`). PZManager deliberately configures **no** network — a `configure_network()` was proposed here and rejected, because two repos laying down the same `static-enp1s0` profile would be two conflicting sources of truth. Don't re-add it. Four things worth knowing before touching any of it:

### Four things to know before touching any of it

- **The ifupdown NM plugin does not unload on reload.** `plugins=` is read only at NM **startup**. While it is loaded it marks the interface unmanaged (reason 76) and no profile can apply — even after removing its stanza and getting a successful `nmcli device set <iface> managed yes`. It takes `systemctl restart NetworkManager`, never `reload`. This is now settled by `/etc/NetworkManager/conf.d/10-manage-all.conf` (`plugins=keyfile`).
- **NM owns `/etc/resolv.conf` now, and empties it if the active profile has no `dns=`.** Under ifupdown the `dns-nameservers` directive was inert (`resolvconf` is not installed), so this failure mode did not exist before. The old value pointed at `192.168.1.3`, which **answers nothing** — never reinstate it. Never point host DNS at `192.168.1.2` (Pi-hole) either: that container runs *on this host*, so a container restart would break the box's own resolution.
- **`macvlan-shim` carries a MASQUERADE rule that NM cannot express.** The profile holds the address (`192.168.1.250/32`) and the route to Pi-hole (`192.168.1.2/32`); the NAT for WireGuard clients (`192.168.2.0/24`) is posed by `/etc/NetworkManager/dispatcher.d/90-macvlan-shim-masquerade`. NM silently ignores a dispatcher script that is not `root:root` and non-world-writable.
- **IPv6 is disabled host-wide** (`ipv6.method=disabled` on both profiles + `net.ipv6.conf.{all,default}.disable_ipv6=1`), with `lo` explicitly re-enabled so `::1` survives. Docker containers have their own netns and are unaffected. PZ already runs `-Djava.net.preferIPv4Stack=true`, so nothing here changes for the game server.

## Wake-on-LAN

It is carried by the NM profile (`wake-on-lan=64`, magic packet only) — **not** by a `post-up ethtool` line any more; set it in the `infra-deploy` template, never in both places. Verify with `ethtool enp1s0 | grep -i 'Wake-on:'` → must show `g`. Arming WoL flips `/sys/bus/pci/devices/0000:01:00.0/power/wakeup` to `enabled` (the r8169 driver does it), so that file is **no longer evidence the NIC can't wake the box**. The mask is pinned explicitly because the driver writes it to the controller at power-down, i.e. **after** the firmware, so it overwrites any broad mask the BIOS armed — a live suspect for the still-open **spontaneous power-on ~1 min after a clean `shutdown -h now`**, since Pi-hole makes this box receive LAN traffic constantly. The other suspect is the watchdog (`sp5100_tco`, `RuntimeWatchdogSec=30`); the delay fits both. Test order: shut down and watch (physical presence); if it still wakes, retest with the Ethernet cable unplugged to rule out a magic packet; then try `RuntimeWatchdogSec=0` — **and put it back to 30**, it is the only protection against the hard freezes. Do **not** suggest the BIOS ErP setting: it kills the LED and fans but also the WoL, which the admin wants to keep. The two are mutually exclusive by construction.
