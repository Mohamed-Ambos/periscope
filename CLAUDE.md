# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this is

A working lab for **on-demand remote support sessions**. A customer calls, a
support engineer clicks one button, and a disposable set of containers dials
into that customer's network and hands the engineer a browser that is already
inside it. When the call ends, everything is destroyed.

It is a **prototype, not production**. It runs on a laptop and deliberately
simulates the customer side. The session containers themselves are real — what
runs here is what would run in production, unchanged.

**Repository:** `github.com/Mohamed-Ambos/session-broker` — public, personal
account, deliberately **outside** the company organisation.

## Who this is for and why it exists

Ambos Security GmbH deploys **security cameras and patrol robots** at customer
sites. When something breaks, support needs to reach devices on a customer's
private network. Today that means ad-hoc VPN access and hosts-file edits.

The goal, as the user described it: *"the customer calls, the support guy opens
something on our system like customer2.ambos.com, clicks a button to start a
box, and that box connects to the customer's VPN."*

Two properties make this sellable to a security-conscious customer, and both
are the point of the design:

- **Access is off by default.** No standing tunnel into anyone's network.
- **One session reaches one customer.** Isolation is structural, not policy.

## The company context

`/home/kali/ambos` on the user's machine holds the company repositories. **This
project is separate and must stay that way** — do not modify anything under
`ambos/` from here.

| Repo | What it is |
|---|---|
| `nsl-test-server` | Alarm-protocol sandbox (SIA DC-09, VdS 2465) + video-alarm gateway. Rust. |
| `infrastructure` | Docker Compose stack on a Synology NAS: Traefik, private registry, step-ca, NATS, Infisical, CI runners. |
| `fleet-management` | ROS 2 monorepo for the robots (renamed from `robot-control`). Its `lan-over-vpn` service already makes a robot route between its WireGuard tunnel and the customer LAN — i.e. a robot is already a site gateway. |
| `ambos-workflows` | Shared release automation (CalVer, git-cliff, build-once/promote). |

Relevant inheritance: the company already runs **Traefik**, **Infisical**
(secrets), **WireGuard**, and a **step-ca** internal CA. This lab reuses those
same building blocks on purpose, so nothing here is exotic to the team.

There is a companion design note covering the *customer-facing* side (giving
cameras trusted HTTPS names). That is a **different product** from this one —
support access and customer daily access should not be conflated.

## Commands

```bash
cp .env.example .env             # fill in secrets: openssl rand -base64 48
./scripts/hosts-entries.sh       # prints the one sudo command needed
./scripts/lab-up.sh              # traefik + session manager + fake customer + wg identities
./scripts/auth-up.sh             # authentik; first boot migrates a DB, ~3 min

./scripts/session-up.sh customer2    # what the Connect button calls
./scripts/session-down.sh customer2  # destroy it
./scripts/lab-down.sh                # remove everything including volumes
```

Console: `http://console.sb.test:8088/` &middot; authentik: `http://auth.sb.test:8088/`
&middot; Traefik dashboard: `http://localhost:8089/`

Log in as `akadmin`, password from `AK_ADMIN_PASSWORD` in `.env`.

## Architecture

Three groups of containers. Names are prefixed `sb-`.

**Ours (always on)** — `sb-traefik`, `sb-session-manager`, `sb-ak-server`,
`sb-ak-worker`, `sb-ak-db`, `sb-ak-redis`.

**The simulated customer (the only pretend part)** — `sb-wg-server` (their
firewall or a box we place), `sb-camera-01` (nginx with a self-signed cert,
because that is what a real camera serves).

**One session, per customer, ephemeral** — `sb-<id>-vpn`, `sb-<id>-resolver`,
`sb-<id>-browser`.

Three **networks** (these are not containers and never appear in `docker ps`):

| Network | Represents | Attached |
|---|---|---|
| `sb_customer_lan` | the customer's LAN, `internal=true` | `sb-wg-server`, `sb-camera-01` — **never a session** |
| `sb_transit` | the public internet | `sb-wg-server`, each session's `vpn` |
| `sb_sessions` | our internal network | Traefik, session manager, authentik, each session's `vpn` |

### The one idea that matters

```yaml
browser:
  network_mode: "service:vpn"    # and the same for resolver
```

The browser and resolver have **no network stack of their own**. Docker gives
them no IP. They borrow the vpn container's namespace, so they can reach
exactly what the tunnel reaches and nothing else. Verify:

```bash
docker inspect sb-customer2-browser -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'   # empty
docker exec sb-customer2-vpn ip route      # only 172.31.90.0/24 dev wg0
```

