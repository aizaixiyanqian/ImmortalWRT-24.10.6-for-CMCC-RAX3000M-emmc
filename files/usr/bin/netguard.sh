#!/bin/sh
# netguard.sh - keeps the LAN online when PassWall2 / AdGuardHome / SmartDNS /
# OpenAppFilter crash, are stopped, or get stuck.
#
# Started by /etc/init.d/netguard (procd, respawn).  Loops every 10 s.
#
# Design rules
# ------------
# 1. dnsmasq (port 53) is the only resolver the clients see, and its upstream
#    list is STATIC: AGH:3053, SmartDNS:6053, ISP:192.168.1.1 (strict-order).
#    netguard never restarts dnsmasq because that would briefly close port 53.
#    A dead local resolver answers with ICMP "port unreachable", so dnsmasq
#    moves to the next server in ~1 ms - the LAN keeps resolving.
# 2. PassWall2: when its core dies, its nft table is deleted immediately so
#    client traffic falls back to normal routing instead of being redirected
#    into a dead port (that used to blackhole the whole LAN).
# 3. AdGuardHome / SmartDNS / OpenAppFilter are restarted (rate-limited) when
#    their process or listening socket disappears; if repeatedly broken they
#    are left stopped instead of being restarted in a tight loop.
# 4. Services disabled in "System -> Startup" are never resurrected.

INTERVAL=${NETGUARD_INTERVAL:-10}
LOG=/tmp/netguard.log
STATE=/tmp/netguard.state
mkdir -p "$STATE"

log() {
	echo "$(date '+%F %T') $*" >> "$LOG"
	logger -t netguard "$*" 2>/dev/null
	if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
		tail -c 32768 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
	fi
}

now() { date +%s; }

ratelimit() {
	_f="$STATE/$1"
	_now=$(now)
	_last=$(cat "$_f" 2>/dev/null || echo 0)
	if [ $((_now - _last)) -ge "$2" ]; then
		echo "$_now" > "$_f"
		return 0
	fi
	return 1
}

have() { pgrep -f "$1" >/dev/null 2>&1; }

svc_enabled() { ls /etc/rc.d/S[0-9]*"$1" >/dev/null 2>&1; }

