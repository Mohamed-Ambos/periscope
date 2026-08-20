# periscope

**On-demand remote support access into customer networks.** A disposable browser,
inside their LAN, for the length of one support call — and nothing before or after.

Named for how it behaves: down by default, raised only to look, a narrow view of
one place, retracted leaving nothing behind.

---

## The problem

Ambos deploys security cameras and patrol robots at customer sites. When something
breaks, support has to reach a device on a private network. The usual answers are
a standing VPN profile on an engineer's laptop, or a two-hour drive.

A standing VPN profile has two properties nobody wants:

- **It never turns off.** A tunnel configured once still exists at 3am on a Sunday,
  on a laptop that may be lost or stolen.
- **One laptop reaches many customers.** Nothing structurally prevents work for
  customer A from touching customer B's network.

periscope makes access an **event** instead of a **state**. A customer calls, an
engineer clicks Connect, a container dials into that one customer's network and
hands over a browser already inside it. Click Stop and the container, the tunnel
and the credential are destroyed together.

## The security model

Two claims, and both are consequences of the architecture rather than promises
about how the tool is used:

| Claim | Enforced by |
|---|---|
| **Access is off by default** | No container, no browser, no tunnel exists until someone clicks Connect. There is nothing running to compromise. |
| **One session reaches one customer** | `AllowedIPs` puts exactly one subnet in the session's routing table. Reaching anywhere else isn't forbidden — it's unroutable. |
| **The browser cannot wander** | It has no network stack of its own. Docker assigns it no IP and no interfaces; it borrows the VPN container's namespace. |
| **Nothing survives the call** | Containers are removed, volumes deleted, and the WireGuard key erased from disk. Nothing to expire or revoke afterwards. |
| **Every action is recorded** | An append-only audit log, written outside the session, including failed attempts. |

This is **not** remote desktop. Nothing is installed on a customer machine, nobody
has to be present to approve, and no one's screen is taken over. What the engineer
gets is a *network position* — the ability to open `https://camera-01` — which is
considerably less than remote control and considerably easier for a security team
to approve.

## Architecture

```
   engineer's browser
          │
          │  https://console.psc.test
          ▼
   ┌──────────────┐        ┌───────────────┐
   │   Traefik    │───────►│   authentik   │   every request checked
   └──────┬───────┘        └───────────────┘   before it reaches anything
          │
          ▼
   ┌──────────────────┐
   │ session manager  │  creates and destroys sessions via the Docker socket
   └────────┬─────────┘  keeps no state — asks Docker what is live
            │
            ▼
   ┌─────────────────────────────────────────────┐
   │  one session — three containers,            │
   │  one shared network namespace               │
   │                                             │
   │   ┌───────┐  ┌──────────┐  ┌─────────┐      │
   │   │  vpn  │  │ resolver │  │ browser │      │
   │   └───┬───┘  └────┬─────┘  └────┬────┘      │
   │    creates     borrows       borrows        │
   │       └───────────┼─────────────┘           │
   │        ┌──────────▼──────────┐              │
   │        │  one network stack  │───── wg0 ────┼───► the customer's LAN
   │        └─────────────────────┘              │
   └─────────────────────────────────────────────┘
```

**Three containers, one network namespace.** They are siblings, not nested — Docker
never puts a container inside another. What they share is a single network stack:

| Container | Job |
|---|---|
| `vpn` | Creates the namespace and the tunnel. Runs `wg-quick up wg0`, installing exactly one route — the customer's subnet. The only one of the three with an IP address. |
| `resolver` | dnsmasq, serving that customer's device names from a JSON registry, so an engineer types `camera-01.acme.internal` rather than an address. Unknown names still resolve publicly. |
| `browser` | Firefox on `:3000`, with `network_mode: "service:vpn"`. It has no interfaces of its own, so it can reach exactly what the tunnel reaches and nothing else. |

The Traefik routing labels live on the **vpn** container, not the browser — a
container with no IP cannot be routed to, so the namespace owner carries the
routing and points at the port its tenant listens on.

The file worth reading first is
[`session/docker-compose.session.yml`](session/docker-compose.session.yml). It is
about forty lines and contains the entire idea.

## Requirements

- Docker and the Compose plugin
- ~4 GB of free RAM (one session with a browser is the heavy part)
- Linux (tested on Debian/Kali); the session containers need `NET_ADMIN`
- Four `/etc/hosts` entries — `scripts/hosts-entries.sh` prints the command

## Getting started

```bash
git clone https://github.com/Mohamed-Ambos/periscope.git
cd periscope

cp .env.example .env          # fill in the secrets: openssl rand -base64 48
./scripts/hosts-entries.sh    # prints the one sudo command you need

./scripts/lab-up.sh           # Traefik, session manager, simulated customer
./scripts/auth-up.sh          # authentik; first boot migrates a DB, ~3 min
```

Then open **<http://console.psc.test:8088/>** and log in as `akadmin` with the
password from `AK_ADMIN_PASSWORD` in your `.env`.

Click **Connect** on a customer, wait a few seconds, click **Open**. You are now
looking at a Firefox running inside a container that reached the customer's network
through a tunnel that did not exist ten seconds ago. Browse to
`camera-01.acme.internal` — a name, not an address. Then click **Stop**.

### Commands

```bash
./scripts/session-up.sh customer2      # exactly what the Connect button calls
./scripts/session-down.sh customer2    # exactly what Stop calls
./scripts/lab-down.sh                  # remove everything, including volumes

docker logs psc-customer2-vpn          # tunnel bring-up and the resulting routes
docker exec psc-customer2-vpn wg show  # handshake and transfer counters
cat session-manager/audit.log          # who started and stopped what, when
```

