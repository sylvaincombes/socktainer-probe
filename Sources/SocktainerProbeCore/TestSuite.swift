import Foundation

// MARK: - State

private var allResults: [TestResult] = []
private var currentSection = "General"
private let resultsMutex = NSLock()
private var runStartDate: Date = Date()

/// When set, only the test whose ID matches is executed; others are silently skipped.
public var testIDFilter: String? = nil

/// When set, only tests whose name contains all characters of the needle (subsequence) are run.
public var testNameFilter: String? = nil

/// When set, only tests whose exact name is in the set are run (used for multi-select from the filter menu).
public var testNameSetFilter: Set<String>? = nil

/// When true, tests are registered but bodies are not executed (for --list).
public var listMode: Bool = false

/// Like listMode but silent — bodies are skipped and results are collected without printing.
/// Used by the interactive filter menu to enumerate available tests.
public var collectMode: Bool = false

/// Call before a new run to clear previous results.
public func resetResults() {
    resultsMutex.lock(); defer { resultsMutex.unlock() }
    allResults = []
    currentSection = "General"
}

/// Records the wall-clock start time of the run.
public func markRunStart() {
    runStartDate = Date()
}

/// Returns the wall-clock elapsed time since `markRunStart()` in seconds.
public func elapsedSeconds() -> Double {
    Date().timeIntervalSince(runStartDate)
}

/// Called with each result as it completes. Set by the GUI; nil falls back to terminal-only output.
public nonisolated(unsafe) var testResultCallback: (@Sendable (TestResult) -> Void)? = nil

private func appendResult(_ result: TestResult) {
    resultsMutex.lock(); defer { resultsMutex.unlock() }
    allResults.append(result)
    testResultCallback?(result)
}

// MARK: - Public API

/// Clears all filter state. Call after a filtered run to restore normal behaviour.
public func clearFilters() {
    testIDFilter = nil
    testNameFilter = nil
    testNameSetFilter = nil
}

/// Returns the (id, name, section) of every registered test after a collectMode run.
public func collectedTestDescriptors() -> [(id: String?, name: String, section: String)] {
    resultsMutex.lock(); defer { resultsMutex.unlock() }
    return allResults.map { (id: $0.id, name: $0.name, section: $0.section) }
}

/// Subsequence fuzzy match: every character in `needle` must appear in `haystack` in order.
private func fuzzyMatch(_ needle: String, in haystack: String) -> Bool {
    let n = needle.lowercased(), h = haystack.lowercased()
    var nIdx = n.startIndex
    for char in h {
        guard nIdx < n.endIndex else { break }
        if char == n[nIdx] { nIdx = n.index(after: nIdx) }
    }
    return nIdx == n.endIndex
}

public func section(_ title: String) {
    currentSection = title
    if !collectMode { print("\n=== \(title) ===") }
}

public func check(
    _ name: String,
    id: String? = nil,
    refs: [String] = [],
    repro: String? = nil,
    _ body: () async throws -> Void
) async {
    if let filter = testIDFilter, id != filter { return }
    if let filter = testNameFilter, !fuzzyMatch(filter, in: name) { return }
    if let filter = testNameSetFilter, !filter.contains(name) { return }
    let label = id.map { "[\($0)] " } ?? ""
    if listMode || collectMode {
        if listMode { print("  \(label)\(name)  \(refs.isEmpty ? "" : refs.joined(separator: " "))") }
        appendResult(TestResult(id: id, name: name, status: .passed, durationMs: 0,
                                     failureReason: nil, reproCommand: repro,
                                     section: currentSection, refs: refs))
        return
    }
    let start = Date()
    do {
        try await body()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  ✅ \(label)\(name)")
        appendResult(TestResult(id: id, name: name, status: .passed, durationMs: ms,
                                     failureReason: nil, reproCommand: nil,
                                     section: currentSection, refs: refs))
    } catch CheckError.assertionFailed(let msg) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  ❌ \(label)\(name): \(msg)")
        appendResult(TestResult(id: id, name: name, status: .failed, durationMs: ms,
                                     failureReason: msg, reproCommand: repro,
                                     section: currentSection, refs: refs))
    } catch {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let msg = error.localizedDescription
        print("  ❌ \(label)\(name): \(msg)")
        appendResult(TestResult(id: id, name: name, status: .failed, durationMs: ms,
                                     failureReason: msg, reproCommand: repro,
                                     section: currentSection, refs: refs))
    }
}

