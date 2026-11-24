#!/usr/bin/env bash
# Phase 2 live demos, run on the CLIENT Mac (Mac 3). The script does every
# check itself and pauses only when another Mac has to run one command.
# Output is saved in evidence/failures/.
#
#   bash scripts/failover-demo.sh dns        Ext A: primary DNS dies, backup answers
#   bash scripts/failover-demo.sh backend    Ext D: Backend A dies, users see no errors
#   bash scripts/failover-demo.sh all        both, one after the other
#
# Needs: Mac 1 primary DNS running, Mac 2 edge + Backend A + backup DNS running,
# Mac 3 Backend B running and the team CA trusted.
set -uo pipefail
source "$(dirname "$0")/common.sh"
curl_tls_args

BACKUP_DNS_IP="${BACKUP_DNS_IP:-$MAC2_IP}"     # backup dnsmasq runs on Mac 2

pause() { printf '\n%s>>> %s%s\n' "$c_yel" "$*" "$c_off"; read -r -p "    press Enter when done... " _; }
step()  { printf '\n%s--- %s%s\n' "$c_bold" "$*" "$c_off"; }
ask()   { dig +short +time=2 +tries=1 "@$1" "app.${DOMAIN}" 2>&1 | sed 's/^/    /'; }
hits()  {   # n requests, one per second: prints which backend answered and the HTTP code
  local n="$1" i code be
  for i in $(seq 1 "$n"); do
    read -r code be < <(curl -sS "${CURL_TLS[@]}" --max-time 5 -o /dev/null -D - -w '' "$APP_URL/api/status" 2>/dev/null \
      | tr -d '\r' | awk -F': ' '/^HTTP/{split($0,a," "); code=a[2]} tolower($1)=="x-backend"{b=$2} END{print (code?code:"000"), (b?b:"-")}')
    printf '    %s  request %2d -> HTTP %s  X-Backend: %s\n' "$(date +%T)" "$i" "$code" "$be"
    sleep 1
  done
}
record() { local f="$EVID/failures/$1-$(host_tag)-$(stamp).txt"; { echo "# $1 - on $(host_tag) - $(date)"; "$2"; } 2>&1 | tee "$f"; ok "saved $f"; }

demo_dns() {
  say "Ext A  DNS failover: the primary DNS dies, the backup answers"
  step "Both DNS servers give the same answer"
  echo "  primary ${MAC1_IP}:"; ask "$MAC1_IP"
  echo "  backup  ${BACKUP_DNS_IP}:"; ask "$BACKUP_DNS_IP"

  step "This client uses both servers, primary first"
  if is_mac; then
    svc="$(mac_service_for_iface "$(default_iface)")"; svc="${svc:-Wi-Fi}"
    run sudo networksetup -setdnsservers "$svc" "$MAC1_IP" "$BACKUP_DNS_IP"
    scutil --dns | grep nameserver | head -4 | sed 's/^/    /'
  fi

  pause "On ${DNS_MAC:-Mac 1} run:   bash scripts/dns.sh stop"

  step "Primary is dead"
  ask "$MAC1_IP"
  step "Flush the cache and resolve again (through the operating system, like a browser)"
  flush_dns_cache
  dscacheutil -q host -a name "app.${DOMAIN}" 2>&1 | sed 's/^/    /'
  step "The site still works"
  hits 4
  echo
  echo "Proof on Mac 2:  tail -5 runtime/dnsmasq.log   -> query[A] app.${DOMAIN} from this Mac"
  echo "WHY: macOS asks the first DNS server; when it does not answer it asks the next one."
  echo "     Two servers with the same records remove DNS as a single point of failure."

  pause "On ${DNS_MAC:-Mac 1} run:   bash scripts/dns.sh start"
  step "Primary is back"
  ask "$MAC1_IP"
}

demo_backend() {
  say "Ext D  Backend failover: Backend A dies, users see no errors"
  step "Normal: round robin A, B, A, B"
  hits 4

  pause "On ${A_MAC:-Mac 2} run:   bash scripts/backend.sh stop A"

  step "Backend A is down: every request still succeeds, all from B"
  hits 8
  echo
  echo "Proof on Mac 2:  tail -8 runtime/logs/nginx-access.log"
  echo "                 look for  upstream=${MAC3_IP}:${BACKEND_A_PORT}, ${MAC4_IP}:${BACKEND_B_PORT} upstream_status=502, 200"
  echo "WHY: nginx gets an error from A, retries the SAME request on B (proxy_next_upstream)"
  echo "     and keeps A out of the pool for fail_timeout=10s. The user only sees the 200."

  pause "On ${A_MAC:-Mac 2} run:   bash scripts/backend.sh start A"
  step "Waiting 10 s (fail_timeout), then round robin is back"
  sleep 10
  hits 4
}

case "${1:-}" in
  dns)     record "P2-A-dns-failover" demo_dns ;;
  backend) record "P2-D-backend-failover" demo_backend ;;
  all)     record "P2-A-dns-failover" demo_dns; record "P2-D-backend-failover" demo_backend ;;
  *)       sed -n '2,12p' "$0"; exit 1 ;;
esac
