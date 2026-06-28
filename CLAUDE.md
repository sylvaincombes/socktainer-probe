# Agent Instructions — SocktainerProbe

## What this project is

A local-only Swift tool for integration testing and API coverage analysis of [Socktainer](https://github.com/socktainer/socktainer). It is **not** committed to the Socktainer repo — it lives in `~/Projects/socktainer-probe/` and is run manually by the developer.

## Architecture

Three SPM targets sharing a common library:

| Target | Purpose |
|---|---|
| `SocktainerProbeCore` | Library — all test logic, Docker CLI wrapper, harness, reports |
| `SocktainerProbe` | CLI executable — `main.swift` + `Menu.swift` |
| `SocktainerProbeUI` | SwiftUI app — native macOS GUI (work in progress) |

### Core files

| File | Purpose |
|---|---|
| `DockerCLI.swift` | Typed wrapper around `docker --context <ctx>` via `Process` |
| `SocktainerHarness.swift` | Starts/stops a Socktainer binary, waits for socket |
| `TestSuite.swift` | `check()`, `skip()`, `assert*()` helpers + result collection |
| `RunReport.swift` | JSON serialization, issue markdown generation |
| `APICoverage.swift` | Swagger parser + static source-based coverage |
| `Config.swift` | Config model + binary discovery, `~/.socktainer-probe/config.json` |
| `Sessions.swift` | Session persistence in `.sessions/` |
| `IntegrationTests.swift` | Integration test orchestration (sequential + parallel) |
| `ComposeTests.swift` | Docker Compose test scenarios |
| `Tests/*.swift` | Individual test sections (one file per domain) |
| `Resources/docker-api-v28.5.2.json` | Bundled Docker Engine API spec |

## Key design decisions

- **No live probing for coverage** — uses static analysis of Socktainer's registered route patterns (`registerVersionedRoute(...)`) to avoid crashing the daemon during coverage runs.
- **Source-based harness restart** — `SocktainerHarness.restart()` is called after events tests because the EventsRoute has a pre-existing NIO crash on client disconnect; tests are written defensively around this.
- **`DockerCLI.configuredBinary`** — set at startup from `CheckConfig.dockerBinary` so all docker calls use the explicit binary, not the shell function wrapper.
- **Persistent machine ID** — stored in `~/.socktainer-probe/machine-id` to enable cross-run tracking.

## Running

```sh
# CLI
swift run SocktainerProbe -- --config        # first-time setup
swift run SocktainerProbe                    # run tests (interactive menu)
swift run SocktainerProbe -- --no-interactive  # headless/CI
swift run SocktainerProbe -- --coverage      # API coverage report
swift run SocktainerProbe -- --binary /path  # test a specific binary

# Native GUI (work in progress)
swift run SocktainerProbeUI
```

## Adding tests

Add `await check("description") { ... }` calls to a section file in `Sources/SocktainerProbeCore/Tests/`. Use `try assertContains`, `try assertEqual`, `try assert` from `TestSuite.swift`. Call `await ensureAlive(sock:)` after any `captureEvents` test since the events stream disconnect may crash Socktainer.

## Known issues

- The Socktainer EventsRoute has a pre-existing NIO crash when the events listener disconnects. Tests around events use `ensureAlive()` and auto-restart to work around this.
- `docker run --rm` remove events sometimes miss labels depending on restart timing.

## Coding style

- No comments unless the WHY is non-obvious
- No single-char variable names
- Swift async/await throughout — no callbacks
- Prefer named parameters over positional for clarity in test assertions
