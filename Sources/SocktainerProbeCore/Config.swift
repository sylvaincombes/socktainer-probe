import Foundation

// MARK: - Socktainer source

/// How the probe finds and optionally builds the Socktainer binary.
public enum SocktainerSource: Codable, CustomStringConvertible {
    /// A pre-built binary at a fixed path.
    case binary(path: String)
    /// A git checkout. The binary is derived as `{path}/.build/release/socktainer`.
    /// When `buildBeforeStart` is true, `make release` runs before each test session.
    case sourceFolder(path: String, buildBeforeStart: Bool)

    private enum CodingKeys: String, CodingKey { case type, path, buildBeforeStart }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let path = try c.decode(String.self, forKey: .path)
        if type == "sourceFolder" {
            let build = try c.decodeIfPresent(Bool.self, forKey: .buildBeforeStart) ?? true
            self = .sourceFolder(path: path, buildBeforeStart: build)
        } else {
            self = .binary(path: path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .binary(let path):
            try c.encode("binary", forKey: .type)
            try c.encode(path, forKey: .path)
        case .sourceFolder(let path, let build):
            try c.encode("sourceFolder", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(build, forKey: .buildBeforeStart)
        }
    }

    public var description: String {
        switch self {
        case .binary(let path):
            return "binary: \(path)"
        case .sourceFolder(let path, let build):
            return "source: \(path)" + (build ? " (build on start)" : "")
        }
    }

    /// Binary to launch for test sessions (derived from source path when needed).
    public var resolvedBinaryPath: String {
        switch self {
        case .binary(let path): return path
        case .sourceFolder(let path, _): return "\(path)/.build/release/socktainer"
        }
    }

    /// Source directory for API route coverage (nil for binary mode — no source available).
    public var sourceDirForCoverage: String? {
        switch self {
        case .binary: return nil
        case .sourceFolder(let path, _): return path
        }
    }
}

// MARK: - Config

public struct CheckConfig: Codable {
    public var dockerBinary: String
    public var socktainerSource: SocktainerSource?
    public var referenceContext: String

    public init(dockerBinary: String, socktainerSource: SocktainerSource?, referenceContext: String) {
        self.dockerBinary = dockerBinary
        self.socktainerSource = socktainerSource
        self.referenceContext = referenceContext
    }

    public static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".socktainer-probe/config.json")

    public static func load() -> CheckConfig? {
        guard let data = try? Data(contentsOf: configPath),
            let config = try? JSONDecoder().decode(CheckConfig.self, from: data)
        else { return nil }
        return config
    }

    public func save() throws {
        let dir = Self.configPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.configPath)
    }
}

// MARK: - Binary discovery

public struct DiscoveredBinary: CustomStringConvertible {
    public let path: String
    public let label: String
    public var description: String { "\(label) — \(path)" }
}

public func discoverDockerBinaries() -> [DiscoveredBinary] {
    let candidates: [(String, String)] = [
        ("/opt/homebrew/bin/docker", "Homebrew"),
        ("/usr/local/bin/docker", "/usr/local"),
        ("/usr/bin/docker", "/usr/bin"),
        ("/Applications/Docker.app/Contents/Resources/bin/docker", "Docker Desktop"),
    ]
    return candidates
        .filter { FileManager.default.isExecutableFile(atPath: $0.0) }
        .map { DiscoveredBinary(path: $0.0, label: $0.1) }
}

public func discoverSocktainerBinaries() -> [DiscoveredBinary] {
    var found: [DiscoveredBinary] = []
    let fm = FileManager.default
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    for path in ["/usr/local/bin/socktainer", "/opt/homebrew/bin/socktainer"]
        where fm.isExecutableFile(atPath: path) {
        found.append(DiscoveredBinary(path: path, label: "Installed"))
    }

    let projectsDir = "\(home)/Projects"
    if let projects = try? fm.contentsOfDirectory(atPath: projectsDir) {
        for project in projects.sorted() {
            for path in [
                "\(projectsDir)/\(project)/.build/debug/socktainer",
                "\(projectsDir)/\(project)/.build/release/socktainer",
                "\(projectsDir)/\(project)/bin/socktainer",
            ] where fm.isExecutableFile(atPath: path) {
                let variant = path.contains("release") ? "release" : "debug"
                found.append(DiscoveredBinary(path: path, label: "\(project) (\(variant))"))
            }
        }
    }

    return found
}

/// Discovers Swift projects under ~/Projects that look like Socktainer source trees
/// (have both Package.swift and Makefile with a `release:` target).
public func discoverSocktainerSources() -> [DiscoveredBinary] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let projectsDir = "\(home)/Projects"
    guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

    return projects.sorted().compactMap { project in
        let dir = "\(projectsDir)/\(project)"
        let hasPackage = fm.fileExists(atPath: "\(dir)/Package.swift")
        let hasMakefile = fm.fileExists(atPath: "\(dir)/Makefile")
        guard hasPackage && hasMakefile else { return nil }
        // Confirm a `release:` target exists in the Makefile.
        guard let makefile = try? String(contentsOfFile: "\(dir)/Makefile", encoding: .utf8),
              makefile.contains("release:") else { return nil }
        return DiscoveredBinary(path: dir, label: project)
    }
}

