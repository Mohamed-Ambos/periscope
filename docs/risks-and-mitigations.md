# Risks and mitigations

**2026-08-20.** Everything known to be wrong, likely to go wrong, or waiting to go
wrong with periscope — and what to do about each. Written so nobody has to
re-derive it, and so a reviewer meets the problems here rather than discovering
them.

Scope: sections 1–3 are periscope itself. Section 4 is what changes when it
becomes part of the wider Ambos platform. Section 5 records what has already been
fixed.

**Severity** — *Blocker*: must be closed before a real customer credential exists.
*High*: will cause a visible failure or a security finding. *Medium*: will cost
time. *Watch*: fine today, decide before it isn't.

## Register

| # | Issue | Severity | Bites at |
|---|---|---|---|
| 1.1 | Session URLs are unauthenticated | **Blocker** | first real credential |
| 1.2 | No idle reaper — sessions live forever | **Blocker** | first forgotten session |
| 1.3 | Credentials written to disk, not fetched from Infisical | High | first real customer |
| 1.4 | Audit log dies with the container | High | first incident review |
| 2.1 | Customer firewall blocks outbound UDP | High | ~1 in 10 customers |
| 2.2 | Overlapping customer LAN subnets | High | second customer |
| 2.3 | The hub can read plaintext | Medium | first security review |
| 2.4 | Flat hub = no isolation between customers | **Blocker** | second customer |
| 2.5 | `privileged: true` on the site gateway | Medium | first security review |
| 2.6 | Device registry goes stale | Medium | first re-IP at a site |
| 3.1 | Runs on a laptop | High | first out-of-hours call |
| 3.2 | Session manager holds a root-equivalent socket | High | always |
| 3.3 | `/api/state` shells out to Docker on every poll | Watch | ~20 open consoles |
| 3.4 | authentik hangs → the console hangs | Medium | first authentik outage |
| 4.1 | WAF as an interpreted Traefik plugin | High | platform launch |
| 4.2 | Let's Encrypt rate limits with per-tenant hostnames | High | ~50 customers |
| 4.3 | Traefik is a single point of failure | High | first SLA |
| 4.4 | PostgreSQL / NATS / time-series are the real ceilings | Watch | platform scale |

---

## 1. Blocking before any real customer

### 1.1 Session URLs are unauthenticated — *Blocker*

