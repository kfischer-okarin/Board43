#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Fill every `# BEGIN SONG: <name>` / `# END SONG` block in a Ruby file
with the compiled byte-string for `<name>.song` from this directory.

Usage:
    uv run my-apps/songs/build.py <path-to-ruby-file> [<path-to-ruby-file> ...]

Song source format (one `.song` file per song, under this directory):
    Each non-blank, non-comment line is `<note> <duration_ms>`.
    Notes are e.g. C4, Gs4 (sharp), Bb3 (flat); R is a rest.
    '#' starts a line comment.

Compiled output format, 4 bytes per event:
    bytes 0-1: frequency in Hz    (little-endian; 0 = rest)
    bytes 2-3: duration in ms     (little-endian)

An ARTICULATION_MS silence is inserted between back-to-back same-pitch
notes so repeated notes articulate instead of blurring into one tone.

Block shape the script rewrites in the target Ruby file:
    # BEGIN SONG: megalovania_saw
    ...anything here gets replaced...
    # END SONG

The constant name emitted is the uppercased song name + `_DATA`
(e.g. `megalovania_saw` -> `MEGALOVANIA_SAW_DATA`).
"""
from __future__ import annotations

import os
import re
import sys

NOTE_LETTERS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
ARTICULATION_MS = 10
BYTES_PER_LINE = 32

SONG_DIR = os.path.dirname(os.path.abspath(__file__))

BLOCK_RE = re.compile(
    r"^([ \t]*)# BEGIN SONG: (?P<name>[A-Za-z0-9_]+)[ \t]*\n"
    r".*?"
    r"^[ \t]*# END SONG[ \t]*\n",
    re.DOTALL | re.MULTILINE,
)


def note_to_midi(name: str) -> int:
    letter = name[0]
    rest = name[1:]
    sharp = 0
    if rest and rest[0] == "s":
        sharp = 1
        rest = rest[1:]
    elif rest and rest[0] == "b":
        sharp = -1
        rest = rest[1:]
    if letter not in NOTE_LETTERS:
        raise ValueError(f"bad note letter in {name!r}")
    if not rest or not rest.lstrip("-").isdigit():
        raise ValueError(f"bad octave in {name!r}")
    return (int(rest) + 1) * 12 + NOTE_LETTERS[letter] + sharp


def midi_to_freq(midi: int) -> int:
    return round(440 * (2 ** ((midi - 69) / 12)))


def parse_song(path: str) -> list[tuple[str, int]]:
    notes: list[tuple[str, int]] = []
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise ValueError(f"{path}:{lineno}: expected '<note> <ms>', got {raw!r}")
            name, dur = parts[0], int(parts[1])
            if not (0 < dur <= 65535):
                raise ValueError(f"{path}:{lineno}: duration {dur} out of 1..65535")
            notes.append((name, dur))
    return notes


def compile_events(notes: list[tuple[str, int]]) -> list[tuple[int, int]]:
    freqs = [0 if n == "R" else midi_to_freq(note_to_midi(n)) for n, _ in notes]
    events: list[tuple[int, int]] = []
    for i, (_, dur) in enumerate(notes):
        f = freqs[i]
        nf = freqs[i + 1] if i + 1 < len(notes) else -1
        if f > 0 and f == nf and dur > 2 * ARTICULATION_MS:
            events.append((f, dur - ARTICULATION_MS))
            events.append((0, ARTICULATION_MS))
        else:
            events.append((f, dur))
    return events


def to_bytes(events: list[tuple[int, int]]) -> bytes:
    buf = bytearray()
    for freq, dur in events:
        if not (0 <= freq <= 65535 and 0 <= dur <= 65535):
            raise ValueError(f"16-bit overflow: freq={freq}, dur={dur}")
        buf.append(freq & 0xFF)
        buf.append((freq >> 8) & 0xFF)
        buf.append(dur & 0xFF)
        buf.append((dur >> 8) & 0xFF)
    return bytes(buf)


def hex_literal(data: bytes, indent: str) -> str:
    lines = []
    for i in range(0, len(data), BYTES_PER_LINE):
        chunk = data[i : i + BYTES_PER_LINE]
        escaped = "".join(f"\\x{b:02x}" for b in chunk)
        lines.append(f'{indent}  "{escaped}"')
    return " \\\n".join(lines) if lines else f'{indent}  ""'


def const_name(song: str) -> str:
    return song.upper() + "_DATA"


def build_block(song: str, indent: str) -> str:
    path = os.path.join(SONG_DIR, f"{song}.song")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"missing song source: {path}")
    notes = parse_song(path)
    events = compile_events(notes)
    data = to_bytes(events)
    lines = [
        f"{indent}# BEGIN SONG: {song}",
        f"{indent}# {len(notes)} notes -> {len(events)} events, {len(data)} bytes",
        f"{indent}{const_name(song)} = \\",
        hex_literal(data, indent),
        f"{indent}# END SONG",
        "",
    ]
    return "\n".join(lines), (song, len(notes), len(events), len(data))


def process(target: str) -> list[tuple[str, int, int, int]]:
    with open(target) as f:
        src = f.read()

    summary: list[tuple[str, int, int, int]] = []
    pieces: list[str] = []
    pos = 0
    for m in BLOCK_RE.finditer(src):
        indent = m.group(1)
        song = m.group("name")
        block, stat = build_block(song, indent)
        pieces.append(src[pos : m.start()])
        pieces.append(block)
        pos = m.end()
        summary.append(stat)
    pieces.append(src[pos:])
    new_src = "".join(pieces)

    if new_src != src:
        with open(target, "w") as f:
            f.write(new_src)
    return summary


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    overall_ok = True
    for target in argv[1:]:
        if not os.path.isfile(target):
            print(f"not a file: {target}", file=sys.stderr)
            overall_ok = False
            continue
        try:
            summary = process(target)
        except Exception as exc:
            print(f"{target}: {exc}", file=sys.stderr)
            overall_ok = False
            continue
        if not summary:
            print(f"{target}: no '# BEGIN SONG: ...' blocks found")
            continue
        print(f"{target}:")
        for song, n_notes, n_events, n_bytes in summary:
            print(f"  {song:30s}  {n_notes:4d} notes, {n_events:4d} events, {n_bytes:5d} bytes")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
