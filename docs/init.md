# `nexis-init`

The init system: PID 1, service supervision, and shutdown. For the
component-by-component case against systemd and what replaces each piece, see
[systemd-replacement.md](systemd-replacement.md).

---

## Shape

Single-threaded and event-driven, built on `pidfd`, `epoll`, `signalfd`,
`timerfd`, cgroups v2 and namespaces. No threads in PID 1, no shell in the
normal service path, and no dynamic linking beyond libc — a PID 1 that cannot
start is an unbootable machine, so its attack surface and its failure modes are
both kept small enough to read.

`pidfd` rather than `SIGCHLD` bookkeeping matters specifically: a pidfd cannot
be recycled onto a different process, which removes the class of supervision
bug where a slow reaper signals a PID that has already been reused.

## What it supervises

Starting services, tracking dependencies, readiness, restart policy, resource
limits, sandboxing, socket activation, and shutdown.

It also absorbs work systemd splits into separate programs, because in a
declarative system that work is the *application* of state the init system
already holds rather than a subsystem of its own:

| Absorbed | systemd equivalent |
| --- | --- |
| Runtime directory creation | `systemd-tmpfiles` |
| User and group creation | `systemd-sysusers` |
| sysctls, module loading, binfmt | `systemd-sysctl`, `-modules-load`, `-binfmt` |
| OOM policy from PSI pressure | `systemd-oomd` |
| Device nodes from netlink uevents | `systemd-udevd` (partially — see below) |

`libudev` is the one component with no maintained alternative. Until a
compatible shim exists over the native uevent manager, the desktop profile
ships standalone `udev`. That is stated plainly rather than wished away;
[systemd-replacement.md](systemd-replacement.md) has the detail.

## Compatibility

`sd_notify`, socket activation conventions, and eventually a subset of the
`org.freedesktop.login1` D-Bus interface to replace `elogind`. The goal is
reducing migration cost, not reproducing systemd.

## Service model

Services are declared, never scripted:

```toml
[service.nginx]
exec = "/usr/bin/nginx"

[service.nginx.dependencies]
requires = ["network"]
after    = ["network"]

[service.nginx.security]
selinux_domain = "httpd_t"
needs_network  = true

[service.nginx.resources]
memory_max = "512M"
tasks_max  = 512
```

A service's `ports` and `security` block are not decoration: the nftables
ruleset is derived from them ([firewall.md](firewall.md)) and so is its SELinux
domain transition ([selinux.md](selinux.md)). There is one description of the
system, so removing a service necessarily closes its port.

The schema is still under development.

## Suspend

The sleep path is part of init because the inhibitor lock is: a process asks
not to be suspended, and PID 1 is the only thing that reliably learns when that
process dies. A leaked block inhibitor from a crashed media player is why a
laptop silently stops sleeping and nothing says why — here the lock is dropped
with the process.

Three rules, all aimed at the same failure class: a machine that cycles between
suspend and resume, or between screen-off and screen-on, without settling.

- **Suspend is idempotent.** A request while one is in flight is dropped, not
  queued. A power manager whose idle timer keeps resetting can otherwise issue
  several per second, each restarting the sequence before the last finished.
- **Thrash is counted and stopped.** Suspend/resume cycles inside a window are
  counted exactly as service restarts are, and past a threshold the machine
  stays awake and says why. Staying awake is the better failure: a laptop that
  will not sleep is visible and diagnosable; a screen strobing at 2Hz is
  neither.
- **Wakeup sources are declared.** A device armed in `/proc/acpi/wakeup` can
  resume the machine the instant it suspends. The set of things permitted to
  wake it is a stated fact, so `nexis check` turns "it will not stay asleep"
  into a diff.

Delay inhibitors get five seconds, matching logind's `InhibitDelayMaxSec`, so
software written against logind behaves the same. A hung inhibitor cannot hold
sleep open indefinitely — the same escalate-rather-than-wait rule shutdown
follows.

`suspend-to-idle` is preferred over `deep` where the firmware offers both:
vendor S3 implementations that resume spuriously are common, and that is the
symptom this whole section exists to bound.

None of this fixes a compositor that re-enables outputs when a monitor drops
its hotplug-detect line on DPMS-off. That is above PID 1. It does mean the loop
terminates and names itself instead of running until the battery is flat.

## Controlling terminals

A service declaring `tty = "/dev/tty1"` gets stdin, stdout, stderr **and** the
controlling terminal — all four, because three of them is not usable. An
interactive program given only stdout draws its first frame and then blocks
forever on a read that can never return, which looks exactly like a hang; and
without `TIOCSCTTY` it also receives no SIGINT and no window-size changes, so
Ctrl-C does nothing and a resize is never noticed.

This is what lets the installation medium boot to the installer with no
graphical stack present.

## Socket activation

Init binds listening sockets before any service runs, so a client can connect
at any time and the kernel buffers until the provider is ready.

The value is not lazy startup — it is **start-order independence**. An
`after = ["postgres"]` that really means "otherwise psql gets ECONNREFUSED" is
noise in the declaration, and socket activation removes the need for it. The
dependency graph gets smaller rather than better-scheduled, which matters more
here than in systemd because a declarative system wants its graph to describe
real requirements.

A second consequence: a service listening on port 80 never needs
`CAP_NET_BIND_SERVICE`, because init bound the socket.

The protocol is systemd's exactly — fds from 3 upward, `LISTEN_FDS`,
`LISTEN_PID`, `LISTEN_FDNAMES` — so daemons implementing `sd_listen_fds()`
work unchanged. `LISTEN_PID` is the part worth understanding: it exists so a
service that re-execs, or spawns a helper, does not have the helper mistake
inherited fds for its own.

## Watchdog

A service can be running and useless: process alive, port open, event loop
wedged. Supervision that only watches for exit cannot see that.

Opt-in per service, and it requires `readiness = "notify"` — arming a watchdog
on a service that cannot ping produces a restart loop indistinguishable from a
crash, so the configuration refuses it rather than letting it happen.

On expiry the service is sent **SIGABRT, not SIGTERM**. A wedged process will
not handle SIGTERM either, and SIGABRT produces a core dump that says where it
was stuck. Killing it without that evidence means the next occurrence is just
as mysterious as this one.

## Shutdown

The system must never sit indefinitely in "stopping" because a service refuses
to die.

1. Stop accepting new activations.
2. Compute shutdown order from the dependency graph.
3. `SIGTERM` each service.
4. Watch termination through `pidfd`.
5. Enforce the configured per-service deadline.
6. `SIGKILL` anything past its deadline.
7. Reap remaining processes in the cgroup.
8. Flush filesystem state.
9. Unmount where appropriate.
10. Reboot or power off.

Every step has a bounded deadline, and exceeding one escalates rather than
waits.
