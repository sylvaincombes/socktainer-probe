import Darwin
import Foundation
import SocktainerProbeCore

// ── .env auto-load ────────────────────────────────────────────────────────────
// Reads .env from the current working directory (if present). Shell exports and
// CI variables always take precedence over .env values.

private var dotenv: [String: String] = {
    let path = FileManager.default.currentDirectoryPath + "/.env"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eq])
        let value = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        result[key] = value
    }
    return result
}()

/// Resolves an environment variable: shell/CI env first, then .env file.
func envVar(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key] ?? dotenv[key]
}

// ── Argument parsing ──────────────────────────────────────────────────────────

let args = Array(CommandLine.arguments.dropFirst())

// Non-interactive flags (for CI/scripts)
let headless = args.contains("--no-interactive") || isatty(STDIN_FILENO) == 0

// --list: print all test IDs without running
if args.contains("--list") {
    listMode = true
    let config = CheckConfig.load()
    if let dockerBin = config?.dockerBinary { DockerCLI.configuredBinary = dockerBin }
    let sock = DockerCLI(context: "socktainer")
    let ref  = DockerCLI(context: config?.referenceContext ?? "colima")
    print("socktainer-probe — registered tests\n")
    print(String(repeating: "─", count: 60))
    await runIntegrationTests(sock: sock, ref: ref, environment: RunEnvironment(
        hardwareModel: "", cpuBrand: "", ramGB: 0, macosVersion: "", socktainerVersion: "",
        appleContainerVersion: ""))
    exit(0)
}

// --only <ID>: run a single test by ID
if let onlyIdx = args.firstIndex(of: "--only"), args.indices.contains(onlyIdx + 1) {
    testIDFilter = args[onlyIdx + 1]
}

// Coverage-only mode
if args.contains("--coverage") {
    let config = CheckConfig.load()
    if let dockerBin = config?.dockerBinary { DockerCLI.configuredBinary = dockerBin }
    // CLI --source flag takes precedence, then source derived from config
    let sourceDir = zip(args, args.dropFirst()).first(where: { $0.0 == "--source" })?.1
                 ?? config?.socktainerSource?.sourceDirForCoverage
    await runCoverageCheck(socktainerSourceDir: sourceDir)
    exit(0)
}

// Interactive config
if args.contains("--config") {
    do { try runConfig() } catch { print("❌ \(error.localizedDescription)") }
    exit(0)
}

// Show current config
if args.contains("--show-config") {
    let effectiveContext = envVar("REFERENCE_CONTEXT") ?? savedConfig?.referenceContext ?? "colima"
    let effectiveDocker = envVar("DOCKER_BINARY")
        ?? savedConfig?.dockerBinary
        ?? DockerCLI.resolvedBinary

    print("socktainer-probe — current configuration")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("Config file: \(CheckConfig.configPath.path)")
    print("Docker CLI:  \(effectiveDocker)")
    if let override = binaryArg ?? envVar("SOCKTAINER_BINARY") {
        print("Socktainer:  \(override) (CLI/env override)")
    } else if let src = savedConfig?.socktainerSource {
        print("Socktainer:  \(src)")
    } else {
        print("Socktainer:  (system — docker context: socktainer)")
    }
    print("Reference:   \(effectiveContext)")
    if !dotenv.isEmpty {
        print("\n.env overrides: \(dotenv.keys.sorted().joined(separator: ", "))")
    }
    print("\nTo reconfigure: swift run -- --config")
    exit(0)
}

// ── Resolve config ────────────────────────────────────────────────────────────

let binaryArg = zip(args, args.dropFirst()).first(where: { $0.0 == "--binary" })?.1
let savedConfig = CheckConfig.load()
let referenceContext = envVar("REFERENCE_CONTEXT") ?? savedConfig?.referenceContext ?? "colima"

if let dockerBin = savedConfig?.dockerBinary {
    DockerCLI.configuredBinary = dockerBin
}

// ── Harness setup ─────────────────────────────────────────────────────────────
// Priority: --binary CLI arg > SOCKTAINER_BINARY env > saved config source

// Flatten savedConfig?.socktainerSource (SocktainerSource??) into a plain optional.
let configSource: SocktainerSource? = savedConfig.flatMap { $0.socktainerSource }

let harness: SocktainerHarness
let shouldStartHarness: Bool
if let binary = binaryArg ?? envVar("SOCKTAINER_BINARY") {
    harness = SocktainerHarness.custom(binaryPath: binary)
    shouldStartHarness = true
} else {
    switch configSource {
    case .binary(let path):
        harness = SocktainerHarness.custom(binaryPath: path)
        shouldStartHarness = true
    case .sourceFolder(let path, let build):
        harness = SocktainerHarness.fromSource(sourcePath: path, buildBeforeStart: build)
        shouldStartHarness = true
    case nil:
        harness = SocktainerHarness.system()
        shouldStartHarness = false
    }
}
if shouldStartHarness {
    do { try await harness.start() } catch {
        print("❌  Failed to start Socktainer: \(error.localizedDescription)")
        exit(1)
    }
}

