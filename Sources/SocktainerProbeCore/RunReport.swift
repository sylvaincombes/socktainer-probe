import Foundation

// MARK: - Machine + version info

public struct RunEnvironment: Codable {
    public let hardwareModel: String   // e.g. "Mac17,2"
    public let cpuBrand: String        // e.g. "Apple M5"
    public let ramGB: Int              // e.g. 32
    public let macosVersion: String
    public let socktainerVersion: String
    public let appleContainerVersion: String
    public var socktainerCheckVersion: String = "0.1.0"

    /// Human-readable machine summary e.g. "Apple M5 · 32 GB RAM · Mac17,2"
    public var machineSummary: String { "\(cpuBrand) · \(ramGB) GB RAM · \(hardwareModel)" }

    public init(
        hardwareModel: String, cpuBrand: String, ramGB: Int,
        macosVersion: String, socktainerVersion: String, appleContainerVersion: String,
        socktainerCheckVersion: String = "0.1.0"
    ) {
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        self.ramGB = ramGB
        self.macosVersion = macosVersion
        self.socktainerVersion = socktainerVersion
        self.appleContainerVersion = appleContainerVersion
        self.socktainerCheckVersion = socktainerCheckVersion
    }

    public static func collect(using docker: DockerCLI) async -> RunEnvironment {
        let hardwareModel = sysctl("hw.model") ?? "unknown"
        let cpuBrand = sysctl("machdep.cpu.brand_string") ?? appleChipName()
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Int(ramBytes / (1024 * 1024 * 1024))
        let macosVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let (socktainerVersion, appleContainerVersion) = await resolveVersions(docker: docker)

        return RunEnvironment(
            hardwareModel: hardwareModel,
            cpuBrand: cpuBrand,
            ramGB: ramGB,
            macosVersion: macosVersion,
            socktainerVersion: socktainerVersion,
            appleContainerVersion: appleContainerVersion
        )
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf).trimmingCharacters(in: .whitespaces)
    }

    private static func appleChipName() -> String {
        // On Apple Silicon, hw.model gives Mac17,2 etc. Map to chip name via system_profiler.
        guard let data = try? Process.output("/usr/sbin/system_profiler", "SPHardwareDataType"),
            let output = String(data: data, encoding: .utf8)
        else { return "Apple Silicon" }
        if let line = output.split(separator: "\n").first(where: { $0.contains("Chip") }) {
            return line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "Apple Silicon"
        }
        return "Apple Silicon"
    }

    private static func resolveVersions(docker: DockerCLI) async -> (String, String) {
        guard let raw = try? await docker.info() else { return ("unknown", "unknown") }
        let sock = raw.split(separator: "\n").first.map(String.init) ?? "unknown"
        let apple = (try? String(data: Process.output("/usr/local/bin/container", "--version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return (sock, apple)
    }
}

// MARK: - Test result

public struct TestResult: Codable {
    public let id: String?          // e.g. "CTR-001" — stable reference for AI/issue discussions
    public let name: String
    public let status: TestStatus
    public let durationMs: Int
    public let failureReason: String?
    public let reproCommand: String?
    public let section: String
    public let refs: [String]       // e.g. ["#220", "#221"] — PRs or issues this test covers
}

public enum TestStatus: String, Codable {
    case passed, failed, skipped, knownFailure, unexpectedPass
}

// MARK: - Full report

public struct RunReport: Codable {
    public let runId: String
    public let timestamp: String
    public let environment: RunEnvironment
    public let results: [TestResult]

    public init(runId: String, timestamp: String, environment: RunEnvironment, results: [TestResult]) {
        self.runId = runId; self.timestamp = timestamp
        self.environment = environment; self.results = results
    }

    public var passed: Int { results.filter { $0.status == .passed }.count }
    public var failed: Int { results.filter { $0.status == .failed }.count }
    public var skipped: Int { results.filter { $0.status == .skipped }.count }
    public var knownFailures: Int { results.filter { $0.status == .knownFailure }.count }
    public var unexpectedPasses: Int { results.filter { $0.status == .unexpectedPass }.count }

    public func save() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".socktainer-probe/runs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(runId).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file)
        print("\n📄 Report saved: \(file.path)")
    }

    public func printIssueMarkdown() {
        guard failed > 0 else { return }
        let failures = results.filter { $0.status == .failed }
        print("\n### 🐛 Paste-ready GitHub issue for \(failed) failure(s)\n")
        print("```markdown")
        print("**[Bug]:** Socktainer check failures — \(failures.map(\.name).joined(separator: ", "))\n")
        print("## Environment\n")
        print("- macOS: \(environment.macosVersion)")
        print("- Socktainer: \(environment.socktainerVersion)")
        print("- Apple Container: \(environment.appleContainerVersion)")
        print("- Machine: \(environment.machineSummary)\n")
        print("## Failures\n")
        for f in failures {
            let idLabel = f.id.map { " `\($0)`" } ?? ""
            print("### \(idLabel) `\(f.name)` (section: \(f.section))\n")
            if !f.refs.isEmpty {
                print("**Related:** \(f.refs.joined(separator: ", "))\n")
            }
            if let reason = f.failureReason {
                print("**Actual:** \(reason)\n")
            }
            print("**Reproduction:**")
            print("```sh")
            if let repro = f.reproCommand {
                print(repro)
            } else {
                print("# Run the socktainer-probe suite")
                print("cd ~/Projects/socktainer-probe && swift run")
            }
            print("```")
            print()
        }
        print("```")
    }
}

// MARK: - Regression diff

public struct TestDiff {
    public let id: String?
    public let name: String
    public let before: TestStatus
    public let after: TestStatus
}

public extension RunReport {
    /// Returns tests whose status changed between `previous` and this report.
    func diff(against previous: RunReport) -> [TestDiff] {
        let prevByName = Dictionary(uniqueKeysWithValues: previous.results.map { ($0.name, $0) })
        return results.compactMap { current in
            guard let prev = prevByName[current.name], prev.status != current.status else { return nil }
            return TestDiff(id: current.id, name: current.name, before: prev.status, after: current.status)
        }
    }

    func printDiff(_ diffs: [TestDiff]) {
        guard !diffs.isEmpty else { print("  No status changes since last run."); return }
        for d in diffs {
            let arrow = statusIcon(d.before) + " → " + statusIcon(d.after)
            let idLabel = d.id.map { "[\($0)] " } ?? ""
            print("  \(arrow)  \(idLabel)\(d.name)")
        }
    }

    private func statusIcon(_ s: TestStatus) -> String {
        switch s {
        case .passed: return "✅"
        case .failed: return "❌"
        case .skipped: return "⏭ "
        case .knownFailure: return "⚠️ "
        case .unexpectedPass: return "🎉"
        }
    }
}

// MARK: - JUnit XML

public extension RunReport {
    /// Generates a JUnit-compatible XML string for CI consumption.
    func junitXML() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<testsuites name=\"socktainer-probe\" tests=\"\(results.count)\" "
        xml += "failures=\"\(failed)\" skipped=\"\(skipped + knownFailures)\" "
        xml += "time=\"\(results.map { Double($0.durationMs) / 1000 }.reduce(0, +))\">\n"

        let sections = Dictionary(grouping: results, by: \.section)
        for (section, tests) in sections.sorted(by: { $0.key < $1.key }) {
            let sectionFailed = tests.filter { $0.status == .failed }.count
            let sectionSkipped = tests.filter { $0.status == .skipped || $0.status == .knownFailure }.count
            let sectionTime = tests.map { Double($0.durationMs) / 1000 }.reduce(0, +)
            xml += "  <testsuite name=\"\(escapeXML(section))\" tests=\"\(tests.count)\" "
            xml += "failures=\"\(sectionFailed)\" skipped=\"\(sectionSkipped)\" time=\"\(sectionTime)\">\n"
            for t in tests {
                let tname = t.id.map { "\($0) — " } ?? ""
                xml += "    <testcase name=\"\(escapeXML(tname + t.name))\" "
                xml += "classname=\"\(escapeXML(section))\" time=\"\(Double(t.durationMs) / 1000)\">\n"
                switch t.status {
                case .failed:
                    let msg = t.failureReason ?? "assertion failed"
                    xml += "      <failure message=\"\(escapeXML(msg))\"/>\n"
                case .skipped, .knownFailure:
                    let msg = t.failureReason ?? "skipped"
                    xml += "      <skipped message=\"\(escapeXML(msg))\"/>\n"
                default: break
                }
                xml += "    </testcase>\n"
            }
            xml += "  </testsuite>\n"
        }
        xml += "</testsuites>\n"
        return xml
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Process helpers

public extension Process {
    static func output(_ executable: String, _ args: String...) throws -> Data {
        try output(executable, args: args)
    }

    static func output(_ executable: String, args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