public func skip(_ name: String, id: String? = nil, reason: String) {
    if let filter = testIDFilter, id != filter { return }
    if let filter = testNameFilter, !fuzzyMatch(filter, in: name) { return }
    if let filter = testNameSetFilter, !filter.contains(name) { return }
    let label = id.map { "[\($0)] " } ?? ""
    if listMode || collectMode {
        if listMode { print("  \(label)\(name)  (skip: \(reason))") }
        return
    }
    print("  ⏭  \(label)\(name) — \(reason)")
    appendResult(TestResult(id: id, name: name, status: .skipped, durationMs: 0,
                                 failureReason: reason, reproCommand: nil,
                                 section: currentSection, refs: []))
}

/// Marks a test as an expected failure (known bug, pending PR, etc.).
/// - If it fails → shown as ⚠️  (known failure — not a regression)
/// - If it passes → shown as 🎉 (unexpected pass — the fix may have landed)
public func xfail(
    _ name: String,
    id: String? = nil,
    refs: [String] = [],
    reason: String,
    repro: String? = nil,
    _ body: () async throws -> Void
) async {
    if let filter = testIDFilter, id != filter { return }
    if let filter = testNameFilter, !fuzzyMatch(filter, in: name) { return }
    if let filter = testNameSetFilter, !filter.contains(name) { return }
    let label = id.map { "[\($0)] " } ?? ""
    if listMode || collectMode {
        if listMode { print("  \(label)\(name)  [xfail: \(reason)]  \(refs.isEmpty ? "" : refs.joined(separator: " "))") }
        appendResult(TestResult(id: id, name: name, status: .knownFailure, durationMs: 0,
                                     failureReason: reason, reproCommand: repro,
                                     section: currentSection, refs: refs))
        return
    }
    let start = Date()
    do {
        try await body()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  🎉 \(label)\(name) — UNEXPECTED PASS (was: \(reason))")
        appendResult(TestResult(id: id, name: name, status: .unexpectedPass, durationMs: ms,
                                     failureReason: "Was expected to fail: \(reason)",
                                     reproCommand: repro, section: currentSection, refs: refs))
    } catch {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  ⚠️  \(label)\(name) — \(reason)")
        appendResult(TestResult(id: id, name: name, status: .knownFailure, durationMs: ms,
                                     failureReason: reason, reproCommand: repro,
                                     section: currentSection, refs: refs))
    }
}

public func buildReport(environment: RunEnvironment) -> RunReport {
    RunReport(
        runId: UUID().uuidString.lowercased(),
        timestamp: ISO8601DateFormatter().string(from: Date()),
        environment: environment,
        results: allResults
    )
}

// MARK: - Assertion helpers

public func assert(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.assertionFailed(message) }
}

public func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    if actual != expected {
        throw CheckError.assertionFailed("\(message) — expected \(expected), got \(actual)")
    }
}

public func assertContains(_ haystack: String, _ needle: String) throws {
    if !haystack.contains(needle) {
        throw CheckError.assertionFailed("'\(haystack)' does not contain '\(needle)'")
    }
}

// MARK: - Event helpers

/// Returns Attributes from the first event matching `action`. If `labelKey` is provided,
/// prefers an event that has that label (falls back to any matching event).
public func eventAttributes(events: [[String: Any]], action: String, labelKey: String? = nil, nameEquals: String? = nil) -> [String: String]? {
    let matching = events
        .filter { ($0["Action"] as? String) == action }
        .compactMap { event -> [String: String]? in
            guard let actor = event["Actor"] as? [String: Any],
                let attrs = actor["Attributes"] as? [String: String]
            else { return nil }
            return attrs
        }
        // `captureEvents` is global, so several containers' events of the same action
        // can land in one window. When the caller knows which container it cares about,
        // pin to that container's `name` attribute so we don't read a sibling's event.
        .filter { nameEquals == nil || $0["name"] == nameEquals }
    if let key = labelKey {
        return matching.first(where: { $0[key] != nil }) ?? matching.first
    }
    return matching.first
}

/// All distinct `Action` values present in a captured event stream.
public func eventActions(events: [[String: Any]]) -> Set<String> {
    Set(events.compactMap { $0["Action"] as? String })
}

/// The `Actor.ID` of the first event whose `Action` matches (and `Type` if given).
public func eventActorID(events: [[String: Any]], action: String, type: String? = nil) -> String? {
    events.first { event in
        (event["Action"] as? String) == action && (type == nil || (event["Type"] as? String) == type)
    }
    .flatMap { ($0["Actor"] as? [String: Any])?["ID"] as? String }
}

/// True when the stream contains at least one event with the given Action (and Type if given).
public func eventHasAction(events: [[String: Any]], action: String, type: String? = nil) -> Bool {
    events.contains { event in
        (event["Action"] as? String) == action && (type == nil || (event["Type"] as? String) == type)
    }
}
