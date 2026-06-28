import Foundation
import SocktainerProbeCore

// MARK: - Display helpers

private func clearScreen() { print("\u{1B}[2J\u{1B}[H", terminator: "") }

private func relativeTime(_ date: Date) -> String {
    let secs = Int(-date.timeIntervalSinceNow)
    if secs < 60 { return "just now" }
    if secs < 3600 { return "\(secs / 60) min ago" }
    if secs < 86400 { return "\(secs / 3600) hr ago" }
    return "\(secs / 86400) days ago"
}

private func prompt(_ msg: String = "Choice") -> String {
    print("\(msg): ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
}

private func pressEnter() {
    print("\nPress Enter to return to menu…", terminator: "")
    _ = readLine()
}

// MARK: - Menu

func runInteractiveMenu(
    harness: SocktainerHarness,
    sock: DockerCLI,
    ref: DockerCLI,
    environment: RunEnvironment
) async {
    while true {
        clearScreen()
        printHeader(environment: environment)

        let lastIntegration = await Sessions.shared.last(kind: .integration)
        let lastParity      = await Sessions.shared.last(kind: .parity)
        let lastCompose     = await Sessions.shared.last(kind: .compose)
        let lastCoverage    = await Sessions.shared.last(kind: .coverage)

        printMenuItems(lastIntegration: lastIntegration, lastParity: lastParity,
                       lastCompose: lastCompose, lastCoverage: lastCoverage)

        let choice = prompt()
        switch choice {
        case "1":
            clearScreen()
            await menuConfigure()
        case "2":
            clearScreen()
            await menuIntegrationTests(harness: harness, sock: sock, ref: ref, environment: environment)
        case "3":
            clearScreen()
            await menuTestcontainers(sock: sock, environment: environment)
        case "4":
            clearScreen()
            await menuDevcontainer(sock: sock, environment: environment)
        case "5":
            clearScreen()
            await menuColimaParity(sock: sock, ref: ref, environment: environment)
        case "6":
            clearScreen()
            await menuCompose(sock: sock, environment: environment)
        case "7":
            clearScreen()
            await menuCoverage()
        case "8":
            clearScreen()
            await menuRunAll(harness: harness, sock: sock, ref: ref, environment: environment)
        case "f":
            clearScreen()
            await menuFilterTests(sock: sock, ref: ref, environment: environment)
        case "9", "q", "":
            await harness.stop()
            print("\nBye! Sessions saved in \(await Sessions.shared.sessionsDir().path)\n")
            return
        default:
            continue
        }
        pressEnter()
    }
}

private func printHeader(environment: RunEnvironment) {
    print("socktainer-probe v\(environment.socktainerCheckVersion)  ·  \(environment.machineSummary)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()
}

private func printMenuItems(
    lastIntegration: SessionRecord?, lastParity: SessionRecord?,
    lastCompose: SessionRecord?, lastCoverage: SessionRecord?
) {
    func hint(_ record: SessionRecord?) -> String {
        guard let r = record else { return "" }
        return "  \u{1B}[90m(\(r.summary) · \(relativeTime(r.timestamp)))\u{1B}[0m"
    }

    print("  1  Configure")
    print("  2  Integration tests\(hint(lastIntegration))")
    print("  3  Testcontainers patterns")
    print("  4  Devcontainer patterns")
    print("  5  Colima parity\(hint(lastParity))")
    print("  6  Docker Compose scenarios\(hint(lastCompose))")
    print("  7  Docker API coverage\(hint(lastCoverage))")
    print("  8  Run all  \u{1B}[90m(integration + compose + parity + coverage)\u{1B}[0m")
    print("  f  Filter & run tests  \u{1B}[90m(fuzzy search by description)\u{1B}[0m")
    print("  9  Exit")
    print()
}

// MARK: - Menu actions

private func menuRunAll(
    harness: SocktainerHarness, sock: DockerCLI, ref: DockerCLI,
    environment: RunEnvironment
) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable. Start it first or configure a binary.")
        return
    }
    print("\n═══ 1/4 · Integration tests (incl. Testcontainers + Devcontainer) ═══")
    await menuIntegrationTests(harness: harness, sock: sock, ref: ref, environment: environment)
    print("\n═══ 2/4 · Docker Compose scenarios ═══")
    await menuCompose(sock: sock, environment: environment)
    print("\n═══ 3/4 · Colima parity ═══")
    resetResults()
    await menuColimaParity(sock: sock, ref: ref, environment: environment)
    print("\n═══ 4/4 · Docker API coverage ═══")
    await menuCoverage()
    print("\n✅ Run all complete — see per-phase reports in \(await Sessions.shared.sessionsDir().path)")
}

private func menuConfigure() async {
    do { try runConfig() } catch { print("❌ \(error.localizedDescription)") }
    let record = SessionRecord(id: UUID().uuidString, timestamp: Date(),
                               kind: .config, summary: "configured", reportPath: nil)
    try? await Sessions.shared.save(record)
}

