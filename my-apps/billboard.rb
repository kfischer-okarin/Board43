# Board43 Sample: Upside-down Billboard
#
# Slowly scrolls "RubyKaigi 2026 in Hakodate" across the LED matrix
# rendered 180 degrees upside-down, so the board can be mounted flipped
# (e.g. hung above eye level) and still read right-to-left naturally.
#
#   SW5 (hold): turbo scroll
#
# Features: Switches (GPIO) + WS2812 16x16 matrix

require 'ws2812-plus'
require 'gpio'

led = WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256)
sw5 = GPIO.new(Board43::GPIO_SW5, GPIO::IN | GPIO::PULL_UP)

MESSAGE = 'RubyKaigi 2026 in Hakodate'

FONT_H   = 7
TEXT_TOP = 4   # text band occupies logical rows 4..10 (7 rows, centered)
TEXT_GAP = 1   # blank columns between adjacent glyphs
SCROLL_FRAMES       = 3  # advance scroll by 1 pixel every N frames
SCROLL_FRAMES_TURBO = 1  # while SW5 is held

# Variable-width 7-tall glyphs. Keys are ASCII byte values.
# Each glyph is 7 rows; every row of a glyph has the same width.
# '#' = lit, '.' = off.
GLYPHS = {
  32 => [  # ' ' (3 wide)
    '...',
    '...',
    '...',
    '...',
    '...',
    '...',
    '...',
  ],
  48 => [  # '0' (5 wide)
    '.###.',
    '#...#',
    '#..##',
    '#.#.#',
    '##..#',
    '#...#',
    '.###.',
  ],
  50 => [  # '2' (5 wide)
    '.###.',
    '#...#',
    '....#',
    '...#.',
    '..#..',
    '.#...',
    '#####',
  ],
  54 => [  # '6' (5 wide)
    '.###.',
    '#....',
    '#....',
    '####.',
    '#...#',
    '#...#',
    '.###.',
  ],
  72 => [  # 'H' (5 wide)
    '#...#',
    '#...#',
    '#...#',
    '#####',
    '#...#',
    '#...#',
    '#...#',
  ],
  75 => [  # 'K' (5 wide)
    '#...#',
    '#..#.',
    '#.#..',
    '##...',
    '#.#..',
    '#..#.',
    '#...#',
  ],
  82 => [  # 'R' (5 wide)
    '####.',
    '#...#',
    '#...#',
    '####.',
    '#.#..',
    '#..#.',
    '#..#.',
  ],
  97 => [  # 'a' (5 wide)
    '.....',
    '.....',
    '.###.',
    '....#',
    '.####',
    '#...#',
    '.####',
  ],
  98 => [  # 'b' (5 wide)
    '#....',
    '#....',
    '####.',
    '#...#',
    '#...#',
    '#...#',
    '####.',
  ],
  100 => [  # 'd' (5 wide)
    '....#',
    '....#',
    '.####',
    '#...#',
    '#...#',
    '#...#',
    '.####',
  ],
  101 => [  # 'e' (5 wide)
    '.....',
    '.....',
    '.###.',
    '#...#',
    '#####',
    '#....',
    '.###.',
  ],
  103 => [  # 'g' (5 wide, no descender)
    '.....',
    '.....',
    '.####',
    '#...#',
    '.####',
    '....#',
    '.###.',
  ],
  105 => [  # 'i' (2 wide)
    '.#',
    '..',
    '.#',
    '.#',
    '.#',
    '.#',
    '.#',
  ],
  107 => [  # 'k' (4 wide, continuous diagonal)
    '#...',
    '#...',
    '#..#',
    '#.#.',
    '##..',
    '#.#.',
    '#..#',
  ],
  110 => [  # 'n' (4 wide)
    '....',
    '....',
    '####',
    '#..#',
    '#..#',
    '#..#',
    '#..#',
  ],
  111 => [  # 'o' (5 wide)
    '.....',
    '.....',
    '.###.',
    '#...#',
    '#...#',
    '#...#',
    '.###.',
  ],
  116 => [  # 't' (3 wide)
    '.#.',
    '.#.',
    '###',
    '.#.',
    '.#.',
    '.#.',
    '..#',
  ],
  117 => [  # 'u' (4 wide)
    '....',
    '....',
    '#..#',
    '#..#',
    '#..#',
    '#..#',
    '####',
  ],
  121 => [  # 'y' (5 wide, no descender)
    '.....',
    '.....',
    '#...#',
    '#...#',
    '.###.',
    '..#..',
    '..#..',
  ],
}

MSG_BYTES = MESSAGE.bytes

# First pass: measure total strip width (sum of glyph widths + gaps).
total_width = 0
ci = 0
while ci < MSG_BYTES.length
  g = GLYPHS[MSG_BYTES[ci]]
  total_width += g[0].length + TEXT_GAP if g
  ci += 1
end

# Second pass: pre-render the whole marquee as a flat boolean strip of
# size FONT_H rows * total_width cols. strip[row * total_width + col] = lit?
strip = Array.new(FONT_H * total_width, false)
x = 0
ci = 0
while ci < MSG_BYTES.length
  glyph = GLYPHS[MSG_BYTES[ci]]
  if glyph
    w = glyph[0].length
    r = 0
    while r < FONT_H
      gb = glyph[r].bytes
      c = 0
      while c < w
        strip[r * total_width + x + c] = true if gb[c] == 35  # '#'
        c += 1
      end
      r += 1
    end
    x += w + TEXT_GAP
  end
  ci += 1
end

# scroll = text column shown at the upside-down reader's leftmost col (read_col = 0).
# Start at -16 so the text enters from the reader's right edge; end past
# total_width so it fully exits the left edge before looping.
scroll = -16
frame  = 0

loop do
  row = 0
  while row < 16
    col = 0
    while col < 16
      # Rotate 180 degrees: the reader sees logical (15-row, 15-col)
      # at physical (row, col).
      read_row = 15 - row
      read_col = 15 - col
      text_row = read_row - TEXT_TOP
      text_col = read_col + scroll

      lit = false
      if text_row >= 0 && text_row < FONT_H &&
         text_col >= 0 && text_col < total_width
        lit = strip[text_row * total_width + text_col]
      end

      idx = row * 16 + col
      if lit
        led.set_rgb(idx, 180, 180, 180)  # white
      else
        led.set_rgb(idx, 0, 0, 0)
      end

      col += 1
    end
    row += 1
  end
  led.show

  step_frames = sw5.low? ? SCROLL_FRAMES_TURBO : SCROLL_FRAMES
  frame += 1
  if frame >= step_frames
    frame = 0
    scroll += 1
    scroll = -16 if scroll > total_width
  end

  sleep_ms 30
end
