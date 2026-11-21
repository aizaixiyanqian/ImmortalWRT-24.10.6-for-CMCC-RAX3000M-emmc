#!/bin/sh
# agh-supervisor.sh - keeps DNS answering even when AdGuardHome dies or hangs.
#
# AdGuardHome is run as a child of this script.  The moment it exits (or stops
# answering DNS), an nft rule redirects dnsmasq's queries to 127.0.0.1:3053
# towards 127.0.0.1:6053 (SmartDNS), so dnsmasq keeps getting answers in
# milliseconds instead of waiting for its retry timeout.  When AdGuardHome is
# answering again the redirect is removed and ad-blocking resumes.
#
# The redirect matches only dnsmasq's uid: the readiness probe below must still
# reach AdGuardHome itself, otherwise it would only ever see SmartDNS.
#
# Started by /etc/init.d/agh-boot (procd, respawn).

PROG=/usr/bin/AdGuardHome
CONF=/etc/AdGuardHome.yaml
WORK=/etc/AdGuardHome
WEBPORT=3000
LOG=/tmp/agh-supervisor.log
DNSMASQ_UID=$(id -u dnsmasq 2>/dev/null)
[ -z "$DNSMASQ_UID" ] && DNSMASQ_UID=453

log() {
	echo "$(date '+%F %T') $*" >> "$LOG"
	logger -t agh-supervisor "$*" 2>/dev/null
	if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
		tail -c 32768 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
	fi
}

port_listen() {
	_hex=$(printf '%04X' "$1")
	awk -v p="$_hex" 'toupper($2) ~ ":" p "$" && $4 == "0A" { f = 1 } END { exit(f ? 0 : 1) }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

nft_init() {
	nft list table inet aghguard >/dev/null 2>&1 && return 0
	nft add table inet aghguard
	nft add chain inet aghguard out '{ type nat hook output priority -100 ; }'
}

# dnsmasq's queries to 127.0.0.1:3053 are silently steered to SmartDNS while
# AdGuardHome is down.  Other processes (root probes) are not affected.
redirect_on() {
	nft_init
	if nft list chain inet aghguard out 2>/dev/null | grep -q 'dport 3053'; then
		return 0
	fi
	nft add rule inet aghguard out meta skuid "$DNSMASQ_UID" ip daddr 127.0.0.1 udp dport 3053 redirect to :6053
	nft add rule inet aghguard out meta skuid "$DNSMASQ_UID" ip daddr 127.0.0.1 tcp dport 3053 redirect to :6053
	log "AdGuardHome down: DNS 3053 -> 6053 (SmartDNS), no client-side stall"
}

redirect_off() {
	nft flush chain inet aghguard out 2>/dev/null
}

PID=""
on_term() {
	[ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null
	[ -n "$PID" ] && wait "$PID" 2>/dev/null
	# keep the redirect: with AGH intentionally stopped DNS must still work
	redirect_on
	log "supervisor stopped (AGH left stopped, DNS served by SmartDNS)"
	exit 0
}
trap on_term TERM INT

log "supervisor started"
fail=0

while :; do
	# While AGH is starting, DNS is served by SmartDNS through the redirect.
	redirect_on

	"$PROG" -c "$CONF" -w "$WORK" -p "$WEBPORT" -l /tmp/AdGuardHome.log &
	PID=$!
	STARTED=$(date +%s)

	# Background watcher:
	#  - drop the redirect only when AGH really answers DNS on 3053
	#  - kill AGH when its DNS stops answering (hung process)
	(
		up=0
		okn=0
		bad=0
		i=0
		while [ "$i" -lt 600 ]; do
			sleep 1
			i=$((i + 1))
			kill -0 "$PID" 2>/dev/null || exit 1
			if port_listen 3053 && timeout 1 lua /usr/bin/dnsprobe.lua 3053 >/dev/null 2>&1; then
				bad=0
				if [ "$up" = 0 ]; then
					redirect_off
					up=1
					log "AdGuardHome ready on 3053: DNS back to AGH (ad-blocking on)"
				fi
			else
				okn=0
				if [ "$up" = 1 ]; then
					# confirm with a second probe before killing (about 2 s)
					if ! (port_listen 3053 && timeout 1 lua /usr/bin/dnsprobe.lua 3053 >/dev/null 2>&1); then
						log "AdGuardHome not answering DNS: killing it for failover"
						kill -9 "$PID" 2>/dev/null
						exit 0
					fi
				elif [ "$i" -gt 90 ]; then
					log "AdGuardHome did not become ready in 90s: restarting"
					kill -9 "$PID" 2>/dev/null
					exit 0
				fi
			fi
		done
	) &
	WATCHER=$!

	wait "$PID"
	RC=$?
	kill "$WATCHER" 2>/dev/null
	wait "$WATCHER" 2>/dev/null
	PID=""

	# AGH exited: redirect first, then look at restart backoff.
	redirect_on
	UP=$(( $(date +%s) - STARTED ))
	# a run longer than a minute counts as healthy: reset the backoff
	[ "$UP" -ge 60 ] && fail=0
	fail=$((fail + 1))
	log "AdGuardHome exited (rc=$RC, ran ${UP}s), restart #$fail"

	if [ "$fail" -le 2 ]; then
		delay=1
	elif [ "$fail" -le 4 ]; then
		delay=5
	elif [ "$fail" -le 8 ]; then
		delay=15
	else
		delay=60
	fi
	sleep "$delay"
done
