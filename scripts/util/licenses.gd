extends RefCounted
## Third-party notices. Shown inside the app (settings → ライセンス / L key) so
## the exe alone satisfies the "include the notice" condition, and written to
## THIRD_PARTY_LICENSES.txt by tools/gen_licenses.gd.

const NAYUKI_MIT := """QR Code generator library (Project Nayuki) — algorithm ported to GDScript in scripts/util/qr_code.gd
https://www.nayuki.io/page/qr-code-generator-library

Copyright (c) Project Nayuki. (MIT License)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
- The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.
- The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising from,
  out of or in connection with the Software or the use or other dealings in the
  Software.
"""

const SUMMARY_JA := """このアプリは次のソフトウェアを利用しています。
・Godot Engine（MIT License）とその同梱ライブラリ（各ライセンスは下記の原文のとおり）
・QRコード生成アルゴリズム：Project Nayuki「QR Code generator library」（MIT License）をGDScriptに移植
3Dモデル・効果音・画面はこのアプリのために作成したもので、外部の有料素材やライセンス不明の素材は含みません。
"""


## Full notice text (English originals, as required by the licenses).
static func build_text() -> String:
	var text := "Bingo Drum 3D — third-party notices\n\n"
	text += "This application uses Godot Engine (https://godotengine.org).\n\n"
	text += "==== Godot Engine license ====\n" + Engine.get_license_text() + "\n\n"
	text += "==== Godot Engine third-party components ====\n"
	for info in Engine.get_copyright_info():
		text += "\n- " + str(info.get("name", "")) + "\n"
		for part in info.get("parts", []):
			text += "  files: %s\n  license: %s\n" % [", ".join(part.get("files", [])), part.get("license", "")]
			for c in part.get("copyright", []):
				text += "  (c) %s\n" % c
	text += "\n==== Licenses referenced above ====\n"
	var lic: Dictionary = Engine.get_license_info()
	for key in lic:
		text += "\n--- %s ---\n%s\n" % [key, lic[key]]
	text += "\n==== Other ====\n\n" + NAYUKI_MIT
	text += "\nAll 3D models, sounds and UI of Bingo Drum 3D are made for this project (primitive meshes and\nprocedurally synthesized audio). No external paid or unlicensed assets are included.\n"
	return text
