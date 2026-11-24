# Phase 2 runbook: filled in for teamx

This is the Cn2.pdf runbook with our real values. Run every command from inside the project folder, one block at a time.

**Role change from the PDF:** Mac 1 is a managed Mac, and its firewall blocks incoming connections to nginx (it can't be changed from the command line). So the **primary edge moved to Mac 2 (Aditya)**, and the **standby edge is on Mac 3 (Yash Yadav)**. Mac 1 keeps the primary DNS.

| | Mac 1 | Mac 2 | Mac 3 |
|---|---|---|---|
| Person | **Yash Raj** | **Aditya** | **Yash Yadav** |
| IP | **10.7.26.168** (IP1) | **10.7.29.157** (IP2) | **10.7.4.107** (IP3) |
| Phase 2 role | primary DNS | primary edge (nginx) + Backend A :3001 + backup DNS | Backend B :3002 + test client + standby edge |

Domain: **`app.teamx.test`**. `team.env`: MAC1=IP1 (DNS), MAC2=IP2 (edge), MAC3=IP2 (A), MAC4=IP3 (B), WRONG_IP=IP3 (standby edge). It must be the same file on all three Macs.

Screenshots are in `evidence/Phase-2-screenshot/` (phase2-2 = Mac 2, phase_2-3 = Mac 3).

---

## Step 0: bring Phase 1 back up

**0.1, Mac 1:** stop the blocked nginx, AirDrop the new `team.env` to Mac 2 and Mac 3, and AirDrop `tls/out/ca.crt`, `tls/out/server.key`, `tls/out/server-chain.crt` to **Mac 2 and Mac 3** (they're both edges). Then restart DNS so `app` points at Mac 2:
```bash
bash scripts/edge.sh stop
```
```bash
open tls/out
```
```bash
bash scripts/dns.sh restart
```

**0.2, Mac 2 and Mac 3:** move the files in:
```bash
mv ~/Downloads/team.env team.env
```
```bash
mv ~/Downloads/ca.crt ~/Downloads/server.key ~/Downloads/server-chain.crt tls/out/
```

**0.3, Mac 2:** start the edge (Backend A should already be running):
```bash
bash scripts/backend.sh start A
```
```bash
bash scripts/edge.sh start
```
```bash
bash scripts/edge.sh status
```

**0.4, Mac 3:**
```bash
bash scripts/backend.sh start B
```

**0.5, Mac 3:** use our DNS and trust the CA (fingerprint `91:53:28:89:81:DE … 86:A4:51:25`):
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.26.168
```
```bash
bash scripts/trust-ca.sh remove
```
```bash
bash scripts/trust-ca.sh
```

**0.6, Mac 3:** check every layer → want 0% loss, succeeded, `10.7.29.157`, then A B A B:
```bash
ping -c 3 10.7.29.157
```
```bash
nc -vz 10.7.29.157 443
```
```bash
dig @10.7.26.168 app.teamx.test +short
```
```bash
for i in 1 2 3 4; do curl -s https://app.teamx.test/ | grep -o "<h1>Backend [AB]" | sed 's/<h1>//'; done
```

---

## Step 1, Extension A: backup DNS on Mac 2

**1.1, Mac 2**
```bash
sed 's/^MAC1_IP=.*/MAC1_IP="10.7.29.157"/' team.env > team-backup.env
```
```bash
TEAM_ENV=$PWD/team-backup.env bash scripts/dns.sh start
```
**1.2, Mac 3** → screenshot `p2-A1-both-dns-answer` (both print 10.7.29.157)
```bash
dig @10.7.26.168 app.teamx.test +short
```
```bash
dig @10.7.29.157 app.teamx.test +short
```
**1.3, Mac 3** → screenshot `p2-A2-client-two-dns-servers`
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.26.168 10.7.29.157
```
```bash
scutil --dns | grep nameserver | head -4
```
**1.4, Mac 1**
```bash
bash scripts/dns.sh stop
```
**1.5, Mac 3** → screenshot `p2-A3-failover-still-resolves`
```bash
sudo dscacheutil -flushcache
```
```bash
sudo killall -HUP mDNSResponder
```
```bash
dscacheutil -q host -a name app.teamx.test
```
```bash
for i in 1 2 3 4; do curl -s https://app.teamx.test/ | grep -o "<h1>Backend [AB]" | sed 's/<h1>//'; done
```
**1.6, Mac 2** → screenshot `p2-A4-backup-dns-log` (shows `query[A] app.teamx.test from 10.7.4.107`)
```bash
tail -5 runtime/dnsmasq.log
```
**1.7, Mac 1**
```bash
bash scripts/dns.sh start
```

---

## Step 2, Extension B: TTL 30 and a record change

**2.1, Mac 1**
```bash
sed -i '' 's/^DNS_TTL=.*/DNS_TTL=30/' team.env
```
```bash
bash scripts/dns.sh restart
```
**2.2, Mac 2**
```bash
sed -i '' 's/^DNS_TTL=.*/DNS_TTL=30/' team-backup.env
```
```bash
TEAM_ENV=$PWD/team-backup.env bash scripts/dns.sh restart
```
**2.3, Mac 3** → screenshot `p2-B1-ttl-30`
```bash
dig @10.7.26.168 app.teamx.test | grep "IN.*A"
```
**2.4, Mac 3** (leave running)
```bash
while true; do date +%T; dscacheutil -q host -a name app.teamx.test | grep ip; sleep 5; done
```
**2.5, Mac 1** → Mac 3 screenshots the flip 10.7.29.157 → 10.7.4.107: `p2-B2-record-change-propagates`
```bash
bash scripts/dns.sh wrong-record
```
**2.6:** Mac 3 presses Ctrl+C. Mac 1:
```bash
bash scripts/dns.sh fix
```

---

## Step 3, Extension D: backend failover

**3.1, Mac 3** (leave running; wait for A/B)
```bash
while true; do curl -s https://app.teamx.test/ | grep -o "<h1>Backend [AB]" | sed 's/<h1>//'; sleep 1; done
```
**3.2, Mac 2** → Mac 3 screenshot `p2-D1-only-B-no-errors`
```bash
bash scripts/backend.sh stop A
```
**3.3, Mac 2** (the edge is here) → screenshot `p2-D2-nginx-log-failover` (`upstream=10.7.29.157:3001, 10.7.4.107:3002 upstream_status=502, 200`)
```bash
tail -8 runtime/logs/nginx-access.log
```
**3.4, Mac 2** → Mac 3 screenshot `p2-D3-A-back`, then Ctrl+C
```bash
bash scripts/backend.sh start A
```

---

## Step 4, Extension E: standby edge on Mac 3 + DNS cutover

**4.1, Mac 3:** mark the standby and start it (the cert files came in 0.2):
```bash
sed -i '' 's/mac2-nginx/standby-nginx/' edge/nginx.conf.template
```
```bash
bash scripts/edge.sh start
```
**4.2, Mac 3** → screenshot `p2-E1-standby-ready` (shows `standby-nginx`)
```bash
curl -sI --resolve app.teamx.test:443:10.7.4.107 https://app.teamx.test/ | grep -i x-edge
```
**4.3, Mac 3** (leave running; wait for `mac2-nginx` lines)
```bash
while true; do date +%T; curl -sI https://app.teamx.test/ | grep -i x-edge; sleep 3; done
```
**4.4, Mac 2:** the primary edge dies, and the backup DNS points at Mac 3:
```bash
bash scripts/edge.sh stop
```
```bash
TEAM_ENV=$PWD/team-backup.env bash scripts/dns.sh wrong-record
```
**4.5, Mac 1:** same cutover on the primary DNS. → Mac 3 screenshot `p2-E2-cutover-to-standby` (mac2-nginx → blanks → standby-nginx; note the gap)
```bash
bash scripts/dns.sh wrong-record
```
**4.6, undo.** Mac 3: Ctrl+C. Mac 1:
```bash
bash scripts/dns.sh fix
```
Mac 2:
```bash
TEAM_ENV=$PWD/team-backup.env bash scripts/dns.sh fix
```
```bash
bash scripts/edge.sh start
```
Mac 3:
```bash
bash scripts/edge.sh stop
```
```bash
sed -i '' 's/standby-nginx/mac2-nginx/' edge/nginx.conf.template
```

---

## Step 5, Extension C: pf firewall (after Step 4 is undone)

The backends accept connections only from the edge (Mac 2, 10.7.29.157).

**5.0, Mac 3** → screenshot `p2-C0-direct-access-before`
```bash
curl -m 3 -s http://10.7.29.157:3001/ | grep -o "<h1>Backend A" | sed 's/<h1>//'
```
**5.1, Mac 2 (Backend A)** → screenshot `p2-C1-memberA-pf-rules`; write down the Token
```bash
printf "pass in quick on en0 proto tcp from 10.7.29.157 to any port 3001\nblock drop in quick on en0 proto tcp from any to any port 3001\n" | sudo pfctl -a com.apple/cn-phase2 -f -
```
```bash
sudo pfctl -E
```
```bash
sudo pfctl -a com.apple/cn-phase2 -sr
```
**5.2, Mac 3 (Backend B)** → screenshot `p2-C2-memberB-pf-rules`; write down the Token
```bash
printf "pass in quick on en0 proto tcp from 10.7.29.157 to any port 3002\nblock drop in quick on en0 proto tcp from any to any port 3002\n" | sudo pfctl -a com.apple/cn-phase2 -f -
```
```bash
sudo pfctl -E
```
```bash
sudo pfctl -a com.apple/cn-phase2 -sr
```
**5.3, Mac 3** → screenshot `p2-C3-direct-blocked-site-works` (first times out, then A B A B)
```bash
curl -m 3 http://10.7.29.157:3001/
```
```bash
for i in 1 2 3 4; do curl -s https://app.teamx.test/ | grep -o "<h1>Backend [AB]" | sed 's/<h1>//'; done
```
**5.4, Mac 1 (optional):** a non-edge Mac can't reach Backend B either (times out):
```bash
curl -m 3 http://10.7.4.107:3002/
```
**5.5, rollback.** Mac 2 and Mac 3 each run this with their own token → screenshot `p2-C4-pf-rollback`
```bash
sudo pfctl -a com.apple/cn-phase2 -F all
```
```bash
sudo pfctl -X TOKEN
```

---

## Step 6, Extension F (viva): go up the stack from Mac 3

| Layer | Command | Healthy |
|---|---|---|
| DNS | `dscacheutil -q host -a name app.teamx.test` | 10.7.29.157 |
| IP | `ping -c 3 10.7.29.157` | 0% loss |
| TCP | `nc -vz 10.7.29.157 443`, `nc -vz 10.7.29.157 3001`, `nc -vz 10.7.4.107 3002` | succeeded (refused = service down; timeout = firewall) |
| TLS | `curl -v https://app.teamx.test/` | SSL certificate verify ok |
| App | `curl -s -o /dev/null -w "%{http_code}" https://app.teamx.test/` + Mac 2 `tail runtime/logs/nginx-access.log` | 200, upstream_status=200 |

Real example from our setup: Mac 1's managed firewall blocked nginx. `nc` succeeded (TCP OK), but TLS failed with `SSL_ERROR_SYSCALL`. That's a host firewall acting above TCP, and a good viva story.

## Step 7: evidence and git (whoever pushes)
Everyone AirDrops their `p2-*.png` screenshots to the person who pushes; they go in `evidence/Phase-2-screenshot/`. Write `docs/PHASE2.md` and link it from the README, then:
```bash
git add evidence/Phase-2-screenshot docs/PHASE2.md docs/PHASE2-RUNBOOK.md README.md team.env .gitignore
```
Never commit `tls/out/*.key`, `team-backup.env` or `runtime/`.

## When finished
Mac 1 and Mac 3:
```bash
sudo networksetup -setdnsservers Wi-Fi empty
```