private func menuIntegrationTests(
    harness: SocktainerHarness, sock: DockerCLI, ref: DockerCLI,
    environment: RunEnvironment
) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable. Start it first or configure a binary.")
        return
    }
    await runIntegrationTests(sock: sock, ref: ref, environment: environment)
    await saveAndPrint(environment: environment, kind: .integration)
}

private func menuTestcontainers(sock: DockerCLI, environment: RunEnvironment) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable.")
        return
    }
    resetResults()
    markRunStart()
    section("Testcontainers patterns")
    await runTestcontainerSection(sock: sock)
    await saveAndPrint(environment: environment, kind: .integration)
}

private func menuDevcontainer(sock: DockerCLI, environment: RunEnvironment) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable.")
        return
    }
    resetResults()
    markRunStart()
    section("Devcontainer patterns")
    await runDevcontainerSection(sock: sock)
    await saveAndPrint(environment: environment, kind: .integration)
}

private func menuColimaParity(sock: DockerCLI, ref: DockerCLI, environment: RunEnvironment) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable.")
        return
    }
    resetResults()
    markRunStart()
    await runParityTests(sock: sock, ref: ref)
    await saveAndPrint(environment: environment, kind: .parity)
}

private func menuCompose(sock: DockerCLI, environment: RunEnvironment) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable.")
        return
    }
    await runComposeTests(sock: sock, environment: environment)
    await saveAndPrint(environment: environment, kind: .compose)
}

private func menuCoverage() async {
    let config = CheckConfig.load()
    let sourceDir = config?.socktainerSource?.sourceDirForCoverage
    await runCoverageCheck(socktainerSourceDir: sourceDir)
    let record = SessionRecord(
        id: UUID().uuidString, timestamp: Date(), kind: .coverage,
        summary: "coverage computed", reportPath: nil
    )
    try? await Sessions.shared.save(record)
}

// MARK: - Shared helpers

private func menuFilterTests(sock: DockerCLI, ref: DockerCLI, environment: RunEnvironment) async {
    guard (try? await sock.ping()) == true else {
        print("❌ Socktainer unreachable.")
        return
    }

    print("Filter & run tests")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("Search (fuzzy, subsequence): ", terminator: "")
    guard let query = readLine()?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
        print("Cancelled.")
        return
    }

    // Collect all tests silently.
    collectMode = true
    await runIntegrationTests(sock: sock, ref: ref, environment: environment)
    let all = collectedTestDescriptors()
    collectMode = false
    resetResults()

    // Fuzzy filter: every character in query must appear in order in the test name.
    func matches(_ name: String) -> Bool {
        var qIdx = query.startIndex
        for ch in name.lowercased() {
            guard qIdx < query.endIndex else { break }
            if ch == query.lowercased()[qIdx] { qIdx = query.index(after: qIdx) }
        }
        return qIdx == query.endIndex
    }

    let filtered = all.filter { matches($0.name) }
    guard !filtered.isEmpty else {
        print("\nNo tests match \"\(query)\".")
        return
    }

    // Show grouped results.
    print("\n\u{1B}[90mFound \(filtered.count) match(es):\u{1B}[0m\n")
    var lastSection = ""
    for (i, t) in filtered.enumerated() {
        if t.section != lastSection {
            print("  \u{1B}[90m── \(t.section) ──\u{1B}[0m")
            lastSection = t.section
        }
        let idPart = t.id.map { "[\($0)] " } ?? ""
        print("  \(i + 1)  \(idPart)\(t.name)")
    }

    print()
    print("Run which? (all / numbers like 1,3,5): ", terminator: "")
    let sel = readLine()?.trimmingCharacters(in: .whitespaces) ?? "all"

    if sel.lowercased() == "all" || sel.isEmpty {
        testNameFilter = query
    } else {
        let indices = sel.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 1 && $0 <= filtered.count }
        guard !indices.isEmpty else { print("Invalid selection."); return }
        testNameSetFilter = Set(indices.map { filtered[$0 - 1].name })
    }

    print()
    resetResults()
    markRunStart()
    await runIntegrationTests(sock: sock, ref: ref, environment: environment)
    clearFilters()
    await saveAndPrint(environment: environment, kind: .integration)
}

private func saveAndPrint(environment: RunEnvironment, kind: SessionRecord.Kind) async {
    let report = buildReport(environment: environment)
    let path = try? await Sessions.shared.saveReport(report, kind: kind)
    let summary = "\(report.passed)/\(report.passed + report.failed) passed"
    let record = SessionRecord(id: UUID().uuidString, timestamp: Date(),
                               kind: kind, summary: summary, reportPath: path?.path)
    try? await Sessions.shared.save(record)
    printSummary(report: report, path: path)
}

private func printSummary(report: RunReport, path: URL?) {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("Results: \(report.passed) passed, \(report.failed) failed, \(report.skipped) skipped")
    if let p = path { print("Session: \(p.path)") }
    if report.failed > 0 { report.printIssueMarkdown() }
}