let sock = DockerCLI(context: harness.context)
let ref  = DockerCLI(context: referenceContext)

// ── Launch ────────────────────────────────────────────────────────────────────

if !headless {
    // Interactive menu
    guard (try? await sock.ping()) == true else {
        print("❌  Cannot reach Socktainer")
        print("    Tip: configure a binary with `swift run -- --config`")
        await harness.stop()
        exit(1)
    }
    let environment = await RunEnvironment.collect(using: sock)
    await runInteractiveMenu(harness: harness, sock: sock, ref: ref, environment: environment)
} else {
    // Headless/CI: run integration tests and exit
    guard (try? await sock.ping()) == true else {
        print("❌  Cannot reach Socktainer")
        await harness.stop()
        exit(1)
    }
    let environment = await RunEnvironment.collect(using: sock)
    // Parallel is the default; pass --sequential to force sequential mode.
    let useSequential = args.contains("--sequential")
    if useSequential {
        await runIntegrationTests(sock: sock, ref: ref, environment: environment)
    } else {
        await runIntegrationTestsParallel(sock: sock, ref: ref, environment: environment)
    }
    let elapsed = elapsedSeconds()
    let report = buildReport(environment: environment)

    // Save report before diff (so loadLastReport skips this one)
    let savedPath = try? await Sessions.shared.saveReport(report)

    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // Version annotation
    if let prev = await Sessions.shared.loadLastReport(),
        prev.environment.socktainerVersion != report.environment.socktainerVersion {
        print("⚡ Version changed: \(prev.environment.socktainerVersion) → \(report.environment.socktainerVersion)")
    }

    // Regression diff
    if let prev = await Sessions.shared.loadLastReport() {
        let diffs = report.diff(against: prev)
        if !diffs.isEmpty {
            print("\nChanges since last run:")
            report.printDiff(diffs)
        }
    }

    var summary = "\(report.passed) passed, \(report.failed) failed"
    if report.skipped > 0 { summary += ", \(report.skipped) skipped" }
    if report.knownFailures > 0 { summary += ", \(report.knownFailures) known failure(s) ⚠️" }
    if report.unexpectedPasses > 0 { summary += ", \(report.unexpectedPasses) unexpected pass(es) 🎉" }
    let elapsedStr = elapsed < 60
        ? String(format: "%.1fs", elapsed)
        : String(format: "%dm %02.0fs", Int(elapsed) / 60, elapsed.truncatingRemainder(dividingBy: 60))
    print("\nResults: \(summary)  ⏱ \(elapsedStr)")

    if report.unexpectedPasses > 0 {
        print("\n🎉 Unexpected passes — the fix may have landed, consider removing xfail:")
        for r in report.results where r.status == .unexpectedPass {
            let idLabel = r.id.map { "[\($0)] " } ?? ""
            print("  · \(idLabel)\(r.name)")
        }
    }

    // JUnit XML output
    let junitPath = zip(args, args.dropFirst()).first(where: { $0.0 == "--junit" })?.1
    if let junitPath {
        do {
            try report.junitXML().write(toFile: junitPath, atomically: true, encoding: .utf8)
            print("JUnit: \(junitPath)")
        } catch {
            print("⚠️  Failed to write JUnit XML: \(error.localizedDescription)")
        }
    }

    if let p = savedPath { print("Session: \(p.path)") }

    // ── Watch mode ────────────────────────────────────────────────────────────
    if args.contains("--watch") {
        let watchTarget = harness.binaryPath ?? SocktainerHarness.socketPath
        func mtime(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        var lastMtime = mtime(watchTarget)
        print("\n👀 Watch mode — monitoring \(watchTarget)")
        print("   Re-runs on file change. Ctrl+C to stop.\n")
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let current = mtime(watchTarget)
            guard current != lastMtime else { continue }
            lastMtime = current
            print("\n🔄 Change detected — re-running tests\n")
            resetResults()
            if useSequential {
                await runIntegrationTests(sock: sock, ref: ref, environment: environment)
            } else {
                await runIntegrationTestsParallel(sock: sock, ref: ref, environment: environment)
            }
            let watchElapsed = elapsedSeconds()
            let newReport = buildReport(environment: environment)
            _ = try? await Sessions.shared.saveReport(newReport)
            var s = "\(newReport.passed) passed, \(newReport.failed) failed"
            if newReport.knownFailures > 0 { s += ", \(newReport.knownFailures) known ⚠️" }
            if newReport.unexpectedPasses > 0 { s += ", \(newReport.unexpectedPasses) unexpected 🎉" }
            let watchElapsedStr = watchElapsed < 60
                ? String(format: "%.1fs", watchElapsed)
                : String(format: "%dm %02.0fs", Int(watchElapsed) / 60, watchElapsed.truncatingRemainder(dividingBy: 60))
            print("\nResults: \(s)  ⏱ \(watchElapsedStr)")
        }
    }

    await harness.stop()
    if report.failed > 0 { report.printIssueMarkdown(); exit(1) }
}