### Traefik labels go on the vpn container

Not on the browser. A container with no IP cannot be routed to; Traefik would
silently never create the router. The namespace owner carries the labels and
points at the port the browser listens on inside it.

### Device names, not hosts files

Each customer has a JSON registry in `session-manager/devices/<id>.json` (static IPs).
At session start it is rendered into a hosts file that a **dnsmasq resolver
inside the session** serves, and the browser's `/etc/resolv.conf` is mounted
pointing at `127.0.0.1`. The engineer types `camera-01.acme.internal`. No
machine anywhere edits a hosts file. Unknown names fall through to Docker's
resolver, so public DNS still works.

## Hard-won lessons — do not re-derive these

**Each customer needs its own VPN identity.** Sharing one WireGuard peer config
across sessions fails *silently*: the first session works, the second comes up
with a tunnel and no peer, because a WireGuard server tracks one endpoint per
public key and the newer handshake steals the older tunnel.

**`.localhost` cannot be used.** Browsers resolve `*.localhost` automatically,
which is tempting — but they **reject cookies scoped to `localhost`** because a
single-label TLD is a public suffix. authentik's outpost needs that cookie, so
every login died with *"invalid state"*. Hence `sb.test` plus `/etc/hosts`.

**`authentik_host` is used from both sides.** The outpost trades the login code
for a token with it *server-side*, and the *browser* is redirected to it. An
internal-only name breaks the browser; a name the container cannot resolve
gives HTTP 400. The fix here is one browser-facing URL plus an `extra_hosts`
entry mapping it to `host-gateway`.

**Bind-mount paths are resolved by the Docker daemon, on the host.** The session manager
runs in a container where the project is at `/project`, but it starts sessions
through the Docker socket — so passing `$(pwd)` mounted a path that exists only
inside the session manager. The session came up with empty files: the resolver exited
with *"no device file mounted"*, the browser never started because it depends on
it, and Traefik answered **502**. Hence `HOST_PROJECT_DIR` in `.env`. Anything
mounted into a session must use a host path, not a session manager path.

**A running session does not pick up changed compose definitions.** Recreate it.
A session alive for days is its own smell — that is what the (unbuilt) reaper is
for.

## State

| Capability | State |
|---|---|
| Session tunnel + namespace isolation | working, verified |
| Two customers concurrently, separate tunnels | working |
| Device names from the JSON registry | working |
| Console: connect / stop / live state / audit | working |
| authentik login on the console | working |
| Auth on **session** URLs | **not working** — see below |
| Credentials from Infisical | not built (lab writes files) |
| Idle timeout / reaper | not built |

**The gap that matters:** a live session's browser is reachable without logging
in. `forward_single` covers one hostname. `forward_domain` was tried twice —
under `.localhost` (cookie rejected) and under `sb.test` (cookie fine, outpost
still 404s for every host) — and the second failure is **unresolved**. The
better production answer is for the session manager to create a provider per session via
authentik's API, which also allows *which engineer may open which customer*.

Until that is fixed, **this lab must not hold a real customer credential.**

## Conventions

- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, live in `scripts/`.
- Compose files are split by concern: `docker-compose.lab.yml` (pretend
  customer), `docker-compose.console.yml` (ours), `docker-compose.auth.yml`
  (authentik), `session/docker-compose.session.yml` (the session template).
- **Never commit** `.env`, `session/conf/*`, `lab/wg-config/*`, or
  `session-manager/audit.log` — they hold private keys and secrets. Already gitignored;
  it was got wrong once and fixed in a follow-up commit.
- Comments explain *why*, especially where a plausible alternative fails. Most
  comments in this repo exist because something was tried and did not work.
- The user is learning this material — explain reasoning, and say plainly when
  something is unverified rather than presenting a guess as fact.

## Working agreements

- Never push to a company repository from here.
- Do not commit with `-c user.email=...`; use the configured identity
  (`Mohamed-Ambos <mohamed9.ambos@gmail.com>`). A wrong author email attaches
  the wrong GitHub account to the commit.
- No AI attribution in commits, PRs, or release notes.
- Verify claims against the running system before writing them down. Several
  statements in earlier drafts of the docs were wrong until tested.

## Where to read next

- `LAB-GUIDE.md` — walkthrough with commands to verify each isolation claim.
- `docs/session-lab-walkthrough.html` — illustrated: every container, what it
  represents at a real customer, how they connect.
- `session/docker-compose.session.yml` — forty lines containing the whole idea.
