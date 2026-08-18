# session-broker

A working lab for **on-demand support sessions**: a customer calls, an engineer
clicks one button, a disposable container dials into that customer's network and
hands over a browser, and everything is destroyed when the call ends.

Runs entirely on your machine. Touches nothing belonging to the company.

```bash
cp .env.example .env
./scripts/hosts-entries.sh   # prints the one sudo command you need
./scripts/lab-up.sh
./scripts/auth-up.sh          # login layer (first boot takes ~3 min)
open http://console.sb.test:8088/
```

**→ [docs/session-lab-walkthrough.html](docs/session-lab-walkthrough.html)** — illustrated: every container, what it represents in real life, and how the pieces connect.

**→ Read [LAB-GUIDE.md](LAB-GUIDE.md)** — what to click, what to check with your
own eyes, and what has to change before a real customer.

## What is real and what is pretend

Pretend: the camera, the customer LAN, their VPN endpoint, the internet between us.

Real, and unchanged in production: the session pair (`vpn` + `browser`), the
`network_mode: service:vpn` isolation, the Traefik routing, the broker's
start/stop/audit logic.

## Status

| Piece | State |
|---|---|
| Session pair, tunnel, isolation | Working, verified |
| Traefik routing per session | Working |
| Broker console: list / connect / stop / audit | Working |
| Authentik in front of the console | Working — login enforced, MFA available |
| Auth on session URLs | **Not built** — needs a real domain, see LAB-GUIDE §4b |
| Credentials from Infisical | **Not built** — lab uses files |
| Device names via per-customer JSON registry | Working — no hosts files anywhere |
| Idle reaper | **Not built** |
