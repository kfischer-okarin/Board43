# Board43 Sample: Upside-down Billboard
#
# Slowly scrolls "RubyKaigi 2026 in Hakodate" across the LED matrix
# rendered 180 degrees upside-down, so the board can be mounted flipped
# (e.g. hung above eye level) and still read right-to-left naturally.
#
#   (no controls - idle animation)
#
# Features: WS2812 16x16 matrix

require 'ws2812-plus'

led = WS2812.new(pin: Board43::GPIO_LEDOUT, num: 256)

MESSAGE = 'RubyKaigi 2026 in Hakodate'

CHAR_W  = 5
STRIDE  = 6    # 5-wide glyph + 1 col gap
FONT_H  = 7
TEXT_TOP = 4   # text band occupies logical rows 4..10 (7 rows, centered)
SCROLL_FRAMES = 4  # advance scroll by 1 pixel every N frames (~8 px/s)

# 5x7 glyphs. Keys are ASCII byte values to avoid string-indexing quirks.
# Each glyph is 7 rows of 5 chars, '#' = lit, '.' = off.
GLYPHS = {
  32 => [  # ' '
    '.....',
    '.....',
    '.....',
    '.....',
    '.....',
    '.....',
    '.....',
  ],
  48 => [  # '0'
    '.###.',
    '#...#',
    '#..##',
    '#.#.#',
    '##..#',
    '#...#',
    '.###.',
  ],
  50 => [  # '2'
    '.###.',
    '#...#',
    '....#',
    '...#.',
    '..#..',
    '.#...',
    '#####',
  ],
  54 => [  # '6'
    '.###.',
    '#....',
    '#....',
    '####.',
    '#...#',
    '#...#',
    '.###.',
  ],
  72 => [  # 'H'
    '#...#',
    '#...#',
    '#...#',
    '#####',
    '#...#',
    '#...#',
    '#...#',
  ],
  75 => [  # 'K'
    '#...#',
    '#..#.',
    '#.#..',
    '##...',
    '#.#..',
    '#..#.',
    '#...#',
  ],
  82 => [  # 'R'
    '####.',
    '#...#',
    '#...#',
    '####.',
    '#.#..',
    '#..#.',
    '#..#.',
  ],
  97 => [  # 'a'
    '.....',
    '.....',
    '.###.',
    '....#',
    '.####',
    '#...#',
    '.####',
  ],
  98 => [  # 'b'
    '#....',
    '#....',
    '####.',
    '#...#',
    '#...#',
    '#...#',
    '####.',
  ],
  100 => [  # 'd'
    '....#',
    '....#',
    '.####',
    '#...#',
    '#...#',
    '#...#',
    '.####',
  ],
  101 => [  # 'e'
    '.....',
    '.....',
    '.###.',
    '#...#',
    '#####',
    '#....',
    '.###.',
  ],
  103 => [  # 'g' (no descender, compressed)
    '.....',
    '.....',
    '.####',
    '#...#',
    '.####',
    '....#',
    '.###.',
  ],
  105 => [  # 'i'
    '..#..',
    '.....',
    '..#..',
    '..#..',
    '..#..',
    '..#..',
    '..#..',
  ],
  107 => [  # 'k'
    '#....',
    '#....',
    '#..#.',
    '#.#..',
    '##...',
    '#.#..',
    '#...#',
  ],
  110 => [  # 'n'
    '.....',
    '.....',
    '####.',
    '#...#',
    '#...#',
    '#...#',
    '#...#',
  ],
  111 => [  # 'o'
    '.....',
    '.....',
    '.###.',
    '#...#',
    '#...#',
    '#...#',
    '.###.',
  ],
  116 => [  # 't'
    '.#...',
    '.#...',
    '###..',
    '.#...',
    '.#...',
    '.#...',
    '..##.',
  ],
  117 => [  # 'u'
    '.....',
    '.....',
    '#...#',
    '#...#',
    '#...#',
    '#...#',
    '.####',
  ],
  121 => [  # 'y' (no descender, compressed)
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
TOTAL_WIDTH = MSG_BYTES.length * STRIDE

# Pre-render the whole marquee once as a flat boolean strip of size
# FONT_H rows * TOTAL_WIDTH cols. strip[row * TOTAL_WIDTH + col] = lit?
strip = Array.new(FONT_H * TOTAL_WIDTH, false)

ci = 0
while ci < MSG_BYTES.length
  glyph = GLYPHS[MSG_BYTES[ci]]
  if glyph
    r = 0
    while r < FONT_H
      gb = glyph[r].bytes
      c = 0
      while c < CHAR_W
        if gb[c] == 35  # '#'
          strip[r * TOTAL_WIDTH + ci * STRIDE + c] = true
        end
        c += 1
      end
      r += 1
    end
  end
  ci += 1
end

# scroll = text column shown at the upside-down reader's leftmost col (read_col = 0).
# Start at -16 so the text enters from the reader's right edge; end past
# TOTAL_WIDTH so it fully exits the left edge before looping.
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
         text_col >= 0 && text_col < TOTAL_WIDTH
        lit = strip[text_row * TOTAL_WIDTH + text_col]
      end

      idx = row * 16 + col
      if lit
        led.set_hsb(idx, 0, 100, 40)  # Ruby red
      else
        led.set_rgb(idx, 0, 0, 0)
      end

      col += 1
    end
    row += 1
  end
  led.show

  frame += 1
  if frame >= SCROLL_FRAMES
    frame = 0
    scroll += 1
    scroll = -16 if scroll > TOTAL_WIDTH
  end

  sleep_ms 30
end
