import Foundation
import SocktainerProbeCore

@MainActor
@Observable
final class RunTestsViewModel {

    enum Suite: String, CaseIterable, Identifiable {
        case integration    = "Integration"
        case testcontainers = "Testcontainers"
        case devcontainers  = "Devcontainer"
        case supabase       = "Supabase"
        case compose        = "Compose"
        case parity         = "Parity"
        case all            = "All"
        var id: String { rawValue }
    }

    struct TestDescriptor: Identifiable {
        let id: String      // composite key for ForEach
        let testID: String? // e.g. "TC-006"
        let name: String
        let section: String

        init(testID: String?, name: String, section: String) {
            self.id = "\(section)/\(name)"
            self.testID = testID
            self.name = name
            self.section = section
        }
    }

    enum RunState { case idle, running, done(RunReport), failed(String) }

    // MARK: - State

    var selectedSuite: Suite = .integration
    var state: RunState = .idle
    var liveResults: [TestResult] = []
    var startDate: Date? = nil
    var totalExpected: Int = 0
    var suiteCounts: [Suite: Int] = [:]

    // Search
    var searchText: String = ""
    private(set) var allTests: [TestDescriptor] = []
    var selectedTestNames: Set<String> = []

    // Build progress (source-folder mode)
    var isBuilding: Bool = false
    var buildOutput: String = ""
    var buildSourcePath: String? = nil

    // Source-folder mode available (controls split Run button visibility)
    private(set) var isSourceFolderMode: Bool = false

    private var runTask: Task<Void, Never>?
    private var wasFilteredRun: Bool = false

    var isRunning: Bool { if case .running = state { true } else { false } }
    var report: RunReport? { if case .done(let r) = state { r } else { nil } }
    var failureMessage: String? { if case .failed(let m) = state { m } else { nil } }

    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var filteredTests: [TestDescriptor] {
        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        return allTests
            .filter { fuzzyMatch(query, in: $0.name.lowercased()) }
            .filter { seen.insert($0.name).inserted }   // deduplicate by name
    }

    var progress: Double? {
        guard totalExpected > 0 else { return nil }
        return min(1.0, Double(liveResults.count) / Double(totalExpected))
    }

    // MARK: - Fuzzy match (subsequence)

    private func fuzzyMatch(_ needle: String, in haystack: String) -> Bool {
        var nIdx = needle.startIndex
        for ch in haystack {
            guard nIdx < needle.endIndex else { break }
            if ch == needle[nIdx] { nIdx = needle.index(after: nIdx) }
        }
        return nIdx == needle.endIndex
    }

    // MARK: - Startup

    func loadSuiteCounts() async {
        // Sequential — both functions mutate global TestSuite state (listMode, collectMode, allResults)
        // and must not run concurrently.
        suiteCounts = await precountAllSuites()
        allTests    = await collectAllIntegrationTests()
        if case .sourceFolder = CheckConfig.load()?.socktainerSource { isSourceFolderMode = true }
    }

    // MARK: - Actions

    func start(filterNames: Set<String>? = nil, filterQuery: String? = nil, forceBuild: Bool = false) {
        guard !isRunning else { return }
        liveResults = []
        state = .running
        startDate = Date()
        wasFilteredRun = filterNames != nil || filterQuery != nil

        let effectiveSuite: Suite = wasFilteredRun ? .integration : selectedSuite

        if let names = filterNames {
            totalExpected = names.count
        } else if let query = filterQuery {
            let q = query.lowercased()
            totalExpected = allTests.filter { fuzzyMatch(q, in: $0.name.lowercased()) }.count
        } else {
            totalExpected = suiteCounts[effectiveSuite] ?? 0
        }

        testResultCallback = { @Sendable result in
            Task { @MainActor [weak self] in self?.liveResults.append(result) }
        }

        runTask = Task.detached(priority: .userInitiated) { [weak self, effectiveSuite, filterNames, filterQuery, forceBuild] in
            await self?.executeDetached(suite: effectiveSuite, filterNames: filterNames,
                                        filterQuery: filterQuery, forceBuild: forceBuild)
        }
    }

