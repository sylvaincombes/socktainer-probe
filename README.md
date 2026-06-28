# SocktainerProbe

> **⚠️ DRAFT — UNSTABLE — WORK IN PROGRESS**
>
> This project is at an early stage. APIs, test IDs, coverage classifications, and UI are subject to change without notice. Do not depend on session files, report formats, or CLI output being stable across versions.
>
> Feedback and contributions welcome — especially around test coverage, platform limitation notes, and workaround ideas.

---

A native macOS developer tool for testing and tracking [Socktainer](https://github.com/socktainer/socktainer)'s Docker Engine API compatibility.

Socktainer implements the Docker socket API on top of Apple Container / Apple Virtualization. SocktainerProbe answers the question: **"Which Docker API endpoints work, which are stubbed, and which can't work on Apple Container at all?"**

It is intentionally a **separate project** from Socktainer — a companion tool for contributors and early adopters, not part of the runtime itself.

---

## Requirements

- macOS 14 (Sonoma) or later · Apple Silicon (M1+)
- Swift 5.9+ (`xcode-select --install` or Xcode)
- [Socktainer](https://github.com/socktainer/socktainer) running (or a binary to test against)
- Docker CLI (`/opt/homebrew/bin/docker` or Docker Desktop)
- A reference Docker runtime for parity tests — [Colima](https://github.com/abiosoft/colima) or [OrbStack](https://orbstack.dev) recommended

No Apple Developer account required — build and run entirely from source.

---

## Quick Start

```sh
git clone https://github.com/sylvaincombes/socktainer-probe
cd socktainer-probe

# First-time setup (pick your Docker CLI, Socktainer binary, reference runtime)
swift run SocktainerProbeCli -- --config

# Launch the native GUI
swift run SocktainerProbe

# Or use the CLI directly
swift run SocktainerProbeCli
```

---

## GUI — `swift run SocktainerProbe`

A native macOS SwiftUI app with five sections:

| Section | What it does |
|---------|-------------|
| **Dashboard** | Last run summary, recent run history, environment info |
| **Run Tests** | Launch any test suite, watch results stream live |
| **Coverage** | Docker Engine API v28.5.2 endpoint coverage matrix |
| **History** | Browse past runs, inspect failures, export to Markdown |
| **Settings** | Docker CLI path, Socktainer binary, reference runtime |

### Running tests in the GUI

Pick a suite and press **⌘R**:

| Suite | What it runs |
|-------|-------------|
| Integration | Full Docker API tests (parallel wave execution) |
| Testcontainers | Testcontainers-Java compatibility patterns |
| Devcontainer | devcontainer.json lifecycle patterns |
| Compose | docker-compose.yml scenario tests |
| Parity | Cross-runtime comparison vs Colima / OrbStack |
| All | All of the above |

Results stream live as each test completes. Press **⌘F** to toggle "Failures only" — the view auto-switches to failures when a run completes with errors.

Right-click any result → **Copy as Markdown** to paste into a GitHub issue.

### Coverage screen

Fetches Socktainer's registered routes from GitHub and cross-references them against the Docker Engine API v28.5.2 swagger. Each endpoint is classified:

| Status | Meaning |
|--------|---------|
| ✅ Implemented | Route registered and test present |
| 🧪 No test | Implemented but not yet covered by a test |
| ❌ Missing | In spec, no known blocker — just needs implementation |
| 🔧 Workaround | Could be implemented with an Apple Container trick |
| 🔴 Platform limit | Apple Container 1.0 cannot support this (pause, CRIU checkpoint, etc.) |
| 🚫 N/A | Swarm / Docker Desktop only — structurally out of scope |

Click **Copy as Markdown** for a GitHub-ready coverage report with collapsible sections.

---

## CLI — `swift run SocktainerProbeCli`

```sh
swift run SocktainerProbeCli                              # interactive menu
swift run SocktainerProbeCli -- --no-interactive          # CI / headless (runs integration tests)
swift run SocktainerProbeCli -- --sequential              # force sequential (default: parallel wave)
swift run SocktainerProbeCli -- --coverage                # Docker API coverage report
swift run SocktainerProbeCli -- --list                    # list all test IDs without running
swift run SocktainerProbeCli -- --only CTR-001            # run a single test by ID
swift run SocktainerProbeCli -- --binary /path/socktainer # test a specific binary
swift run SocktainerProbeCli -- --watch                   # re-run automatically on binary change
swift run SocktainerProbeCli -- --junit report.xml        # emit JUnit XML for CI systems
```

---

## Test IDs

Every test has a stable prefix-numbered ID (e.g. `CTR-001`, `EVT-007`, `VOL-003`) for use in issues and PR descriptions. Known failures are marked `xfail` with an explicit reason — they show as ⚠️ and are not counted as regressions. When an xfail test suddenly passes, it shows as 🎉 Unexpected pass — a clear signal that a feature was implemented.

---

## Project layout

```
Sources/
  SocktainerProbeCore/       ← shared library (tests, DockerCLI, reports, coverage analysis)
    Tests/                   ← one file per test domain (ContainerTests, EventTests, …)
  SocktainerProbe/           ← native macOS SwiftUI app (GUI)
  SocktainerProbeCli/        ← CLI (interactive menu + headless CI mode)
Resources/
  docker-api-v28.5.2.json    ← bundled Docker Engine API spec (offline coverage)
  docker-compose/            ← compose scenario YAML files used by Compose suite
```

---

## Contributing

- **Add a test:** drop a `check()` or `xfail()` call in the right `Tests/*.swift` file, follow the `PREFIX-NNN` ID convention
- **Run your test:** `swift run SocktainerProbeCli -- --list` to verify it appears, `--only YOUR-ID` to run it
- **Map it to an API endpoint:** add an entry to `routeTestMap` in `APICoverage.swift` so Coverage shows it as covered
- **Platform status corrections:** adjust `platformLimitationPaths`, `doableWithWorkaroundPaths`, or `methodNotApplicable` in `APICoverage.swift`

---

## License

MIT
