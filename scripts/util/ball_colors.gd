extends RefCounted
## Ball / board colors: 10 colors by the tens digit — 1-9 blue, 10-19 red,
## 20-29 green, ... 90-99 silver. From 100 on the colors repeat (100-109 blue
## again). For max 75 the B-I-N-G-O letters still follow the card columns
## (1-15 B, 16-30 I, 31-45 N, 46-60 G, 61-75 O), independent of the color.

const LETTERS := ["B", "I", "N", "G", "O"]
## Index = tens digit (number / 10 % 10).
const PALETTE := [
	Color(0.15, 0.40, 0.95),  # 0-9   blue
	Color(0.90, 0.18, 0.20),  # 10-19 red
	Color(0.13, 0.68, 0.32),  # 20-29 green
	Color(0.98, 0.84, 0.14),  # 30-39 yellow
	Color(0.56, 0.30, 0.86),  # 40-49 purple
	Color(1.00, 0.52, 0.10),  # 50-59 orange
	Color(0.10, 0.78, 0.86),  # 60-69 cyan
	Color(0.98, 0.48, 0.74),  # 70-79 pink
	Color(0.56, 0.34, 0.18),  # 80-89 brown
	Color(0.88, 0.88, 0.92),  # 90-99 white / silver
]
const DARK_INK := Color(0.08, 0.09, 0.14)


## Color group of a number: its tens digit (0-9 -> 0, 10-19 -> 1, ..., 100-109 -> 0).
static func group(number: int) -> int:
	return (maxi(number, 0) / 10) % PALETTE.size()


## B-I-N-G-O column (0..4) of a number: 5 equal parts of 1..max_number.
static func band(number: int, max_number: int) -> int:
	if max_number <= 0:
		return 0
	return clampi(int(float(number - 1) * 5.0 / float(max_number)), 0, 4)


## `_max_number` is kept so callers need not care how colors are assigned.
static func color_for(number: int, _max_number: int = 0) -> Color:
	return PALETTE[group(number)]


## Text color that stays readable on top of `color_for()`: white or dark,
## whichever has the higher contrast (WCAG relative luminance).
static func ink_for(number: int, _max_number: int = 0) -> Color:
	var bg := color_for(number)
	return Color.WHITE if contrast(bg, Color.WHITE) >= contrast(bg, DARK_INK) else DARK_INK


static func contrast(a: Color, b: Color) -> float:
	var la := _luminance(a)
	var lb := _luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


static func _luminance(c: Color) -> float:
	var l := c.srgb_to_linear()
	return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b


static func uses_bingo_letters(max_number: int) -> bool:
	return max_number == 75


static func letter_for(number: int, max_number: int) -> String:
	if not uses_bingo_letters(max_number):
		return ""
	return LETTERS[band(number, max_number)]
