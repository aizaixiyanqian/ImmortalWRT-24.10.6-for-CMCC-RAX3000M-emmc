#!/bin/sh
# Ensure /etc/AdGuardHome.yaml keeps the independent DNS wiring:
#   AdGuardHome -> SmartDNS (127.0.0.1:6053) -> PassWall2 (127.0.0.1:2002)
# with plain ISP/public DNS as fallback, so AGH still resolves if SmartDNS or
# the PassWall2 core is down.
#
# Only runs while AdGuard Home is stopped (called from agh-boot start_service).
# Everything outside the dns: section is preserved byte for byte.

Y=/etc/AdGuardHome.yaml
[ -f "$Y" ] || exit 0

awk '
BEGIN { in_dns = 0; skip = 0 }

/^dns:/ { in_dns = 1; print; next }
in_dns == 1 && /^[^ # 	-]/ { in_dns = 0 }

in_dns == 1 && /^  port:/ {
	print "  port: 3053"
	next
}

in_dns == 1 && /^  upstream_dns:/ {
	print "  upstream_dns:"
	print "    - 127.0.0.1:6053"
	skip = 1
	next
}

in_dns == 1 && /^  fallback_dns:/ {
	print "  fallback_dns:"
	print "    - 192.168.1.1"
	print "    - 223.5.5.5"
	skip = 1
	next
}

in_dns == 1 && /^  bootstrap_dns:/ {
	print "  bootstrap_dns:"
	print "    - 192.168.1.1"
	print "    - 223.5.5.5"
	skip = 1
	next
}

skip == 1 && /^    - / { next }
skip == 1 { skip = 0 }

in_dns == 1 && /^  upstream_mode:/ { print "  upstream_mode: load_balance"; next }
in_dns == 1 && /^  upstream_timeout:/ { print "  upstream_timeout: 5s"; next }
in_dns == 1 && /^  max_goroutines:/ { print "  max_goroutines: 100"; next }

# PTR lookups for LAN addresses would be sent to 127.0.0.1:53 (dnsmasq),
# which forwards to AGH again -> a loop that ends in 2 s timeouts.  SmartDNS
# already knows the DHCP leases, so simply do not use the system resolver here.
in_dns == 1 && /^  use_private_ptr_resolvers:/ { print "  use_private_ptr_resolvers: false"; next }
in_dns == 1 && /^  local_ptr_upstreams:/ { print "  local_ptr_upstreams: []"; skip = 1; next }

{ print }
' "$Y" > /tmp/AdGuardHome.yaml.new

if [ -s /tmp/AdGuardHome.yaml.new ]; then
	cp -f "$Y" /tmp/AdGuardHome.yaml.bak 2>/dev/null
	mv -f /tmp/AdGuardHome.yaml.new "$Y"
else
	rm -f /tmp/AdGuardHome.yaml.new
fi
