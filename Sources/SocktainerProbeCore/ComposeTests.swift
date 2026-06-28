import Foundation

// MARK: - Check descriptor (parsed from *.check.yml)

public struct ComposeCheck {
    public let name: String
    public let expectUp: Bool
    public let expectPsContains: String
    public let expectDown: Bool
    public let skip: Bool
    public let skipReason: String

    public static func load(from path: String) -> ComposeCheck? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        func value(for key: String) -> String {
            content.split(separator: "\n")
                .first { $0.hasPrefix(key + ":") }
                .map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
                ?? ""
        }
        return ComposeCheck(
            name: value(for: "name").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            expectUp:         value(for: "expect_up") == "true",
            expectPsContains: value(for: "expect_ps_contains"),
            expectDown:       value(for: "expect_down") == "true",
            skip:             value(for: "skip") == "true",
            skipReason:       value(for: "skip_reason")
        )
    }
}

// MARK: - Runner

public func runComposeTests(sock: DockerCLI, environment: RunEnvironment) async {
    resetResults()
    section("Docker Compose")

    let resourceDir = composeResourceDir()
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: resourceDir) else {
        skip("Docker Compose (all)", reason: "Resources/docker-compose/ not found at \(resourceDir)")
        return
    }

    let composeFiles = files
        .filter { $0.hasSuffix(".yml") && !$0.hasSuffix(".check.yml") }
        .sorted()

    guard !composeFiles.isEmpty else {
        skip("Docker Compose (all)", reason: "no *.yml files in Resources/docker-compose/")
        return
    }

    for fileName in composeFiles {
        let composePath = "\(resourceDir)/\(fileName)"
        let checkPath   = composePath.replacingOccurrences(of: ".yml", with: ".check.yml")
        let meta = ComposeCheck.load(from: checkPath) ?? ComposeCheck(
            name: fileName, expectUp: true, expectPsContains: "",
            expectDown: true, skip: false, skipReason: ""
        )

        if meta.skip {
            skip(meta.name, reason: meta.skipReason.isEmpty ? "marked skip in .check.yml" : meta.skipReason)
            continue
        }

        let idPrefix = "CMP-" + (fileName.components(separatedBy: "-").first ?? "?")
        await runScenario(idPrefix: idPrefix, name: meta.name, composeFile: composePath, meta: meta, sock: sock)
    }
}

private func runScenario(idPrefix: String, name: String, composeFile: String, meta: ComposeCheck, sock: DockerCLI) async {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sck-compose-\(Int.random(in: 10000...99999))")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    // Copy compose file to tmp dir so docker compose uses a clean project name
    let tmpFile = tmpDir.appendingPathComponent("docker-compose.yml").path
    try? FileManager.default.copyItem(atPath: composeFile, toPath: tmpFile)

    if meta.expectUp {
        await check("\(name) — up", id: "\(idPrefix)-UP",
                    repro: "docker --context socktainer compose -f \(composeFile) up -d") {
            _ = try await sock.compose(file: tmpFile, "up", "-d")
        }
    }

    if !meta.expectPsContains.isEmpty {
        await check("\(name) — ps shows \(meta.expectPsContains)", id: "\(idPrefix)-PS",
                    repro: "docker --context socktainer compose -f \(composeFile) ps") {
            let psOut = try await sock.compose(file: tmpFile, "ps")
            try assert(psOut.contains(meta.expectPsContains), "'\(meta.expectPsContains)' visible in ps output")
        }
    }

    if meta.expectDown {
        await check("\(name) — down", id: "\(idPrefix)-DN",
                    repro: "docker --context socktainer compose -f \(composeFile) down") {
            _ = try await sock.compose(file: tmpFile, "down", "--remove-orphans")
        }
    } else {
        _ = try? await sock.compose(file: tmpFile, "down", "--remove-orphans")
    }

    try? FileManager.default.removeItem(at: tmpDir)
}

// MARK: - Path resolution

private func composeResourceDir() -> String {
    // currentDirectoryPath is the project root when invoked via `swift run`
    // Fallback: walk up from executable for direct binary invocation
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let cwdPath = cwd.appendingPathComponent("Resources/docker-compose").path
    if FileManager.default.fileExists(atPath: cwdPath) { return cwdPath }

    // Executable is at .build/{arch}/debug/SocktainerCheck — go up 4 levels
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
    let root = exe.deletingLastPathComponent()   // debug/
                  .deletingLastPathComponent()   // arch/
                  .deletingLastPathComponent()   // .build/
                  .deletingLastPathComponent()   // project root
    return root.appendingPathComponent("Resources/docker-compose").path
}
