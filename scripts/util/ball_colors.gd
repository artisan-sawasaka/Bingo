extends RefCounted
## Ball / board colors. For max 75 the classic B-I-N-G-O columns are used
## (1-15 B, 16-30 I, 31-45 N, 46-60 G, 61-75 O). Other sizes use 5 equal bands.

const LETTERS := ["B", "I", "N", "G", "O"]
const PALETTE := [
	Color(0.18, 0.45, 0.95),  # blue
	Color(0.92, 0.22, 0.25),  # red
	Color(0.88, 0.88, 0.92),  # white / silver
	Color(0.15, 0.72, 0.38),  # green
	Color(0.98, 0.72, 0.12),  # yellow / orange
]


static func band(number: int, max_number: int) -> int:
	if max_number <= 0:
		return 0
	return clampi(int(float(number - 1) * 5.0 / float(max_number)), 0, 4)


static func color_for(number: int, max_number: int) -> Color:
	return PALETTE[band(number, max_number)]


## Text color that stays readable on top of `color_for()`.
static func ink_for(number: int, max_number: int) -> Color:
	return Color(0.08, 0.09, 0.14) if band(number, max_number) in [2, 4] else Color.WHITE


static func uses_bingo_letters(max_number: int) -> bool:
	return max_number == 75


static func letter_for(number: int, max_number: int) -> String:
	if not uses_bingo_letters(max_number):
		return ""
	return LETTERS[band(number, max_number)]
