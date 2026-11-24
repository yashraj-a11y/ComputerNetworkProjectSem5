# Phase 2: resilience extensions (A–F)

Team **teamX**, domain **`app.teamx.test`**, 3 Macs on the same college Wi-Fi (24 Nov 2026).
Step-by-step commands: [PHASE2-RUNBOOK.md](PHASE2-RUNBOOK.md). Screenshots: `evidence/Phase-2-screenshot/`.

## Setup

| | Mac 1 | Mac 2 | Mac 3 |
|---|---|---|---|
| Member | Yash Raj | Aditya | Yash Yadav |
| IP | 10.7.26.168 | 10.7.29.157 | 10.7.4.107 |
| Role | primary DNS (dnsmasq) | primary edge (nginx, TLS, LB) + Backend A :3001 + backup DNS | Backend B :3002 + test client + standby edge |

`team.env`: `MAC1_IP`=10.7.26.168 (DNS), `MAC2_IP`=10.7.29.157 (edge), `MAC3_IP`=10.7.29.157 (A), `MAC4_IP`=10.7.4.107 (B), `WRONG_IP`=10.7.4.107 (standby edge, used as the cutover target).

### Why the edge is on Mac 2, not Mac 1
The runbook puts the primary edge on Mac 1. On Mac 1, nginx started and `nc -vz 10.7.26.168 443` **succeeded**, but every HTTPS request from another Mac failed. `curl -v` showed `LibreSSL SSL_connect: SSL_ERROR_SYSCALL`, and nginx's error log showed `recv() failed (57: Socket is not connected) while SSL handshaking`. The cause was Mac 1's **macOS Application Firewall**, which listed nginx as *Block incoming connections*. Mac 1 is a managed Mac, so `socketfilterfw` refused the change (*"Firewall settings cannot be modified from command line on managed Mac computers"*). We didn't try to get around the managed policy. We moved the edge to Mac 2 and the standby edge to Mac 3.

This was also a useful layer-by-layer lesson. TCP (layer 3 in our table) passed, and the failure only showed up at TLS, because a host firewall can cut a connection after the handshake.

---

## A: backup DNS on Mac 2

**Why:** with one DNS server, losing Mac 1 means no client can find `app.teamx.test`, even though the site is fine.

**How:** Mac 2 runs a second dnsmasq from a copy of `team.env` where `MAC1_IP` is Mac 2 (`team-backup.env`). It serves the same records. The client Mac 3 is given both servers: `networksetup -setdnsservers Wi-Fi 10.7.26.168 10.7.29.157`.

**Result:**
- Both servers answered `app.teamx.test → 10.7.29.157` ([A1](../evidence/Phase-2-screenshot/phase_2-3/p2-A1-both-dns-answer1.png)). Mac 3's resolver listed both nameservers ([A2](../evidence/Phase-2-screenshot/phase_2-3/p2-A2-client-two-dns-servers.png)).
- We stopped Mac 1's dnsmasq. `dig @10.7.26.168` then **timed out**, while `dig @10.7.29.157` still answered `10.7.29.157`.
- After flushing its cache, Mac 3 still resolved `app.teamx.test` to 10.7.29.157 and loaded the site A B A B ([A3](../evidence/Phase-2-screenshot/phase_2-3/p2-A3-failover-still-resolves.png)).
- The backup's log shows `query[A] app.teamx.test from 10.7.4.107` ([A4](../evidence/Phase-2-screenshot/phase2-2/p2-A4-backup-dns-log.png)).

**Explanation:** macOS asks the first DNS server, and if it doesn't answer in time, it moves on to the next. Two servers remove DNS as a single point of failure.

## B: TTL 30 and a record change

**Why:** a DNS change only reaches clients after their cached answer expires, so the TTL decides how fast a change propagates.

**How:** we set `DNS_TTL=30` on both DNS servers. `dig` showed `app.teamx.test. 30 IN A 10.7.29.157` ([B1](../evidence/Phase-2-screenshot/phase_2-3/p2-B1-ttl-30.png)). Mac 3 polled the OS cache (`dscacheutil`, not `dig`, which skips the cache) every 5 s. We then ran `dns.sh wrong-record` on Mac 1 to point `app` at 10.7.4.107.

**Result** ([B2](../evidence/Phase-2-screenshot/phase_2-3/p2-B2-record-change-propagates.png)):

| Event | Time |
|---|---|
| Record changed on Mac 1 | ~11:16:10 (server answered 10.7.4.107 at 11:16:13) |
| Last answer `10.7.29.157` on Mac 3 | 11:16:21 |
| First answer `10.7.4.107` on Mac 3 | 11:16:26 |

The change reached the client about **16 s** after it was made, which is within one TTL (30 s).

**Explanation:** a short TTL means changes reach clients fast but generates more DNS queries. A long TTL means fewer queries, but changes are slow to arrive.

## C: pf firewall, backends reachable only through nginx

**Why:** if clients can reach a backend directly, they skip TLS, load balancing and logging on the edge.

**How:** on each backend Mac, we put rules in our own pf anchor `com.apple/cn-phase2`, which `/etc/pf.conf` already loads, so no system file was edited:
```
pass in quick on en0 proto tcp from 10.7.29.157 to any port 3001     (Mac 2; port 3002 on Mac 3)
block drop in quick on en0 proto tcp from any to any port 3001
```
Then `sudo pfctl -E`, which returns a token, followed by `sudo pfctl -a com.apple/cn-phase2 -sr` to show the rules.

