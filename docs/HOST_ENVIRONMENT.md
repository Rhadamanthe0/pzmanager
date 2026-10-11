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
- [Backup CPU isolation](#backup-cpu-isolation)
- [Hard freezes and the watchdog](#hard-freezes-and-the-watchdog)
- [Networking](#networking)
- [Wake-on-LAN](#wake-on-lan)

## Backup CPU isolation

This Ryzen 7 8745HS has 8 physical cores and 16 logical CPUs. `lscpu -e`
and `cpu*/topology/thread_siblings_list` identify CPUs **4 and 12** as the
two SMT threads of physical core 4. Both are reserved for the hourly backup;
the game is restricted to **0–3 and 8–11**, the other four physical cores allocated to this account.
The system-wide `user-1005.slice` now permits only 0–4 and 8–12 (five physical cores). The previous reservation 7/15 was outside that parent mask and ineffective; core 4 is reserved within the actual allocation. Reserving only CPU 4 would still let the game compete with the backup on CPU 12.

These are **machine-specific**, persistent user-unit overrides, applied with:

```bash
systemctl --user set-property zomboid.service 'AllowedCPUs=0-3 8-11'
systemctl --user set-property pz-backup.service 'AllowedCPUs=4 12'
systemctl --user set-property pz-backup.service CPUQuota=200%
# In this host's .env, for live-game scopes including manual backups:
export BACKUP_CPU_LIST="4,12"
```

systemd stores them under `~/.config/systemd/user.control/<unit>.d/` and
enables the delegated cpuset controller. The kernel applies the masks to
**all existing and future threads** in each service, without restarting PZ.
Check `EffectiveCPUs` while the services are running, the cgroups'
`cpuset.cpus.effective`, and `/proc/<game-pid>/task/*/status` rather than
assuming a successful `set-property` proves effective isolation.

The backup's aggregate CPU budget is specified in
[WHAT_IS_INSTALLED](WHAT_IS_INSTALLED.md#pz-backuptimer---hourly-backup).
The first isolated run was initially allowed a full CPU; the limit was reduced
while observing shared-disk waits and slower game-loop intervals, to temper the
metadata burst. These observations alone do not identify which host workload
caused the waits.
On 2026-10-11 the live-game quota was raised to 200% while retaining both
SMT threads of the separate backup core. The quota now remains at 200%
in every state; the CPU mask is relaxed within the account's allocation
only when the JVM is proven absent.
The CPU masks do not isolate the shared NVMe, memory bandwidth, or unrelated
host workloads. The live-game backup scope reads `BACKUP_CPU_LIST` for both
manual and hourly runs. When the JVM is proven absent, its scope uses all
available CPUs while retaining the same 200% quota.
Do not copy these CPU numbers to another machine without checking its topology.
To remove the separation, set each unit's `AllowedCPUs` and the host's
`BACKUP_CPU_LIST` to empty values. If the reserved CPUs become inaccessible,
the script refuses the live-game copy rather than silently sharing game CPUs.

## Memory budget

The generic rule — keep `-Xmx` at about **half of physical RAM** — is the default
in `configureJvm.sh` and is what [ADVANCED.md](ADVANCED.md#ram--jvm-configuration)
documents. **This box deliberately breaks it**, so use the *slack* as your guide
instead.

- **RAM**: 32 GB (`MemTotal` 32130864 kB ≈ **30.6 GiB usable**), upgraded
  2026-08-19 from 15 GiB.
- **Target profile: `PZ_XMX_GB=16`, `MemoryMax=20G`.** The 4 GiB difference
  covers all service charges outside the heap, including native memory, code,
  stacks, descendants, cache and kernel accounting. The preventive monitor
  requests a restart at 18 GiB resident process memory; it cannot guarantee a
  clean save during a rapid increase.
- The historical override **20** from 2026-08-19 is incompatible with the
  20 GiB whole-service cap. It must be explicitly migrated while stopped,
  rather than silently clamped or applied to the live JVM. See the
  [migration plan](ADVANCED.md#existing-installation-migration-to-the-20-gib-budget).

| Target component | Budget |
|---|---|
| Java heap maximum | 16 GiB |
| All other charges in the PZ cgroup | 4 GiB headroom |
| Entire PZ service hard cap | 20 GiB |
| Physical RAM remaining for the host and other services | about 10.6 GiB |

These are limits and planning margins, not observed resident use. The outside
heap headroom is not a separate enforced sub-limit. Lowering Xmx can increase
GC work and require earlier restarts; it does not fix serialization of a large
or problematic book.

Two things that are *not* levers here:

- `HEAP_RESTART_PERCENT` (90 vs 95) changes only the **Java-heap** OOM trigger.
  The separate 18 GiB total service trigger and 20 GiB cgroup cap protect the
  service budget; they do not guarantee protection from host-wide OOM pressure.
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