# port_listen PORT -> 0 if a socket is in LISTEN state on PORT
port_listen() {
	_hex=$(printf '%04X' "$1")
	awk -v p="$_hex" 'toupper($2) ~ ":" p "$" && $4 == "0A" { f = 1 } END { exit(f ? 0 : 1) }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_pid() {
	_hex=$(printf '%04X' "$1")
	_inode=$(awk -v p="$_hex" 'toupper($2) ~ ":" p "$" && $4 == "0A" { print $10; exit }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null)
	[ -n "$_inode" ] || return 1
	for _f in /proc/[0-9]*/fd/*; do
		[ "$(readlink "$_f" 2>/dev/null)" = "socket:[$_inode]" ] || continue
		_pid=${_f#/proc/}
		echo "${_pid%%/*}"
		return 0
	done
	return 1
}

rss_kb() { awk '/^VmRSS:/{ print $2 }' "/proc/$1/status" 2>/dev/null; }

# Only one AdGuardHome may run; keep the one that owns port 3053.
dedupe_agh() {
	_pids=$(pgrep -f '/usr/bin/AdGuardHome' 2>/dev/null)
	[ -n "$_pids" ] || return 0
	_n=$(echo $_pids | wc -w)
	[ "$_n" -gt 1 ] || return 0
	_keep=$(port_pid 3053 2>/dev/null)
	[ -n "$_keep" ] || _keep=$(echo $_pids | awk '{print $1}')
	for _p in $_pids; do
		[ "$_p" = "$_keep" ] && continue
		kill -9 "$_p" 2>/dev/null
		log "killed duplicate AdGuardHome pid $_p (keeping $_keep)"
	done
}

# AGH can be alive but wedged; its HTTP endpoint is a cheap liveness probe.
agh_alive() {
	have '/usr/bin/AdGuardHome' || return 1
	port_listen 3053 || return 1
	_code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ 2>/dev/null)
	[ "$_code" = "200" ] || [ "$_code" = "302" ] || [ "$_code" = "401" ]
}

# The supervisor runs AGH as a child and redirects 3053 -> 6053 the instant it
# dies, so "DNS is covered" even while AGH is restarting.
agh_supervised() { have '/usr/bin/agh-supervisor.sh'; }

passwall_guard() {
	if [ "$(uci -q get passwall2.@global[0].enabled)" != "1" ]; then
		if nft list table inet passwall2 >/dev/null 2>&1; then
			nft delete table inet passwall2 2>/dev/null
			log "passwall2 disabled: removed stale nft table (direct routing)"
		fi
		return 0
	fi
	# A passwall2 start/stop/restart script is running: never touch its nft
	# table or start a second instance (it takes /var/lock/passwall2.lock).
	if ! flock -n /var/lock/passwall2.lock true 2>/dev/null; then
		return 0
	fi
	if have 'passwall2/bin/xray' || have 'passwall2/bin/sing-box'; then
		rm -f "$STATE/pw2.fails" "$STATE/pw2.restart"
		_pid=$(pgrep -f 'passwall2/bin/xray' 2>/dev/null | head -1)
		[ -n "$_pid" ] || _pid=$(pgrep -f 'passwall2/bin/sing-box' 2>/dev/null | head -1)
		_rss=$(rss_kb "$_pid")
		if [ -n "$_rss" ] && [ "$_rss" -gt 204800 ]; then
			if ratelimit pw2.mem 600; then
				log "passwall2 core rss ${_rss}kB > 200MB, recycling"
				( /etc/init.d/passwall2 restart >/dev/null 2>&1 ) &
			fi
		fi
		return 0
	fi
	# A restart is already running: leave its nft table alone, otherwise we
	# would delete the fresh rules the restart just loaded.
	_age=999999
	[ -f "$STATE/pw2.restart" ] && _age=$(( $(now) - $(cat "$STATE/pw2.restart") ))
	[ "$_age" -ge 180 ] || return 0
	# core is down and no restart is in flight: flush the redirect table so
	# client traffic falls back to normal routing instead of a dead port.
	if nft list table inet passwall2 >/dev/null 2>&1; then
		nft delete table inet passwall2 2>/dev/null && \
			log "passwall2 core down: flushed nft table, traffic goes direct"
	fi
	_fails=$(cat "$STATE/pw2.fails" 2>/dev/null || echo 0)
	if [ "$_fails" -ge 3 ]; then
		if ratelimit pw2.stop 600; then
			log "passwall2 failed 3x: keeping it stopped so the LAN stays direct"
			/etc/init.d/passwall2 stop >/dev/null 2>&1
			nft delete table inet passwall2 2>/dev/null
		fi
		return 0
	fi
	if ratelimit pw2.restart 90; then
		log "passwall2 core down: restarting"
		( /etc/init.d/passwall2 restart >/dev/null 2>&1 ) &
		echo "$(now)" > "$STATE/pw2.restart"
		echo $((_fails + 1)) > "$STATE/pw2.fails"
	fi
}

oaf_guard() {
	if have '/usr/bin/oafd'; then
		rm -f "$STATE/oaf.fails"
		return 0
	fi
	svc_enabled appfilter || return 0
	_fails=$(cat "$STATE/oaf.fails" 2>/dev/null || echo 0)
	if [ "$_fails" -ge 3 ]; then
		if ratelimit oaf.stop 600; then
			log "oafd failed 3x: stopping appfilter and unloading kmod-oaf (no stale filter)"
			/etc/init.d/appfilter stop >/dev/null 2>&1
			rmmod oaf 2>/dev/null
		fi
	elif ratelimit oaf.restart 60; then
		log "oafd down: restarting appfilter"
		( /etc/init.d/appfilter restart >/dev/null 2>&1 ) &
		echo $((_fails + 1)) > "$STATE/oaf.fails"
	fi
}

main_loop() {
	log "netguard started (interval ${INTERVAL}s)"
	# Boot grace: passwall2 waits 60 s before it starts (start_delay), so do not
	# treat "core not running yet" as a crash right after boot.
	echo "$(now)" > "$STATE/pw2.restart"
	echo 0 > "$STATE/postboot"
	while :; do
		dedupe_agh

		# PassWall2 re-writes /tmp/dnsmasq.*.d/dnsmasq-passwall2.conf on every
		# start with "server=127.0.0.1#2002" + "all-servers".  That races our
		# ordered chain (ISP answers first -> pollution, ad-block bypassed).
		# Drop the file and reload dnsmasq so only our ordered list is used.
		if ls /tmp/dnsmasq.*.d/dnsmasq-passwall2.conf >/dev/null 2>&1; then
			if ratelimit pw2dnsclean 60; then
				rm -f /tmp/dnsmasq.*.d/dnsmasq-passwall2.conf
				log "removed passwall2 dnsmasq injection (all-servers/2002), reloading dnsmasq"
				/etc/init.d/dnsmasq restart >/dev/null 2>&1
			fi
		fi

		# dnsmasq: procd already respawns it; require two failed checks so a
		# restart triggered by another service is not restarted a second time
		if ! (have '/usr/sbin/dnsmasq' && port_listen 53); then
			_n=$(cat "$STATE/dns.fail" 2>/dev/null || echo 0)
			_n=$((_n + 1))
			echo "$_n" > "$STATE/dns.fail"
			if [ "$_n" -ge 2 ] && ratelimit dnsmasq.restart 30; then
				log "dnsmasq down or not listening: restarting"
				/etc/init.d/dnsmasq restart >/dev/null 2>&1
				rm -f "$STATE/dns.fail"
			fi
		else
			rm -f "$STATE/dns.fail"
		fi

		# AdGuardHome
		agh_ok=0
		if agh_supervised; then
			agh_ok=1
			# supervisor handles crashes; only kill a wedged AGH so the
			# supervisor notices, redirects and restarts it
			if have '/usr/bin/AdGuardHome' && port_listen 3053 && ! agh_alive; then
				if ratelimit agh.kill 60; then
					log "AdGuardHome wedged: killing it so the supervisor can fail over"
					kill -9 $(pgrep -f '/usr/bin/AdGuardHome') 2>/dev/null
				fi
			fi
		elif svc_enabled agh-boot && ratelimit agh.restart 45; then
			log "AdGuardHome supervisor down: restarting agh-boot"
			( /etc/init.d/agh-boot restart >/dev/null 2>&1 ) &
		fi

		# SmartDNS
		sdns_ok=0
		if [ "$(uci -q get smartdns.@smartdns[0].enabled)" = "1" ]; then
			if have '/usr/sbin/smartdns' && port_listen 6053; then
				sdns_ok=1
			elif svc_enabled smartdns && ratelimit sdns.restart 45; then
				log "SmartDNS down: restarting"
				( /etc/init.d/smartdns restart >/dev/null 2>&1 ) &
			fi
		fi

		# Once the local resolvers are up after a boot, drop dnsmasq's cache
		# once: during the first seconds of boot the ISP fallback may have
		# cached polluted answers for proxied domains.
		if [ "$(cat "$STATE/postboot" 2>/dev/null || echo 0)" = "0" ]; then
			if [ "$sdns_ok" = 1 ] && agh_alive; then
				for _pid in $(pgrep -f '^/usr/sbin/dnsmasq' 2>/dev/null); do
					kill -HUP "$_pid" 2>/dev/null
				done
				echo 1 > "$STATE/postboot"
				log "local resolvers up: flushed dnsmasq cache (drops boot-time answers)"
			fi
		fi

		passwall_guard
		oaf_guard

		# once a minute: end-to-end DNS sanity check (log only)
		if ratelimit dns.probe 60; then
			if ! (timeout 4 nslookup www.baidu.com 127.0.0.1 2>/dev/null | grep -q 'Address'); then
				log "WARN: end-to-end DNS probe failed (clients cannot resolve)"
			fi
		fi

		sleep "$INTERVAL"
	done
}

main_loop
