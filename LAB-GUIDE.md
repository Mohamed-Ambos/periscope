# Lab guide — see it working with your own eyes

This lab runs the whole support-session idea on your laptop, with **nothing from
the company touched**. It simulates a customer site (a camera on a private
network behind a VPN endpoint) and runs the real thing on our side (a broker
that starts disposable sessions, and Traefik in front of them).

Everything below is a command you can run and a result you can look at.

---

## 1. What is pretending to be what

| In the lab | In real life |
|---|---|
| `sb-camera-01` — nginx with a self-signed cert | An Axis camera at a customer |
| `sb_customer_lan` — an isolated Docker network | The customer's LAN |
| `sb-wg-server` — WireGuard endpoint | The customer's firewall, or a box we place |
| `sb_transit` — a Docker network | The public internet |
| `sb-broker` — the console with the buttons | The same thing, on our server |
| `sb-traefik` | The same thing, on our server |
| `sb-<customer>-vpn` + `-browser` | Exactly the same, unchanged |

The session containers are **not** a simulation. What runs here is what would
run in production.

---

## 2. Start it

```bash
cd ~/session-broker
cp .env.example .env          # first time only
./scripts/lab-up.sh
```

That starts Traefik, the broker, the fake customer network, and generates one
WireGuard identity per customer. Takes a minute the first time.

Now open the console:

**<http://console.localhost:8088/>**

You should see two customers, both stopped. Nothing is connected yet — that is
the normal state of the whole system.

---

## 3. Watch a session come to life

Click **Connect** on *ACME GmbH*. Wait ~3 seconds, then click **Open**.

You are now looking at a Firefox running inside a container. In its address bar,
type:

```
https://172.31.90.10/
```

You will get a **certificate warning** — accept it. That is the fake camera's
self-signed certificate, exactly like a real one. You should then see a camera
page.

**Stop and think about what just happened.** Your laptop's browser never talked
to that camera. It talked to Traefik, which talked to a containerised Firefox,
which reached the camera through a WireGuard tunnel that did not exist ten
seconds ago.

---

## 4. See it with your own eyes

Each of these is a thing you can check yourself rather than take on faith.

### The browser has no network of its own

```bash
docker inspect sb-customer2-browser -f '{{.HostConfig.NetworkMode}}'
docker inspect sb-customer2-browser -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

The first prints `container:<id>` — it is living inside the VPN container's
network. The second prints **nothing at all**, because it has no address of its
own. This is the isolation guarantee, and it is one line of compose.

### The tunnel is the only way in

```bash
# with the tunnel up
docker exec sb-customer2-vpn curl -sk -o /dev/null -w '%{http_code}\n' https://172.31.90.10/
# → 200

# take the tunnel down
docker exec sb-customer2-vpn wg-quick down wg0
docker exec sb-customer2-vpn curl -sk --max-time 5 https://172.31.90.10/
# → hangs, then fails. The camera is gone.

# bring it back
docker exec sb-customer2-vpn wg-quick up wg0
```

Refresh the Firefox tab while the tunnel is down — the camera is unreachable
there too, because the browser shares that network.

### Only the customer's subnet goes over the tunnel

```bash
docker exec sb-customer2-vpn ip route
```

```
default via 172.24.0.1 dev eth0          ← normal traffic, not the tunnel
172.31.90.0/24 dev wg0 scope link        ← only the customer's LAN
```

A session can reach that one customer and nothing else. There is no default
route into their network.

### The session is not on the customer's network

```bash
docker inspect sb-customer2-vpn -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# → sb_sessions sb_transit        (never sb_customer_lan)
```

### Two customers cannot see each other

```bash
docker exec sb-broker true 2>/dev/null   # start customer7 from the console too
docker exec sb-customer2-vpn ping -c1 -W2 10.13.13.3   # customer7's tunnel address
# → fails
```

### Nothing survives

```bash
./scripts/session-down.sh customer2
docker ps -a | grep customer2      # → nothing
```

The containers are gone, the tunnel is gone, the credentials that were inside
them are gone.

### Every action is on the record

```bash
cat broker/audit.log
```

```
2026-08-18T12:22:29+00:00  stop   customer2  ok
2026-08-18T12:22:35+00:00  start  customer7  ok
```

---

## 5. Useful commands

```bash
./scripts/lab-up.sh                  # start everything
./scripts/session-up.sh customer2    # start one session (what the button calls)
./scripts/session-down.sh customer2  # destroy it
./scripts/lab-down.sh                # remove everything, including volumes