The button and the engineer run the *same script*. There is no second code path
that can drift from the one you debug by hand.

## Verifying the claims

Each of these is something you can check rather than take on faith.

```bash
# The browser has no network of its own
docker inspect psc-customer2-browser -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
# → prints nothing at all

# Only the customer's subnet is routed over the tunnel
docker exec psc-customer2-vpn ip route
# → 172.31.90.0/24 dev wg0   — and no default route into their network

# The tunnel is the only way in
docker exec psc-customer2-vpn wg-quick down wg0
docker exec psc-customer2-vpn curl -sk --max-time 5 https://172.31.90.10/
# → fails. The camera is gone. Refresh the browser tab; gone there too.

# A session is never on the customer's network
docker inspect psc-customer2-vpn -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# → psc_sessions psc_transit    (never psc_customer_lan)

# Nothing survives
./scripts/session-down.sh customer2 && docker ps -a | grep customer2
# → nothing
```

## What is real and what is simulated

**Simulated** — the camera, the customer's LAN, their VPN endpoint, and the
internet between us. That is `docker-compose.lab.yml`, and it exists so the whole
system runs on one laptop. The customer LAN is an `internal` Docker network with no
route to the host or the internet, so reaching the camera *proves* the tunnel
carried the traffic; nothing else could have.

**Real, and unchanged in production** — the session containers, the namespace
isolation, the Traefik routing, and the session manager's start/stop/audit logic.

## Repository layout

```
periscope/
├── docker-compose.console.yml     # ours: Traefik + session manager
├── docker-compose.auth.yml        # authentik: login and MFA
├── docker-compose.lab.yml         # the simulated customer (the only pretend part)
├── session/
│   ├── docker-compose.session.yml # the session template — read this first
│   ├── vpn/                       # WireGuard client image
│   └── resolver/                  # dnsmasq image
├── session-manager/
│   ├── app.py                     # the console: list, start, stop, audit
│   ├── customers.yml              # the customer register
│   └── devices/<customer>.json    # per-customer device registry
├── auth/blueprints/               # provisions the authentik application
├── scripts/                       # what the buttons actually call
└── docs/                          # illustrated architecture and walkthrough
```

## Configuration

All configuration is in `.env` — see `.env.example`, which documents each value.
The one that catches everybody:

```ini
HOST_PROJECT_DIR=/absolute/path/to/periscope
```

The session manager starts sessions *through the Docker socket*, and the daemon
resolves bind-mount paths on the **host**, not inside whichever container asked.
Without this, mounts silently point at a path that exists only inside the session
manager and the session comes up with empty files.

Secrets are never committed. `.env`, `session/conf/*`, `lab/wg-config/*` and the
audit log are all gitignored.

## Taking it to a real customer

The session half needs **no changes at all**. What changes is where the tunnel
terminates.

In the lab, the session dials the customer directly, because we own both ends. A
real customer sits behind NAT — you cannot dial into them, and asking for an
inbound port forward is precisely what a security team refuses. Instead both ends
dial **outwards** to a rendezvous with a public address, and neither ever accepts
an incoming connection:

```
   our session ──dials out──►  hub  ◄──dials out── site gateway ──► customer LAN
                            (public IP)
```

The whole ask on the customer becomes one sentence: *this device needs to send
outbound UDP to one address.* No inbound rule, no port forward, no public IP.

And at any site with an Ambos robot, that gateway is **already installed** —
`fleet-management`'s `lan-over-vpn` makes a robot route and NAT between its
WireGuard interface and the LAN it is plugged into. The NAT is what means the
customer never has to add a route to their own router.

## Status

| Capability | State |
|---|---|
| Session containers, tunnel, namespace isolation | working, verified end to end |
| Two customers at once, separate tunnels, mutually unreachable | working |
| Device names from a per-customer JSON registry | working |
| Console: connect / stop / live state / audit log | working |
| authentik login on the console, MFA available | working, verified |
| Auth on **session** URLs | **not built** |
| Credentials fetched from Infisical | **not built** — the lab writes keys to disk |
| Idle timeout / reaper | **not built** |
| A real customer, a real tunnel | **not started** |

### Known gaps

**Session URLs are not authenticated.** A live session's browser answers anyone who
can reach the host. authentik's `forward_single` mode covers exactly one hostname —
the console. `forward_domain` would cover the console *and* every session with a
single provider; it was tried twice and returns 404 for every host, and that failure
is **unresolved**. The better answer, and the one on the roadmap, is for the session
manager to create a provider per session through authentik's API — which also allows
*which engineer may open which customer*, rather than only who may log in.

**There is no reaper.** `SESSION_IDLE_MINUTES` exists in `.env.example` and nothing
reads it. A forgotten session is a standing tunnel into a customer's network — the
exact thing this design exists to abolish.

> **Until both are fixed, this must not hold a real customer credential.**

## Documentation

- **[docs/support-sessions-architecture.html](docs/support-sessions-architecture.html)**
  — the full picture: the four layers, the scripts and config files that carry the
  design, and what changes at a real customer.
- **[docs/session-lab-walkthrough.html](docs/session-lab-walkthrough.html)**
  — illustrated: every container and what it stands for in real life.
- **[LAB-GUIDE.md](LAB-GUIDE.md)** — what to click, and the commands that prove each
  isolation claim.
- **[docs/risks-and-mitigations.md](docs/risks-and-mitigations.md)** — everything known
  to be wrong, likely to go wrong, or waiting to go wrong, and what to do about each.

## Scope

A **prototype, not production**, and a personal repository — deliberately outside
the company organisation. It reuses building blocks the company already runs
(Traefik, WireGuard, authentik, Infisical, step-ca) on purpose, so nothing here is
exotic to the team that would inherit it.
