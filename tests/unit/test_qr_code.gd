extends "res://tests/test_case.gd"
## Structural checks + dumps matrices to user://test_tmp/qr_dump.json so
## tools/verify_qr.mjs can decode them with an independent decoder (jsQR).

const QrCode = preload("res://scripts/util/qr_code.gd")

var SAMPLES := [
	"http://192.168.1.23:8765/#k=AbCdEfGhIjKlMnOpQrStUvWx",
	"http://10.0.0.5:8766/#k=Z9-_Z9-_Z9-_Z9-_Z9-_Z9-_",
	"http://172.16.100.200:8765/#k=0123456789abcdefghijABCDEFGHIJ",
	"A",
	"日本語のテキスト",
	"https://example.com/" + "x".repeat(200),
]


func _finder_ok(q, ox: int, oy: int) -> bool:
	for dy in 7:
		for dx in 7:
			var ring := maxi(absi(dx - 3), absi(dy - 3))
			var expect := ring != 2
			if q.get_module(ox + dx, oy + dy) != expect:
				return false
	return true


func test_structure_and_dump() -> void:
	var dump := []
	for text in SAMPLES:
		var q = QrCode.encode_text(text, QrCode.ECC_M)
		if not check(q != null, "encoded " + text.left(20)):
			continue
		eq(q.size, q.version * 4 + 17, "size")
		check(_finder_ok(q, 0, 0) and _finder_ok(q, q.size - 7, 0) and _finder_ok(q, 0, q.size - 7), "finders " + text.left(20))
		for i in range(8, q.size - 8):
			if q.get_module(i, 6) != (i % 2 == 0) or q.get_module(6, i) != (i % 2 == 0):
				fail("timing pattern")
				break
		check(q.get_module(8, q.size - 8), "dark module")
		var rows := []
		for y in q.size:
			var row := ""
			for x in q.size:
				row += "1" if q.get_module(x, y) else "0"
			rows.append(row)
		dump.append({"text": text, "version": q.version, "mask": q.mask, "rows": rows})
	# Forced masks must also be decodable.
	for m in 8:
		var q2 = QrCode.encode_text(SAMPLES[0], QrCode.ECC_M, m)
		var rows2 := []
		for y in q2.size:
			var row := ""
			for x in q2.size:
				row += "1" if q2.get_module(x, y) else "0"
			rows2.append(row)
		dump.append({"text": SAMPLES[0], "version": q2.version, "mask": m, "rows": rows2})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://test_tmp"))
	var f := FileAccess.open("user://test_tmp/qr_dump.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(dump))
	f.close()


func test_too_long_returns_null() -> void:
	check(QrCode.encode_text("x".repeat(3000), QrCode.ECC_M) == null, "too long")


func test_image_render() -> void:
	var q = QrCode.encode_text(SAMPLES[0])
	var img: Image = q.to_image(4, 4)
	eq(img.get_width(), (q.size + 8) * 4, "image size")
	eq(img.get_pixel(0, 0).r, 1.0, "quiet zone white")
	eq(img.get_pixel(16, 16).r, 0.0, "finder corner black")