A live session's browser answers anyone who can reach the host:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: customer2.psc.test:8088' http://127.0.0.1:8088/
# → 200, no login
```

Traefik's router list shows why — the console carries the auth middleware and the
session does not:

```
session-manager@docker   middlewares=['ak-auth@docker']
customer2@docker         middlewares=NONE
```

This is an unauthenticated door into a customer's network, open for as long as the
session is.

**Why it isn't already fixed.** authentik's `forward_single` mode protects exactly
one hostname. `forward_domain` would cover the console *and* every session with a
single provider — it was tried twice, under `.localhost` (the cookie is rejected
because a single-label TLD is a public suffix) and under `sb.test` (cookie valid,
outpost still answers 404 for every host). **The second failure is unresolved. Do
not assume a real domain fixes it.**

**Solution.** Have the session manager create an authentik provider *per session*
through the API when it starts one, and delete it on teardown. More work than a
config change, and it buys something `forward_domain` cannot: *which engineer may
open which customer*, rather than only who may log in.

**Interim.** Bind Traefik to a private interface only, so session URLs are
unreachable except over the admin network.

### 1.2 No idle reaper — *Blocker*

`SESSION_IDLE_MINUTES` exists in `.env.example` and **nothing reads it**. A
forgotten session is a standing tunnel into a customer's network — the exact thing
this design exists to abolish.

**Solution.** A loop in the session manager: destroy a session after N minutes with
no traffic, and enforce a hard maximum lifetime regardless of activity. Idle can be
measured from the WireGuard transfer counters (`wg show`), which cost nothing to read.

### 1.3 Credentials on disk — *High*

`session-up.sh` writes the peer config to `session/conf/<id>.conf`. It is deleted at
teardown, but it exists on disk for the life of the session, and survives a crash.

**Solution.** Fetch from Infisical at session start, pass it to the container in
memory, and let it die with the container. Infisical already runs in
`infrastructure`. The session manager is the only component that should ever hold a
credential.

### 1.4 The audit log dies with its container — *High*

`session-manager/audit.log` lives inside the container's project mount. Recreate the
container from a fresh checkout and the record of who reached which customer is gone
— including the failures, which are the entries you want most during an incident.

**Solution.** Ship it off the host: syslog, Loki, or an object store. Append-only,
and somewhere a person would actually look.

---

## 2. Networking at a real site

### 2.1 The customer's firewall blocks outbound UDP — *High*

WireGuard is UDP-only and **has no fallback**. Some corporate networks permit
outbound UDP only to DNS. The tunnel then never establishes, and the failure mode is
silence — which you will be debugging live while the customer waits.

**Solution.** Test before demo day, from the site itself:

```bash
nc -zvu <hub> 51820        # or: wg-quick up wg0 && wg show
```

**Longer term.** Either adopt a control plane that relays over HTTPS when hole
punching fails (NetBird, Tailscale), or wrap WireGuard in `wstunnel`/`udp2raw` for
the sites that need it. See `remote-access-tech-comparison.md`.

### 2.2 Overlapping customer subnets — *High*

Two customers both on `192.168.1.0/24` collide in `AllowedIPs` and at the hub. Fine
for one site; broken at the second.

**Solution.** Give every site a unique carrier subnet (`100.64.<site>.0/24`) and
1:1 NAT it at the site gateway. Decide this before the second customer, not after —
retrofitting means re-addressing live sites.

### 2.3 The hub can read plaintext — *Medium*

A hub-and-spoke WireGuard hub **terminates both tunnels**: it decrypts traffic from
the session and re-encrypts it to the site. It is not a dumb relay, and it is a
trusted component.

**Solution.** Treat it as one — minimal packages, nothing else on the host, keys-only
SSH, and the isolation rules written down and reviewed. If a customer requires that no
machine of ours can see their traffic, that is an argument for a mesh overlay where
peers connect directly and the coordination server never holds plaintext.

### 2.4 A flat hub gives up isolation — *Blocker at customer two*

In the lab, isolation is structural: separate Docker networks mean a session
*physically cannot* reach another customer. A single flat hub puts every peer in one
subnet and will forward between them unless stopped.

**Solution, in order of strength.** One WireGuard interface and subnet per customer —
structural again, more setup. Or per-peer `FORWARD` rules on the hub — cheap, correct
only while nobody edits them wrong. If you use rules, **demonstrate them**: start a
session for site A and show it failing to reach site B.

### 2.5 `privileged: true` on the site gateway — *Medium*

`lan-over-vpn` runs privileged because Docker otherwise blocks writes to host network
sysctls such as `net.ipv4.ip_forward`. It is a real privilege on a machine sitting in
a customer's building, and the word will come up in a security review.

**Mitigation, already in place.** The service writes nothing to the robot's
filesystem and removes its managed iptables rules when stopped. Know that before
you're asked.

### 2.6 The device registry goes stale — *Medium*

`session-manager/devices/<customer>.json` maps names to **static** addresses. A camera
that gets a new address from DHCP breaks the name silently.

**Solution.** Require fixed addresses (DHCP reservations) at commissioning — normal
practice for cameras, but now load-bearing. Where a customer runs their own DNS,
forward their zone instead and maintain nothing:

```sh
--server=/acme.internal/192.168.131.1
```

---

## 3. Running it as a service

### 3.1 It runs on a laptop — *High*

A support tool that is asleep when a customer calls is not a support tool.

**Solution.** An always-on host. Not the NAS: 2 GB of RAM, and one session with a
browser wants most of it. Budget roughly 1–2 GB per concurrent session — three
sessions want about 8 GB.

### 3.2 The session manager holds a root-equivalent socket — *High*

Mounting `/var/run/docker.sock` read-write is equivalent to root on the host: anyone
who can send it commands can start a privileged container mounting the whole
filesystem. Through the sessions it starts, it can also reach every customer network
you serve.

**Mitigations, current and planned.** It is deliberately ~125 lines with four
endpoints and no user accounts; authentik guards the door from outside so it contains
no auth code of its own. Next steps: run it on a host that does nothing else, and
consider a socket proxy that permits only the container operations it actually needs.

### 3.3 `/api/state` shells out to Docker on every poll — *Watch*

The console polls every 4 seconds per open tab, and each call spawns `docker ps` plus
`docker inspect` and reads two files. Twenty open consoles is ~5 req/s of process
spawning, all day. Small, but it is the component with the least headroom — and the
only scaling concern visible in the current design.

**Solution, cheapest first.** Cache the state server-side for ~1 second, so ten tabs
cost one `docker ps`. Then talk to the Docker API over the socket instead of spawning
the CLI. Then replace polling with Server-Sent Events, so idle consoles cost nothing.

### 3.4 If authentik hangs, the console hangs — *Medium*

Verified: with authentik **stopped**, the console returns 404 and leaks nothing —
fail-closed, correct. With authentik **paused** (present but unresponsive) the router
stays enabled and the request **hangs indefinitely** rather than failing fast.

**Solution.** Set a timeout on the forward-auth middleware, and health-check
authentik so a hung instance is restarted rather than tolerated.

---

## 4. If periscope becomes part of the Ambos platform

These apply to the multi-tenant platform, where customer users log in through
Traefik and the load is no longer just a handful of support engineers.

### 4.1 WAF as an interpreted Traefik plugin — *High*

Open-source Traefik has no native WAF. Adding one as a plugin means it runs through
**Yaegi, a Go interpreter** — plugin code is not compiled in. Inspecting every request
body through an interpreted rule engine is a completely different performance profile
from routing.

**Solution.** Put TLS, WAF and DDoS at a managed edge and let Traefik do routing only
— which also makes it stateless and horizontally scalable. If a managed edge is
politically unacceptable for a German security product, run the WAF as its own service
rather than as a plugin. Benchmark before committing either way.

### 4.2 Certificate rate limits with per-tenant hostnames — *High*

`customer-N.app.ambos-security.com` per tenant means a certificate per tenant, and
Let's Encrypt limits certificates per registered domain per week. This is a wall you
hit while onboarding, with nothing to do with performance.

**Solution.** One **wildcard certificate via DNS-01** covering every tenant. Decide
before the second customer.

### 4.3 Traefik is a single point of failure — *High*

Every user, every tenant, every session passes through one box.

**Solution.** At least two instances behind a balancer — which means configuration can
no longer come from container labels on one host. Move to a shared source (file
provider on shared storage, a KV store, or Kubernetes CRDs). Note `acme.json` is
**not** safe to share between instances, so certificate management must move out of
Traefik for this to work.

### 4.4 Traefik is not the ceiling — *Watch*

Sizing conversations tend to focus on the proxy. In that architecture the real limits
are, in order: **PostgreSQL** (one primary for all tenants), the **session containers**
(RAM per concurrent support call), **NATS/JetStream fan-out** (all telemetry from all
sites), and **time-series writes** (every device, every site). Traefik is last.

**Solution.** Instrument before estimating. Traefik exports Prometheus metrics and
`infrastructure` already runs Prometheus and Grafana — turn it on so this stops being
a question anyone has to guess at.

---

## 5. Already found and fixed

Recorded so nobody re-derives them.

| Issue | Cause | Fix |
|---|---|---|
| **Teardown destroyed nothing and reported success** | `session-down.sh` set only `WG_CONF`; the session compose file also interpolates `DEV_HOSTS` and `RESOLV_CONF`. Unset, they render an empty mount source, compose refuses to parse the file, `down` never runs — and `\|\| true` swallowed it. | All three variables set; generated files removed; the script now counts what is left and exits non-zero rather than lying. |
| **Console showed every session as stopped** | `live()` sliced names with `name[3:-4]`, written for the 3-character prefix `sb-`. Renaming to `psc-` made it 4, so every id came back as `-customer2`. | `removeprefix`/`removesuffix` against named constants. A rename cannot break it again. |
| **`Permission denied` starting a session by hand** | The session manager runs as root and writes `session/conf/<id>.conf` through the Docker socket, so leftovers are root-owned. | `rm -f` before writing — deletion needs write permission on the directory, not the file. |
| **HTTP 502 on every session** | `session-up.sh` passed `$(pwd)` as a mount source; the Docker daemon resolves bind-mount paths **on the host**, where the session manager's `/project` does not exist. | `HOST_PROJECT_DIR`, with a compose guard that refuses to start if it is unset. |
| **Second session came up with a tunnel and no peer** | One WireGuard peer config shared across sessions. A server tracks one endpoint per public key, so the newer handshake silently steals the older tunnel. | One credential per customer, always. |
| **Every login failed with "invalid state"** | `.localhost` — browsers reject cookies scoped to a single-label TLD, and authentik's outpost needs that cookie. | A registrable lab domain (`psc.test`) plus `/etc/hosts`. |
| **Traefik silently created no router for a session** | Labels were on the `browser` container, which has no IP and cannot be routed to. | Labels live on the namespace owner (`vpn`), pointing at the port its tenant listens on. |
