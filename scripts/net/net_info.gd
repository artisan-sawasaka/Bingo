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


## Returns [{ ip, name }] of private IPv4 addresses, best candidate first.
static func lan_addresses() -> Array:
	var found := []
	var seen := {}
	for iface in IP.get_local_interfaces():
		var name: String = iface.get("friendly", iface.get("name", ""))
		for addr in iface.get("addresses", []):
			var ip: String = addr
			if is_private_ipv4(ip) and not seen.has(ip):
				seen[ip] = true
				found.append({"ip": ip, "name": name, "score": _score(ip, name)})
	# Fallback when interface info is unavailable.
	if found.is_empty():
		for ip in IP.get_local_addresses():
			if is_private_ipv4(ip) and not seen.has(ip):
				seen[ip] = true
				found.append({"ip": ip, "name": "", "score": _score(ip, "")})
	found.sort_custom(func(a, b): return a.score > b.score)
	return found
