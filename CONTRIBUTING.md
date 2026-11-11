# Contributing to Loom

Thanks for wanting to help. Bug reports, fixes, documentation and ideas are all welcome.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

> Found a security problem? Please do not open a public issue or pull request for it. Follow the
> [security policy](SECURITY.md) instead.

## Getting set up

Loom is a Windows desktop app. You need:

- Windows 10 or 11
- [Node.js](https://nodejs.org) 22 or later
- [Rust](https://rustup.rs) stable, with the MSVC toolchain
- The WebView2 runtime, which Windows 11 already includes

```bash
git clone https://github.com/TomFleuren/Loom.git
cd Loom
npm install
npm run tauri dev
```

That opens the Loom window with hot reloading for the interface.

## Commands

| Command | What it does |
| --- | --- |
| `npm run dev` | Start the interface on its own, in a browser |
| `npm run tauri dev` | Open the desktop window |
| `npm run build` | Typecheck and build the interface into `dist/` |
| `npm run dist` | Build `src-tauri/target/release/Loom.exe` |

## Before opening a pull request

1. Run `npm run build`. CI runs the same check.
2. If you changed the desktop window, run `npm run tauri dev` and try the screen you touched.
3. Keep the change focused. A small pull request that does one thing is easier to review.
4. Describe what you changed and how you checked it. The pull request template has prompts.

## Ground rules

- Loom changes a Windows machine, and some actions need an administrator. Be explicit in the interface when a change is hard to undo.
- Do not add a new runtime dependency without a reason. Say why it belongs.
- Keep the catalog data in `src/data` and `src-tauri/resources/config` in sync. The window reads one copy and the engine reads the other.
