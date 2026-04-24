# Board43 Sample: Upside-down Billboard
#
# Slowly scrolls "RubyKaigi 2026 in Hakodate" across the LED matrix
# rendered 180 degrees upside-down, so the board can be mounted flipped
# (e.g. hung above eye level) and still read right-to-left naturally.
# The top and bottom borders draw a wavy line that cycles through six
# rainbow stops (red, yellow, green, cyan, blue, magenta), holding each
# color for a beat then sweeping to the next as a traveling gradient.
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

# Wavy border animation (reader-coords: top row 1, bottom row 14).
WAVE_TABLE          = [0, 1, 1, 1, 0, -1, -1, -1]  # amp 1, 8-step sine-ish
WAVE_LEN            = 8
WAVE_ADVANCE_FRAMES = 2   # wave shifts 1 column every N frames
TOP_WAVE_CENTER     = 1   # reader's row of top wave's midline
BOT_WAVE_CENTER     = 14  # reader's row of bottom wave's midline
BOT_PHASE_OFFSET    = 4   # half-cycle offset so top/bottom mirror each other

# Hue cycle: six rainbow stops 60 deg apart. Each phase = hold at
# HUE_COLORS[i] then sweep to HUE_COLORS[i+1]. During a sweep a single
# wavefront crosses the line and every column interpolates linearly from
# the old hue to the next over a wide gradient band, so you see a smooth
# e.g. red -> orange -> yellow wash travel across. Because neighbors on
# the wheel are 60 deg apart, the in-between shade always blends nicely.
HUE_COLORS       = [0, 60, 120, 180, 240, 300]                 # red,yellow,green,cyan,blue,magenta
HUE_HOLD_FRAMES  = 40                                          # ~1.2s per hold
HUE_SWEEP_FRAMES = 40                                          # ~1.2s per sweep
HUE_GRAD_HALF    = 6                                           # half-width of gradient (cols) -> 12-col gradient
HUE_SCALE        = 20                                          # sub-column resolution
HUE_GRAD_HALF_S  = HUE_GRAD_HALF * HUE_SCALE                   # 120
HUE_SWEEP_SPAN_S = (16 + 2 * HUE_GRAD_HALF) * HUE_SCALE        # 560, full wavefront travel
HUE_PHASE_LEN    = HUE_HOLD_FRAMES + HUE_SWEEP_FRAMES          # 80, one hold+sweep pair
HUE_CYCLE_LEN    = HUE_COLORS.length * HUE_PHASE_LEN           # 480, full rainbow loop
WAVE_BRIGHTNESS  = 40

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
    '###.',
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
    '###.',
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

wave_phase = 0
wave_frame = 0
hue_frame  = 0

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

  # Resolve hue state once per frame: figure out which rainbow stop we
  # are on and whether we're holding there or sweeping to the next one.
  phase_idx    = hue_frame / HUE_PHASE_LEN         # 0..5, index of current hold color
  phase_pos    = hue_frame % HUE_PHASE_LEN         # 0..HUE_PHASE_LEN-1
  from_hue     = HUE_COLORS[phase_idx]
  sweep_active = false
  wf_s         = 0
  if phase_pos >= HUE_HOLD_FRAMES
    sweep_active = true
    t_sweep = phase_pos - HUE_HOLD_FRAMES
    wf_s = t_sweep * HUE_SWEEP_SPAN_S / HUE_SWEEP_FRAMES - HUE_GRAD_HALF_S
  end

  # Wavy borders: overwrite the top/bottom margins with a single-pixel
  # squiggle per column. While holding, all columns share from_hue.
  # While sweeping, each column's hue = from_hue + offset(0..60), where
  # offset depends on the column's position relative to the wavefront,
  # walking forward around the color wheel to the next rainbow stop.
  wc = 0
  while wc < 16
    top_off = WAVE_TABLE[(wc + wave_phase) % WAVE_LEN]
    bot_off = WAVE_TABLE[(wc + wave_phase + BOT_PHASE_OFFSET) % WAVE_LEN]

    # Reader-coord rows -> physical rows (180 deg flip).
    top_phys_row = 15 - (TOP_WAVE_CENTER + top_off)
    bot_phys_row = 15 - (BOT_WAVE_CENTER + bot_off)
    phys_col     = 15 - wc

    if sweep_active
      dist_s = wc * HUE_SCALE - wf_s
      hue_offset = if dist_s <= -HUE_GRAD_HALF_S
                     60  # already transitioned to next rainbow stop
                   elsif dist_s >= HUE_GRAD_HALF_S
                     0   # not yet reached by wavefront
                   else
                     (HUE_GRAD_HALF_S - dist_s) / 4  # inside gradient band (0..60)
                   end
      hue = (from_hue + hue_offset) % 360
    else
      hue = from_hue
    end

    led.set_hsb(top_phys_row * 16 + phys_col, hue, 100, WAVE_BRIGHTNESS)
    led.set_hsb(bot_phys_row * 16 + phys_col, hue, 100, WAVE_BRIGHTNESS)

    wc += 1
  end

  led.show

  step_frames = sw5.low? ? SCROLL_FRAMES_TURBO : SCROLL_FRAMES
  frame += 1
  if frame >= step_frames
    frame = 0
    scroll += 1
    scroll = -16 if scroll > total_width
  end

  wave_frame += 1
  if wave_frame >= WAVE_ADVANCE_FRAMES
    wave_frame = 0
    wave_phase = (wave_phase + 1) % WAVE_LEN
  end

  hue_frame += 1
  hue_frame = 0 if hue_frame >= HUE_CYCLE_LEN

  sleep_ms 30
end
