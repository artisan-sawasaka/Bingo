extends RefCounted
## LAN address discovery and ranking for the remote-control URL.

const VIRTUAL_HINTS := ["vethernet", "virtualbox", "vmware", "hyper-v", "loopback", "bluetooth", "wsl", "docker", "tailscale", "zerotier", "vpn", "tap-", "tun"]


static func is_private_ipv4(ip: String) -> bool:
	var p := ip.split(".")
	if p.size() != 4:
		return false
	for part in p:
		if not part.is_valid_int():
			return false
	var a := p[0].to_int()
	var b := p[1].to_int()
	if a == 10:
		return true
	if a == 172 and b >= 16 and b <= 31:
		return true
	if a == 192 and b == 168:
		return true
	return false


static func _score(ip: String, iface_name: String) -> int:
	var s := 0
	var lname := iface_name.to_lower()
	for hint in VIRTUAL_HINTS:
		if lname.find(hint) >= 0:
			s -= 100
	if ip.begins_with("192.168."):
		s += 30
	elif ip.begins_with("10."):
		s += 20
	elif ip.begins_with("172."):
		s += 10
	if lname.find("wi-fi") >= 0 or lname.find("wifi") >= 0 or lname.find("wlan") >= 0 or lname.find("wireless") >= 0:
		s += 15
	if lname.find("ethernet") >= 0 or lname.find("イーサネット") >= 0:
		s += 12
	return s


## Score taken off an address the OS no longer uses (see active_ipv4), so it
## sorts after every live one. It stays in the list ("別のIP") in case the
## check is ever wrong for a network.
const STALE_PENALTY := 1000


## Returns [{ ip, name, score, active }] of private IPv4 addresses, best candidate first.
static func lan_addresses() -> Array:
	return rank(IP.get_local_interfaces(), Array(IP.get_local_addresses()), active_ipv4())


## IPv4 addresses Windows is really using now. A Wi-Fi adapter that lost its
## link keeps its old DHCP address in the "Deprecated" state:
## IP.get_local_interfaces() still lists it, but no phone can reach it, so a
## QR made from it always fails. Resolving this PC's own name returns only the
## live ("Preferred") addresses, answered locally in a few ms (no process).
## Empty when unknown (not Windows / lookup failed): nothing is demoted then.
static func active_ipv4() -> Array:
	var host := OS.get_environment("COMPUTERNAME")
	if host.is_empty():
		return []
	IP.clear_cache(host)  # results are cached; the network may have changed
	return Array(IP.resolve_hostname_addresses(host, IP.TYPE_IPV4))


## Pure ranking (tests): `interfaces` as from IP.get_local_interfaces(),
## `fallback_ips` used when they hold no private address, `active` from
## active_ipv4() (empty = every address counts as live).
static func rank(interfaces: Array, fallback_ips: Array, active: Array) -> Array:
	var found := []
	var seen := {}
	for iface in interfaces:
		var name: String = iface.get("friendly", iface.get("name", ""))
		for addr in iface.get("addresses", []):
			var ip: String = addr
			if is_private_ipv4(ip) and not seen.has(ip):
				seen[ip] = true
				found.append({"ip": ip, "name": name})
	# Fallback when interface info is unavailable.
	if found.is_empty():
		for addr in fallback_ips:
			var ip: String = addr
			if is_private_ipv4(ip) and not seen.has(ip):
				seen[ip] = true
				found.append({"ip": ip, "name": ""})
	for a in found:
		a.active = active.is_empty() or active.has(a.ip)
		a.score = _score(a.ip, a.name) - (0 if a.active else STALE_PENALTY)
	found.sort_custom(func(a, b): return a.score > b.score)
	return found
