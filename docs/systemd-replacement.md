# Replacing systemd, component by component

systemd is not one thing. It is roughly thirty programs behind one name, and
they are not equally hard to replace. Treating it as a single decision — "we
use systemd" or "we don't" — is what leads distributions to either ship the
whole thing or ship something that doesn't work with a modern desktop.

NexisOS takes each component separately. The rule is:

1. If NexisOS's declarative model already covers the job, replace it natively.
   Half of systemd's surface is imperative reimplementations of things a
   declarative system gets for free.
2. If a maintained, API-compatible alternative exists, use it.
3. If neither, ship the systemd component **as a standalone build** and record
   it as debt with a named exit condition.

Rule 3 is not a defeat. `systemd-boot` is an EFI application that never runs
after the kernel starts; using it costs nothing architecturally. `systemd-udevd`
is a different matter. Being precise about which is which is the entire point of
this document.

---

## Summary

| Component | Job | NexisOS approach | Status |
| --- | --- | --- | --- |
| PID 1 / service manager | supervision, ordering | `nexis-init` | build |
| `systemd-sysusers` | create users/groups | declarative `users` config | native |
| `systemd-tmpfiles` | create runtime dirs | declarative, applied by `nexis-init` | native |
| `systemd-sysctl` | apply sysctls | declarative config | native |
| `systemd-modules-load` | load kernel modules | declarative config | native |
| `systemd-binfmt` | binfmt_misc | declarative config | native |
| `systemd-journald` | logging | `nexis-log` + `/dev/log` syslog socket | build |
| `systemd-timesyncd` | NTP | **chrony** | adopt |
| `systemd-resolved` | DNS | **unbound** or plain `resolv.conf` | adopt |
| `systemd-networkd` | networking | **NetworkManager**, or `iwd` + `dhcpcd` | adopt |
| `systemd-cryptsetup` | LUKS unlock | **cryptsetup** from the initramfs | adopt |
| `systemd-nspawn` | containers | **bubblewrap**, or native namespaces | adopt |
| `systemd-oomd` | OOM policy | PSI-based, native (`nexis-init` owns cgroups) | native |
| `systemd-boot` | EFI boot menu | **systemd-boot** (EFI app only) | adopt |
| `systemd-logind` | seats, sessions, device access | **seatd** (installer), **elogind** (desktop) | adopt, then native |
| logind sleep/inhibitor API | suspend coordination | native (`sleep.nim`) | build |
| `systemd-udevd` / `libudev` | device management | **the hard one — see below** | unresolved |
| `hostnamed` / `localed` / `timedated` | D-Bus settings APIs | small native services | build |
| `dbus` | IPC (not systemd, but coupled) | **dbus-daemon** reference implementation | adopt |
| `pam_systemd` | session registration | `pam_elogind`, then native | adopt, then native |

---

## The components that are free

These exist because systemd needs an imperative mechanism to reach a state that
a declarative system simply *declares*. NexisOS already has the state
description; it needs an applier, not a subsystem.

`sysusers`, `tmpfiles`, `sysctl`, `modules-load`, `binfmt` are all of this
shape. A generation already knows its users, its required runtime directories,
its sysctls and its modules, because they are in the configuration that built
it. `nexis-init` applies them during activation. The systemd versions parse
drop-in directories at runtime to discover the same facts; we know them at
generation-build time.

This is worth stating clearly because it means **a large fraction of systemd's
component count is not a replacement problem for NexisOS at all**. It is a
problem systemd has because it sits on top of imperatively-managed
distributions.

`oomd` belongs in this group for a different reason: `nexis-init` already owns
the cgroup hierarchy and already reads PSI pressure for supervision, so the
policy is a hundred lines on top of state we hold anyway.

## The components with clean adoptions

`chrony` for NTP, `unbound` for DNS, `cryptsetup` for LUKS, `bubblewrap` for
containers. All are mature, none has any systemd coupling, and each does its job
better than the systemd component it replaces. There is no interesting decision
here.

Networking: NetworkManager runs without systemd and is what a desktop profile
should use, because that is what the Plasma applet talks to. A minimal server
profile can use `iwd` + `dhcpcd` instead and skip the dependency entirely.

`dbus`: the reference `dbus-daemon` works standalone. `dbus-broker` is faster
but is built against `sd-bus` and expects systemd socket activation, so it is a
poor fit until `nexis-init`'s socket activation compatibility is proven. Start
with `dbus-daemon`; revisit.

## systemd-boot is not a systemd dependency

Worth calling out because it looks like one. `systemd-boot` is an EFI
application. It runs before the kernel and is gone by the time PID 1 exists. It
does not link systemd libraries at runtime, does not require systemd on the
installed system, and is a single small binary that reads a plain-text config.