private func discoverDockerContexts(using dockerBinary: String) -> [String] {
    guard let data = try? Process.output(dockerBinary, "context", "ls", "--format", "{{.Name}}"),
        let output = String(data: data, encoding: .utf8)
    else { return ["colima", "default"] }
    return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

// MARK: - Interactive picker
// Returns the selected VALUE (path), not the display label.

private func pick(
    prompt: String,
    items: [(label: String, value: String)],
    defaultValue: String?,
    allowCustom: Bool = true
) -> String? {
    print(prompt)
    print()
    if let def = defaultValue {
        print("  0  \(def) (default)")
    }
    for (i, item) in items.enumerated() {
        print("  \(i + 1)  \(item.label)")
    }
    if allowCustom { print("  c  Enter a custom path") }
    print()
    let hint = defaultValue.map { " [\($0)]" } ?? ""
    print("Choice\(hint): ", terminator: "")

    let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    if input.isEmpty, let def = defaultValue { return def }
    if input == "0", let def = defaultValue { return def }
    if allowCustom && input.lowercased() == "c" {
        print("Path: ", terminator: "")
        let custom = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? nil : (custom as NSString).expandingTildeInPath
    }
    if let idx = Int(input), idx >= 1, idx <= items.count {
        return items[idx - 1].value
    }
    return input.isEmpty ? nil : input
}

// MARK: - Interactive setup

public func runConfig() throws {
    print("socktainer-probe — setup")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    // ── Docker CLI ────────────────────────────────────────────────────────────
    let dockerBinaries = discoverDockerBinaries()
    let currentDocker = DockerCLI.resolvedBinary
    let dockerBinary = pick(
        prompt: "Which docker CLI binary to use?",
        items: dockerBinaries.map { (label: $0.description, value: $0.path) },
        defaultValue: currentDocker
    ) ?? currentDocker
    print("→ \(dockerBinary)\n")

    // ── Socktainer source ─────────────────────────────────────────────────────
    print("How to launch Socktainer?")
    print()
    print("  0  Use currently-running instance")
    print("  b  Binary — point to a pre-built binary")
    print("  s  Source folder — build with `make release` from a git checkout")
    print()
    print("Choice [0]: ", terminator: "")
    let modeInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    print()

    let socktainerSource: SocktainerSource?
    switch modeInput {
    case "b":
        let binaries = discoverSocktainerBinaries()
        let choice = pick(
            prompt: "Which binary?",
            items: binaries.map { (label: $0.description, value: $0.path) },
            defaultValue: nil
        )
        if let path = choice {
            socktainerSource = .binary(path: path)
            print("→ \(path)\n")
        } else {
            socktainerSource = nil
            print("→ Using currently-running Socktainer\n")
        }

    case "s":
        let sources = discoverSocktainerSources()
        let choice = pick(
            prompt: "Which source folder?",
            items: sources.map { (label: $0.description, value: $0.path) },
            defaultValue: nil
        )
        if let path = choice {
            print()
            print("Build with `make release` before each test session? [y/N]: ", terminator: "")
            let buildInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let buildOnStart = buildInput == "y"
            socktainerSource = .sourceFolder(path: path, buildBeforeStart: buildOnStart)
            print("→ \(path)\(buildOnStart ? " (will run make release on start)" : "")\n")
        } else {
            socktainerSource = nil
            print("→ Using currently-running Socktainer\n")
        }

    default:
        socktainerSource = nil
        print("→ Using currently-running Socktainer\n")
    }

    // ── Reference context ─────────────────────────────────────────────────────
    let allContexts = discoverDockerContexts(using: dockerBinary)
    let refContexts = allContexts.filter { $0 != "socktainer" && $0 != "socktainer-probe" }
    let refDefault = refContexts.contains("colima") ? "colima" : refContexts.first
    let refChoice = pick(
        prompt: "Reference runtime for comparison?",
        items: refContexts.map { (label: $0, value: $0) },
        defaultValue: refDefault,
        allowCustom: true
    ) ?? "colima"
    print("→ \(refChoice)\n")

    // ── Save ──────────────────────────────────────────────────────────────────
    let config = CheckConfig(
        dockerBinary: dockerBinary,
        socktainerSource: socktainerSource,
        referenceContext: refChoice
    )
    try config.save()
    print("✅ Config saved to \(CheckConfig.configPath.path)")
    print()
    print("Run tests:    swift run")
    print("Show config:  swift run -- --show-config")
}