docker logs sb-customer2-vpn         # tunnel bring-up and routes
docker exec sb-customer2-vpn wg show # handshake, transfer counters
```

Traefik's dashboard is at <http://localhost:8089/> if you want to watch routers
appear and disappear as sessions start and stop.

### Adding a third fake customer

1. Add the id to `PEERS` in `docker-compose.lab.yml`
2. `docker compose -f docker-compose.lab.yml up -d --force-recreate wg-server`
3. Add an entry to `broker/customers.yml`
4. It appears in the console

---

## 6. What the lab already taught us

Two things that were **not** obvious until it ran:

**The Traefik labels belong on the VPN container, not the browser.** The browser
has no network stack, so Docker gives it no IP and Traefik cannot route to it at
all. The container that owns the namespace is the one that is routable, so it
carries the routing labels and points at the port the browser is listening on
inside that namespace. See the comment in `session/docker-compose.session.yml`.

**Each customer needs its own VPN identity.** The first version of this lab gave
every session the same peer config. The first session worked, the second came up
with a tunnel and *no peer* — because a WireGuard server tracks one endpoint per
public key, so the newer handshake silently steals the older session's tunnel.
It fails quietly, which is the worst way to fail. One credential per customer,
always.

---

## 7. Taking this to real customers

The session half needs **no changes at all**. What changes is where the tunnel
terminates, and what sits in front of the console.

### What stays exactly the same

- The session pair (`vpn` + `browser`) and `network_mode: service:vpn`
- Traefik labels on the VPN container
- The broker's start/stop/audit logic
- One credential per customer

### What must change before a real customer

**1. The credentials come from Infisical, not a file.**
The lab writes `session/conf/<customer>.conf` to disk. In production the broker
fetches that customer's config from Infisical when the session starts, passes it
in memory, and it dies with the container. Nothing lands on disk.

**2. Authentication in front of the console.**
Right now anyone who can reach `console.localhost:8088` can open a tunnel into
any customer. In production the broker sits behind Traefik forward-auth with
Authentik or Authelia, and MFA is mandatory. **The broker is the most
security-critical thing you will run** — it can reach every customer network you
serve. Do this before it ever holds a real credential.

**3. A reaper.**
The lab leaves sessions running forever. Production needs an idle timeout and a
hard maximum lifetime, because a forgotten session is a standing tunnel into a
customer's network — the exact thing this design exists to prevent.

**4. Real names and real certificates.**
`console.localhost` becomes `console.ambos-security.com` with a proper
certificate. Sessions can stay on internal names since only staff reach them.

**5. The customer's VPN, not ours.**
This is the one real unknown. The lab uses WireGuard on both ends because we
control both ends. At a real customer it is whatever their firewall speaks:

| Situation | What it means |
|---|---|
| Customer runs WireGuard | Drop their config in. Nothing changes. |
| Customer runs OpenVPN / IPsec | The `vpn` image needs that client too. One image, several clients, chosen per customer. |
| Customer runs a vendor VPN (Fortinet, SonicWall…) | May need a vendor client, sometimes a licence. Check before promising. |
| Customer refuses any access | We place a small box that dials out to us on demand. Same WireGuard everywhere, one code path. |

Decide this early: it is the difference between "add a customer" being a config
entry and being a project.

**6. Where it runs.**
Not the NAS — 2 GB of RAM, and one session with a browser needs most of that.
Three concurrent sessions want roughly 8 GB. Whatever host you choose must be
always-on, because a support tool that is asleep when a customer calls is not a
support tool.

### A realistic rollout

1. Run this lab until the workflow feels right.
2. Put Authentik in front of the broker. Do not skip ahead.
3. Move credentials into Infisical.
4. Add the reaper and keep the audit log somewhere you would actually read.
5. Pilot with **one** friendly customer over WireGuard — ideally a site that
   already has one of our robots, since the tunnel exists there already.
6. Only then take on customers whose VPN we do not control.

---

## 8. Where the pieces live

```
session-broker/
├── docker-compose.console.yml   # OUR side: Traefik + broker
├── docker-compose.lab.yml       # the fake customer: VPN endpoint + camera
├── session/
│   ├── docker-compose.session.yml   # the session pair — read this one
│   └── vpn/                         # WireGuard client image
├── broker/
│   ├── app.py                   # the console: list, start, stop, audit
│   └── customers.yml            # the customer register
├── lab/camera/                  # the fake camera
└── scripts/                     # what the buttons actually call
```

The file worth reading first is `session/docker-compose.session.yml`. It is
about forty lines and it contains the entire idea.