NexisOS needs a boot menu specifically because generations require *selecting
one at boot* for rollback. Writing a custom EFI menu is a real project with real
Secure Boot signing consequences and buys nothing. Use `systemd-boot`, with
Unified Kernel Images per generation.

The alternative worth knowing about: with UKIs you can boot the EFI stub
directly with no bootloader at all — but then generation selection has to happen
through EFI boot variables, which is fragile on real firmware. Not worth it.

---

## logind: seatd now, native later

The job is arbitrating access to input and DRM devices between sessions, so an
unprivileged compositor can open `/dev/dri/card0` without being root.

**For the installer**, this is already solved cleanly. `cage` is wlroots-based,
wlroots uses `libseat`, and `libseat` talks to **`seatd`** — a small daemon
built for exactly this and with no systemd relationship. The installer
environment needs `seatd` and nothing more.

**For a Plasma desktop**, it is harder. Plasma, PAM session registration, and
several parts of the Qt/KDE stack speak the `org.freedesktop.login1` D-Bus
interface directly, not `libseat`. **`elogind`** is systemd's logind extracted to
run standalone, and it is the pragmatic answer.

**The native exit.** `nexis-init` will already track sessions, own the cgroup
hierarchy, and apply per-service device access policy. The logind D-Bus surface
that desktops actually use is a modest subset — session/seat enumeration,
`TakeDevice`/`ReleaseDevice`, idle hints, inhibitor locks, power actions.
Implementing that subset inside `nexis-init` is a bounded project and removes
the last general-purpose systemd daemon from the desktop. It is the right
long-term target, and it is *not* a prerequisite for a working system.

---

## udev: the genuinely unresolved one

This is the component that decides how systemd-free NexisOS can actually be, and
it deserves to be stated without optimism.

The problem is not the daemon. The problem is `libudev`. Mesa, libinput,
PipeWire, NetworkManager, Plasma, and most of the Wayland stack link it directly
for device enumeration and hotplug. And `libudev`'s interface is tightly bound to
the daemon's behaviour and its database, so a "device manager" that populates
`/dev` correctly is not sufficient — consumers need the library semantics too.

**eudev is not the answer any more.** It was the standard alternative for years.
<cite index="22-1">Gentoo retired it, and the retirement notice points users back at systemd's udev — the alternatives are either unmaintained or aimed at very minimal setups.</cite> <cite index="18-1">By the time it was abandoned it had fallen far enough behind that catching up would take substantial work.</cite> Adopting it would mean adopting its maintenance.

**`libudev-zero`** is a daemonless drop-in `libudev` implementation. <cite index="21-1">It exists precisely because udev's library interface is tied to the udev daemon and creates lock-in.</cite> It works well for the wlroots/X class of consumer — enough for cage, libinput, and Mesa. Its own documentation is candid that it is not a complete substitute, and it does not implement the hwdb, which libinput uses for input device quirks.

### The decision

Split by environment, because the two have very different requirements:

**Installer environment: `libudev-zero` + a native uevent manager.**
The installer needs DRM, input, block devices and network interfaces. That is
`libudev-zero`'s sweet spot, and it keeps the ISO small. The uevent side — read
netlink `NETLINK_KOBJECT_UEVENT`, create device nodes, apply permissions — is a
few hundred lines and `nexis-init` should own it, since it already runs an
epoll loop and already has a declarative permissions model.

**Desktop environment: ship standalone `udev` as debt.**
Plasma with full hardware support needs the hwdb and the complete library
semantics. Shipping systemd's udev built standalone (as several distributions
already package it) is the honest short-term answer. Pretending otherwise
produces a distribution where laptop function keys and hidpi touchpads don't
work.

**The exit condition — and this is the one to write down.** The long-term fix is
a NexisOS `libudev` implementation backed by the native uevent manager, plus
hwdb ingestion. This is a large but *bounded* project, and it is the single
highest-leverage piece of systemd independence available, because it is the only
component in this document with no maintained alternative. Nothing else on the
list is blocked on it, so it can proceed in parallel with everything else.

Do not start it before the system manager and generation builder work. Do not
pretend it is optional either.

---

## What this means for the roadmap

The Phase 3 `nexis-init` work should absorb the "native" rows above — tmpfiles,
sysusers, sysctl, modules-load, binfmt, oomd — because they are applications of
state `nexis-init` already holds, not separate subsystems.

Two items deserve to be their own roadmap entries rather than sub-bullets:

- **Native uevent manager** (Phase 3). Unblocks the installer's `libudev-zero`
  path and is the foundation of the eventual `libudev`.
- **logind D-Bus subset in `nexis-init`** (Phase 4 or later). Removes `elogind`.

And one deserves to be named as a known, accepted dependency rather than quietly
carried:

- **`libudev` compatibility** (post-Phase 6). Until then the desktop profile
  ships standalone udev, and the README should say so.