    func startWithBuild() { start(forceBuild: true) }

    func runSelectedTests() {
        guard !selectedTestNames.isEmpty else { return }
        start(filterNames: selectedTestNames)
    }

    func runAllMatches() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        start(filterQuery: query)
    }

    func toggleAllFiltered() {
        let filtered = filteredTests
        if selectedTestNames.count == filtered.count && filtered.allSatisfy({ selectedTestNames.contains($0.name) }) {
            selectedTestNames = []
        } else {
            selectedTestNames = Set(filtered.map(\.name))
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        testResultCallback = nil
        clearFilters()
        state = .idle
        startDate = nil
        totalExpected = 0
    }

    func reset() { stop(); liveResults = [] }

    // MARK: - Execution (off main actor)

    nonisolated func executeDetached(
        suite: Suite,
        filterNames: Set<String>? = nil,
        filterQuery: String? = nil,
        forceBuild: Bool = false
    ) async {
        let config = CheckConfig.load()
        if let bin = config?.dockerBinary { DockerCLI.configuredBinary = bin }

        let configSource: SocktainerSource? = config.flatMap { $0.socktainerSource }
        let harness: SocktainerHarness
        let shouldStart: Bool
        switch configSource {
        case .binary(let path):
            harness = SocktainerHarness.custom(binaryPath: path)
            shouldStart = true
        case .sourceFolder(let path, let build):
            harness = SocktainerHarness.fromSource(sourcePath: path, buildBeforeStart: build || forceBuild)
            shouldStart = true
        case nil:
            harness = SocktainerHarness.system()
            shouldStart = false
        }
        if shouldStart {
            // Wire build output to the UI when in source-folder mode.
            if case .sourceFolder(let path, let build) = configSource, build || forceBuild {
                await MainActor.run { [weak self] in
                    self?.isBuilding = true
                    self?.buildOutput = ""
                    self?.buildSourcePath = path
                }
                harness.buildProgressCallback = { @Sendable [weak self] chunk in
                    Task { @MainActor [weak self] in self?.buildOutput += chunk }
                }
            }

            do {
                try await harness.start()
            } catch {
                await MainActor.run { [weak self] in self?.isBuilding = false }
                await finish(.failed("Failed to start Socktainer: \(error.localizedDescription)"))
                return
            }
            await MainActor.run { [weak self] in self?.isBuilding = false }
            harness.buildProgressCallback = nil
        }

        let sockContext = await harness.context
        let sock = DockerCLI(context: sockContext)
        let ref  = DockerCLI(context: config?.referenceContext ?? "colima")

        guard (try? await sock.ping()) == true else {
            await harness.stop()
            await finish(.failed("Cannot reach Socktainer. Is it running?"))
            return
        }

        let environment = await RunEnvironment.collect(using: sock)

        // Apply search filter before running.
        if let names = filterNames { testNameSetFilter = names }
        else if let query = filterQuery { testNameFilter = query }

        switch suite {
        case .integration:
            await runIntegrationTestsParallel(sock: sock, ref: ref, environment: environment)
        case .testcontainers:
            resetResults(); markRunStart()
            section("Testcontainers patterns")
            await runTestcontainerSection(sock: sock)
        case .supabase:
            resetResults(); markRunStart()
            await runSupabaseSection(sock: sock)
        case .devcontainers:
            resetResults(); markRunStart()
            section("Devcontainer patterns")
            await runDevcontainerSection(sock: sock)
        case .compose:
            resetResults(); markRunStart()
            await runComposeTests(sock: sock, environment: environment)
        case .parity:
            resetResults(); markRunStart()
            await runParityTests(sock: sock, ref: ref)
        case .all:
            await runIntegrationTestsParallel(sock: sock, ref: ref, environment: environment)
            await runComposeTests(sock: sock, environment: environment)
            resetResults(); markRunStart()
            await runParityTests(sock: sock, ref: ref)
        }

        // Always clear filters after run.
        clearFilters()

        let capturedResults = await MainActor.run { [weak self] in self?.liveResults ?? [] }
        let rep = RunReport(
            runId: UUID().uuidString.lowercased(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            environment: environment,
            results: capturedResults
        )

        testResultCallback = nil
        await harness.stop()

        guard !Task.isCancelled else { await finish(.idle); return }

        _ = try? await Sessions.shared.saveReport(rep, kind: suite.sessionKind)
        await finish(.done(rep))
    }

    private func finish(_ newState: RunState) {
        state = newState
        if wasFilteredRun {
            // Clear search so the content area switches to the normal results view.
            searchText = ""
            selectedTestNames = []
            wasFilteredRun = false
        }
    }
}

// MARK: - Test enumeration (list/collect mode, no docker needed)

func precountAllSuites() async -> [RunTestsViewModel.Suite: Int] {
    let dummy = DockerCLI(context: "dummy")
    let dummyEnv = RunEnvironment(
        hardwareModel: "", cpuBrand: "", ramGB: 0,
        macosVersion: "", socktainerVersion: "", appleContainerVersion: ""
    )
    var counts: [RunTestsViewModel.Suite: Int] = [:]
    for suite in RunTestsViewModel.Suite.allCases {
        counts[suite] = await countSuite(suite, sock: dummy, ref: dummy, environment: dummyEnv)
    }
    return counts
}

/// Collects all integration test descriptors silently using collectMode.
func collectAllIntegrationTests() async -> [RunTestsViewModel.TestDescriptor] {
    let dummy = DockerCLI(context: "dummy")
    let dummyEnv = RunEnvironment(
        hardwareModel: "", cpuBrand: "", ramGB: 0,
        macosVersion: "", socktainerVersion: "", appleContainerVersion: ""
    )
    let savedCallback = testResultCallback
    testResultCallback = nil
    collectMode = true
    resetResults()
    await runIntegrationTests(sock: dummy, ref: dummy, environment: dummyEnv)
    let descs = collectedTestDescriptors()
    collectMode = false
    resetResults()
    testResultCallback = savedCallback
    return descs.map { RunTestsViewModel.TestDescriptor(testID: $0.id, name: $0.name, section: $0.section) }
}

private func countSuite(
    _ suite: RunTestsViewModel.Suite,
    sock: DockerCLI, ref: DockerCLI,
    environment: RunEnvironment
) async -> Int {
    let savedCallback = testResultCallback
    listMode = true
    testResultCallback = nil
    resetResults()

    if suite == .all {
        listMode = false
        testResultCallback = savedCallback
        let iCount = await countSuite(.integration,    sock: sock, ref: ref, environment: environment)
        let cCount = await countSuite(.compose,        sock: sock, ref: ref, environment: environment)
        let pCount = await countSuite(.parity,         sock: sock, ref: ref, environment: environment)
        return iCount + cCount + pCount
    }

    switch suite {
    case .integration:
        await runIntegrationTests(sock: sock, ref: ref, environment: environment)
    case .testcontainers:
        await runTestcontainerSection(sock: sock)
    case .supabase:
        await runSupabaseSection(sock: sock)
    case .devcontainers:
        await runDevcontainerSection(sock: sock)
    case .compose:
        await runComposeTests(sock: sock, environment: environment)
    case .parity:
        await runParityTests(sock: sock, ref: ref)
    case .all:
        break
    }

    let count = buildReport(environment: environment).results.count
    listMode = false
    testResultCallback = savedCallback
    resetResults()
    return count
}

// MARK: - Helpers

private extension RunTestsViewModel.Suite {
    var sessionKind: SessionRecord.Kind {
        switch self {
        case .integration:    .integration
        case .testcontainers: .integration
        case .supabase:       .integration
        case .devcontainers:  .integration
        case .compose:        .compose
        case .parity:         .parity
        case .all:            .integration
        }
    }
}
