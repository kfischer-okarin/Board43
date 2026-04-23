# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Board43 is a monorepo for an RP2350A dev board. The top-level directories are effectively **independent projects with their own toolchains, licenses, and release tags** — there is no root build system. Work in the relevant subdirectory.

| Dir | Stack | Purpose |
| --- | --- | --- |
| `firmware/` | PicoRuby (Ruby + C, Pico SDK) via git submodule | Board firmware (R2P2 / PicoRuby for RP2350) |
| `docs/` | Rust (edition 2024) + Typst | Compiles the reference manual PDF |
| `playground/` | React 19 + TypeScript + Vite + Biome, pnpm | Browser-based PicoRuby IDE |
| `playground/lib/board43-image-transformer/` | Rust (edition 2024) + wasm-pack | Image→16×16 RGB CLI and WASM module |
| `pcb/` | KiCad | Board schematic and layout |
| `workshop/` | Ruby examples + Markdown | Workshop material (JP/EN) |

## Firmware (`firmware/`)

- PicoRuby lives in `firmware/picoruby` as a git submodule. Pico SDK and Pico Extras are **nested** submodules under it and must be materialized by `rake r2p2:setup` (not `git submodule update --recursive`), so they land on the tagged release the Rakefile expects.
- First-time setup: `cd firmware && ./setup.sh`. This runs `git submodule update --init --recursive` inside `picoruby/`, `bundle install`, `rake r2p2:setup`, then applies `firmware/picoruby.patch`. The patch adds two extra mrbgems (`picoruby-ws2812-plus`, `picoruby-lsm6ds3`) and a Board43-specific build-date suffix.
- Build (local): from `firmware/picoruby`, export `PICO_SDK_PATH=$(pwd)/mrbgems/picoruby-r2p2/lib/pico-sdk` and `PICO_EXTRAS_PATH=$(pwd)/mrbgems/picoruby-r2p2/lib/pico-extras`, then `rake r2p2:picoruby:pico2:prod`. Output UF2 lands in `build/r2p2/picoruby/pico2/prod/R2P2-PICORUBY-*.uf2`.
- Release: push a tag `firmware-YYYY-MM-DD-NN` (two-digit sequence) to trigger `.github/workflows/build-firmware.yml`. CI requires `cmake`, `gcc-arm-none-eabi`, `libnewlib-arm-none-eabi`, `libstdc++-arm-none-eabi-newlib`.
- If you modify the patch, regenerate it from the submodule working tree — the workflow applies it verbatim.

## Docs (`docs/`)

- `docs/` is a Rust crate (`board43-document-compiler`) that wraps [typwriter](https://crates.io/crates/typwriter) to compile `reference-manual/main.typ` to PDF and then stamp metadata from `reference-manual/metadata.yml`.
- Common commands (run from `docs/`):
  - `cargo run -- compile` — build `reference-manual/reference-manual.pdf`.
  - `cargo run -- watch` — recompile on change and open the PDF in Chrome.
  - `cargo run -- format` — format the Typst source.
  - `cargo run -- compile --nup 1x2` — generate an n-up PDF alongside the normal one.
- **Typwriter caching gotcha (relevant to CI and any cleanup):** typwriter's `build.rs` downloads fonts into `~/.cache/typwriter/` and the generated `embed_*.rs` in `target/` uses `include_bytes!` with **absolute paths** into that cache. Deleting `~/.cache/typwriter/` without also clearing `target/` leaves dangling paths. The CI workflow caches both together for this reason — keep them in sync locally too.
- Release: tag `document-MAJOR.MINOR.PATCH` triggers `.github/workflows/build-document.yml`. When publishing a document release after a firmware release, uncheck "Set as the latest release" — the manual points readers at `releases/latest` for firmware downloads.

## Playground (`playground/`)

- React 19 + Vite SPA. Package manager is **pnpm** (lockfile and `pnpm-workspace.yaml` are committed). Lint/format is Biome (single quotes, semicolons, 2-space indent).
- Commands (from `playground/`):
  - `pnpm install` / `pnpm dev` / `pnpm build` / `pnpm preview`
  - `pnpm lint` — `biome check .`
  - `pnpm lint:fix` — auto-fix
  - `pnpm format` — `biome format --write .`
- No test runner is configured.
- Two WASM modules are used:
  - `@picoruby/wasm-wasi` — runs Ruby in-browser for the LED simulator. Excluded from Vite pre-bundling in `vite.config.ts` to avoid binary load issues.
  - `board43-image-transformer` — local Rust crate, **built artifacts are vendored into `src/wasm/image-transformer/`** (`.js`, `.wasm`, `.d.ts`). Biome ignores that directory. Rebuild the artifacts from `playground/lib/board43-image-transformer/` (see below) and copy the `pkg/` output into `src/wasm/image-transformer/` when the Rust source changes.
- Workers use ES module format (`worker.format: 'es'` in Vite config). Device I/O uses the Web Serial API (Chrome/Edge only); the simulator path works in any modern browser.
- Key source areas: `src/components/Editor/` (CodeMirror multi-file editor), `src/components/Emulator/` (16×16 LED simulator, pixel codegen, presets), `src/hooks/` (`usePicoRubyWasm`, `useSerial`, `useDeviceFilesystem`), `src/workers/picoruby.worker.ts` (runs user Ruby off the main thread), `src/i18n/` (English/Japanese).

## board43-image-transformer (`playground/lib/board43-image-transformer/`)

- Dual-target Rust crate: `cdylib` for WASM, `rlib` + binary for the CLI. `wasm-opt` is disabled in the wasm-pack profile.
- Prereqs: `rustup target add wasm32-unknown-unknown` and `cargo install wasm-pack`.
- CLI: `cargo run -- <inputs>... -o <output-dir>`.
- WASM for the playground: `wasm-pack build --target bundler --release`, then copy `pkg/board43_image_transformer{,_bg}.{js,wasm,d.ts}` into `playground/src/wasm/image-transformer/`.
- WASM for the standalone demo (`index.html` in the crate): `wasm-pack build --target web --release` then serve the directory over HTTP.
- Output layout: `transform(bytes) → Uint8Array(768)` — 16×16×3 raw RGB, row-major, 3 bytes per pixel.

## PCB (`pcb/`)

KiCad project (`Board43.kicad_pro`, `.kicad_sch`, `.kicad_pcb`). `pcb/scripts/arrange_grid.py` is a helper script. Files are licensed CERN-OHL-W-2.0 (some under CC BY-SA 4.0).

## Release tagging summary

- Firmware: `firmware-YYYY-MM-DD-NN` (e.g. `firmware-2026-04-15-01`)
- Document: `document-MAJOR.MINOR.PATCH` (e.g. `document-1.0.0`)

Both workflows also accept `workflow_dispatch` manual runs (build without creating a release).
