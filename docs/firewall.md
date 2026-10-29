# Firewall

nftables, default-deny inbound, generated from service declarations, and part of
the generation.

## Why it is generated rather than written

The usual failure is not that firewall syntax is hard. It is that the firewall
and the services drift apart. Someone enables nginx and forgets to open 443;
someone removes a service and the port stays open for two years. Hand-maintained
rules are a second description of the system that has to be kept in sync with the
first one by hand.

NexisOS already knows which services run and what they listen on, because
services are declared:

```toml
[service.nginx]
exec  = "/usr/bin/nginx"
ports = [{ port = 80, proto = "tcp" }, { port = 443, proto = "tcp" }]
```

So the inbound ruleset is **derived**. Removing the service closes the port,
necessarily, because there is only one description. A port cannot be open for
something that isn't running.

Explicit rules remain available for everything services can't express:

```toml
[firewall]
default-input   = "drop"
default-forward = "drop"
default-output  = "accept"

[[firewall.rule]]
comment = "management network SSH"
input   = true
proto   = "tcp"
port    = 22
source  = ["10.0.0.0/24", "fd00:1::/64"]
action  = "accept"
```

## Why nftables

- **Atomic replacement.** `nft -f` swaps an entire ruleset in one transaction.
  There is no window during a reload where the machine is half-configured — which
  with iptables is a real gap that a generation-based system would otherwise
  reintroduce on every activation.
- **One ruleset for IPv4 and IPv6.** The `inet` family covers both. This
  matters more than it sounds: the most common firewall failure in the wild is a
  carefully written IPv4 ruleset alongside a wide-open IPv6 stack.
- **Sets and maps** make large allowlists efficient rather than thousands of
  linear rules.
- It is what the kernel actually implements. `iptables` is a compatibility layer
  over it now.

## The default ruleset

Generated for every system unless overridden. Written out as a single
`nftables.conf` inside the generation.

```
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif lo accept

        # ICMPv6 is not optional. Dropping it breaks neighbour discovery and
        # path MTU discovery, which breaks IPv6 in ways that present as
        # intermittent application failures rather than as a firewall problem.
        icmpv6 type {
            destination-unreachable, packet-too-big, time-exceeded,
            parameter-problem, nd-router-advert, nd-neighbor-solicit,
            nd-neighbor-advert, mld-listener-query
        } accept

        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept

        # Echo, rate limited. Answering ping is useful for diagnosis; being a
        # flood amplifier is not.
        icmp type echo-request limit rate 10/second accept
        icmpv6 type echo-request limit rate 10/second accept

        # SYN flood mitigation ahead of the service rules.
        tcp flags syn / fin,syn,rst,ack limit rate 60/second burst 20 packets accept

        # --- generated from service declarations ---

        counter
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

Design decisions in that, each of which is a place distributions commonly get it
wrong:

- **`policy drop` on input**, not accept-with-reject-at-the-end. If rule
  generation fails, the machine is closed rather than open.
- **`drop`, not `reject`, by default.** Reject is friendlier on a LAN and is
  available per-rule; silent drop is the right default on an untrusted network.
- **`ct state invalid drop` before anything else**, which closes a family of
  out-of-state injection tricks.
- **Forwarding defaults to drop and `ip_forward` stays off** unless a
  declaration turns it on. A machine should not become a router because a
  container runtime was installed.
- **Output accept by default.** Egress filtering is valuable and is available
  (`default-output = "drop"` plus explicit rules), but a default-deny egress
  that the user did not ask for produces a machine that appears broken.
- **The counter at the end of input** makes "what is being dropped" answerable
  without editing the ruleset first.

## Companion sysctls

Firewall rules alone do not cover these, and they are applied declaratively
alongside:

```
net.ipv4.conf.all.rp_filter            = 1   # strict reverse path
net.ipv4.conf.all.accept_redirects     = 0
net.ipv6.conf.all.accept_redirects     = 0
net.ipv4.conf.all.accept_source_route  = 0
net.ipv6.conf.all.accept_source_route  = 0
net.ipv4.conf.all.log_martians         = 1
net.ipv4.tcp_syncookies                = 1
net.ipv4.ip_forward                    = 0
net.ipv6.conf.all.forwarding           = 0
```

## Zones

Interface-scoped policy without inventing a zone daemon:

```toml
[firewall.zone.trusted]
interfaces = ["virbr0"]
default    = "accept"

[firewall.zone.public]
interfaces = ["wlan0", "eth0"]
default    = "drop"
services   = ["ssh"]
```

Zones compile to `iifname` matches in the generated ruleset. There is no runtime
zone state and no daemon — the ruleset is static once generated, which is the
point.

## The firewall is part of the generation

The compiled ruleset is a generation artifact, sealed with everything else.

- Rolling back restores the firewall that matched that system. It is not
  possible to roll back services and keep the newer ruleset, which is exactly
  the drift that makes rollback dangerous elsewhere.
- Activation applies it in one `nft -f` transaction during the same window as
  the rest of activation, and a ruleset that fails to load fails the activation
  rather than leaving the machine in a mixed state.
- `nexis diff 41 42` shows firewall changes alongside package changes, so a port
  opening is visible in the same review as the service that opened it.

## Deliberately not included by default

- **Egress filtering.** Available, off by default. See above.
- **IDS/IPS.** Suricata, CrowdSec and similar belong in the optional security
  profiles, not the base.
- **NAT and routing.** Declarable, but a workstation profile should never enable
  them implicitly.
- **A firewall daemon.** No firewalld equivalent. Runtime mutation of the
  ruleset would be state outside the declaration, which is the thing the whole
  system is built to prevent.