**Result:**
- Before the rules: Mac 3 → `http://10.7.29.157:3001/` returned `Backend A` ([C0](../evidence/Phase-2-screenshot/phase_2-3/p2-C0-direct-access-before.png)).
- Rules loaded on Mac 2 ([C1](../evidence/Phase-2-screenshot/phase2-2/p2-C1-memberA-pf-rules.png)) and Mac 3 ([C2](../evidence/Phase-2-screenshot/phase_2-3/p2-C2-memberB-pf-rules.png)).
- After the rules: Mac 3 → `curl -m 3 http://10.7.29.157:3001/` returned **`curl: (28) Connection timed out after 3006 milliseconds`**, while `https://app.teamx.test/` still returned A B A B ([C3](../evidence/Phase-2-screenshot/phase_2-3/p2-C3-direct-blocked-site-works.png)).
- Rollback: `pfctl -a com.apple/cn-phase2 -F all` and `pfctl -X <token>` printed `pf disabled` ([C4](../evidence/Phase-2-screenshot/phase2-2/p2-C4-pf-rollback.png), [C4 Mac 3](../evidence/Phase-2-screenshot/phase_2-3/p2-C4-pf-rollback-1.png)). After that, Mac 1 could reach :3001 and :3002 directly again.

**Explanation:** `block drop` silently throws away the SYN, so the client waits for a timeout. `block return` would send a RST, which gives "connection refused" straight away. `pfctl -E` hands out a reference token, and `-X <token>` releases only ours.

## D: a dead backend causes no user errors

**Why:** a backend can crash at any time, and users shouldn't see an error when it does.

**How:** no config change was needed. The Phase 1 nginx config already has `max_fails=1 fail_timeout=10s` on each upstream, plus `proxy_next_upstream error timeout http_502 http_503 http_504`. Mac 3 sent one request per second while Mac 2 stopped Backend A.

**Result:**
- Mac 3's loop showed only `Backend B`, with no errors and no blank lines ([D1](../evidence/Phase-2-screenshot/phase_2-3/p2-D1-only-B-no-errors.png)).
- nginx access log on Mac 2 ([D2](../evidence/Phase-2-screenshot/phase2-2/p2-D2-nginx-log-failover.png)):
  ```
  24/Nov/2026:11:21:53 +0530 10.7.4.107:51806 -> 10.7.29.157:443 "GET / HTTP/2.0" 200 ...
      upstream=10.7.29.157:3001, 10.7.4.107:3002 upstream_status=502, 200 rt=0.044
  ```
  nginx tried A, which failed, retried B **within the same request**, and the user got a 200. The following requests went straight to B (`upstream_status=200`).
- After Backend A was restarted, the loop went back to alternating A/B within about 10 s ([D3](../evidence/Phase-2-screenshot/phase_2-3/p2-D3-A-back.png)).

**Explanation:** `max_fails=1 fail_timeout=10s` means one failure marks a backend down for 10 s. `proxy_next_upstream` retries the other backend, so the failure never reaches the user.

## E: standby edge on Mac 3 and DNS cutover

**Why:** with every backend redundant, nginx itself becomes the single point of failure.

**How:** Mac 3 got the same `server.key` and `server-chain.crt` as Mac 2, so the switch causes no certificate warning. Its `X-Edge` header was set to `standby-nginx`, and it started a second nginx. Checking it directly with `curl --resolve app.teamx.test:443:10.7.4.107` returned `x-edge: standby-nginx` from both Mac 2 and Mac 3 ([E1](../evidence/Phase-2-screenshot/phase_2-3/p2-E1-standby-ready-1.png), [E1 from Mac 2](../evidence/Phase-2-screenshot/phase2-2/p2-E1-standby-ready-2.png)). Mac 3 then polled `X-Edge` every 3 s. Next, Mac 2 stopped its nginx, and both DNS servers ran `wrong-record`, pointing `app` at 10.7.4.107.

**Result** ([E2](../evidence/Phase-2-screenshot/phase_2-3/p2-E2-cutover-to-standby.png)):

| Phase | Time |
|---|---|
| Last `x-edge: mac2-nginx` | 11:33:24 |
| No answer (edge dead, old DNS answer still cached) | 11:33:27 – 11:33:47 |
| First `x-edge: standby-nginx` | 11:33:51 |

The downtime was **27 s**, which is under the 30 s TTL. Both DNS servers answered 10.7.4.107 by 11:33:54.

**Explanation:** the downtime is capped by the TTL (30 s). It's usually shorter, because the cached answer is already partway through its TTL. A real setup would automate the switch with keepalived/VRRP (a shared virtual IP) or health-checked DNS.

## F: live fault diagnosis (viva)

Work from Mac 3, going up the stack, and stop at the first layer that fails.

| Layer | Command | Healthy | If it fails |
|---|---|---|---|
| 1. DNS | `dscacheutil -q host -a name app.teamx.test` / `dig app.teamx.test` | 10.7.29.157 | Wrong IP = bad record. No answer = dnsmasq down, or the client's DNS list is wrong (`scutil --dns`, VPN). |
| 2. IP | `ping -c 3 10.7.29.157` | 0% loss | Wi-Fi problem, or the IP changed (DHCP). |
| 3. TCP | `nc -vz 10.7.29.157 443` (and `10.7.29.157 3001`, `10.7.4.107 3002`) | succeeded | Refused = service down or wrong port. Timeout = firewall (pf `block drop`). |
| 4. TLS | `curl -v https://app.teamx.test/` | `SSL certificate verify ok` | CA not trusted, wrong name, expired cert. `SSL_ERROR_SYSCALL` after a good TCP connect = host firewall (our Mac 1 case). |
| 5. App | `curl -s -o /dev/null -w "%{http_code}" https://app.teamx.test/` + `tail runtime/logs/nginx-access.log` on Mac 2 | 200, `upstream_status=200` | 502/504 = backend(s) down; read `upstream=`. |

Practise with `bash scripts/failure-demo.sh all`.
