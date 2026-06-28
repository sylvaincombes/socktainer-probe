import Foundation

// MARK: - Endpoint status

public enum EndpointStatus: String, Codable {
    case implemented           // registered in Socktainer source and verified working
    case stub                  // registered but known stub (swarm routes etc.)
    case notImplemented        // in swagger, no known blocker — just needs implementation
    case notApplicable         // structurally impossible (swarm, Docker Desktop, BuildKit)
    case platformLimitation    // Apple Container 1.0 does not support this natively
    case doableWithWorkaround  // feasible with a platform-level trick (not yet done)
}

public struct EndpointResult: Identifiable {
    public var id: String { "\(method) \(path)" }
    public let method: String
    public let path: String
    public let status: EndpointStatus
    public let note: String?
    public let testID: String?
    public let operationId: String?   // from swagger, for docs URL
    public let docTag: String?        // from swagger tags[0]

    public var docsURL: URL? {
        guard let opId = operationId else { return nil }
        return URL(string: "https://docs.docker.com/engine/api/v1.51/#operation/\(opId)")
    }

    public init(method: String, path: String, status: EndpointStatus, note: String?,
                testID: String? = nil, operationId: String? = nil, docTag: String? = nil) {
        self.method = method; self.path = path
        self.status = status; self.note = note; self.testID = testID
        self.operationId = operationId; self.docTag = docTag
    }
}

public struct CoverageSummary {
    public let total: Int
    public let implemented: Int
    public let notImplemented: Int
    public let notApplicable: Int
    public let stubs: Int
    public let testedCount: Int         // implemented endpoints with a test ID
    public let doableWithWorkaround: Int // could be implemented with a workaround
    public let platformLimitations: Int  // blocked by Apple Container platform

    public var testable: Int { total - notApplicable - platformLimitations - doableWithWorkaround }
    public var implementedPct: Int { testable > 0 ? Int(Double(implemented) * 100 / Double(testable)) : 0 }
    public var testedPct: Int { implemented > 0 ? Int(Double(testedCount) * 100 / Double(implemented)) : 0 }
}

/// Returns structured coverage results without printing. Used by the GUI.
public func computeCoverageResults(
    socktainerSourceDir: String? = nil,
    githubRepoURL: String? = nil
) async -> (results: [EndpointResult], summary: CoverageSummary, sourceFound: Bool) {
    guard let endpoints = try? await fetchSwaggerEndpoints() else {
        return ([], CoverageSummary(total:0,implemented:0,notImplemented:0,notApplicable:0,stubs:0,testedCount:0,doableWithWorkaround:0,platformLimitations:0), false)
    }

    // 1. Try local source directory
    let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/socktainer/Sources/socktainer/Routes").path
    let localDir = socktainerSourceDir ?? defaultDir
    var extracted = extractSocktainerRoutes(from: localDir)

    // 2. Fallback: fetch from GitHub
    if extracted.all.isEmpty, let repoURL = githubRepoURL {
        extracted = (try? await fetchSocktainerRoutesFromGitHub(repoURL: repoURL)) ?? ExtractedRoutes()
    }

    let implementedNorm = Set(extracted.implemented.map { normalizeSourcePath($0) })
    let stubNorm        = Set(extracted.stubs.map      { normalizeSourcePath($0) })
    let sourceFound     = !extracted.all.isEmpty

    var results: [EndpointResult] = []
    for ep in endpoints {
        let (method, path, operationId, tag) = ep
        let normalized = normalizeSwaggerPath(path)
        let status: EndpointStatus
        let note: String?

        let methodKey = "\(method) \(path)"
        if let methodNote = methodNotApplicable[methodKey] {
            status = .notApplicable
            note = methodNote
        } else if notApplicablePaths.contains(path) {
            status = .notApplicable
            note = "Swarm / Docker Desktop only — no Apple Container equivalent"
        } else if let limitation = platformLimitationPaths[path] {
            status = .platformLimitation
            note = limitation
        } else if stubNorm.contains(normalized) || extracted.stubs.contains(path) {
            status = .stub
            note = "Registered but returns 501 Not Implemented"
        } else if implementedNorm.contains(normalized) || extracted.implemented.contains(path) {
            status = .implemented
            note = nil
        } else if let workaround = doableWithWorkaroundPaths[path] {
            status = .doableWithWorkaround
            note = workaround
        } else {
            status = .notImplemented
            note = nil
        }
        let tid = routeTestID(method: method, path: path)
        results.append(EndpointResult(method: method, path: path, status: status, note: note,
                                       testID: tid, operationId: operationId, docTag: tag))
    }

    let impl      = results.filter { $0.status == .implemented }.count
    let na        = results.filter { $0.status == .notApplicable }.count
    let miss      = results.filter { $0.status == .notImplemented }.count
    let stubs     = results.filter { $0.status == .stub }.count
    let platLim   = results.filter { $0.status == .platformLimitation }.count
    let workaround = results.filter { $0.status == .doableWithWorkaround }.count
    let tested    = results.filter { $0.status == .implemented && $0.testID != nil }.count
    let summary   = CoverageSummary(total: results.count, implemented: impl,
                                     notImplemented: miss, notApplicable: na,
                                     stubs: stubs, testedCount: tested,
                                     doableWithWorkaround: workaround,
                                     platformLimitations: platLim)
    return (results, summary, sourceFound)
}

// MARK: - Known limitations (Apple Container structural)

private let notApplicablePaths: Set<String> = [
    // Swarm — no matching Apple Container capability
    "/swarm", "/swarm/init", "/swarm/join", "/swarm/leave", "/swarm/update",
    "/swarm/unlockkey", "/swarm/unlock",
    "/services", "/services/create", "/services/{id}", "/services/{id}/update", "/services/{id}/logs",
    "/tasks", "/tasks/{id}", "/tasks/{id}/logs",
    "/nodes", "/nodes/{id}", "/nodes/{id}/update",
    "/secrets", "/secrets/create", "/secrets/{id}", "/secrets/{id}/update",
    "/configs", "/configs/create", "/configs/{id}", "/configs/{id}/update",
    // Plugins — Apple Container plugin system is unrelated to Docker plugins
    "/plugins", "/plugins/privileges", "/plugins/pull",
    "/plugins/{name}/json", "/plugins/{name}", "/plugins/{name}/enable",
    "/plugins/{name}/disable", "/plugins/{name}/upgrade", "/plugins/create",
    "/plugins/{name}/push", "/plugins/{name}/set",
    // Session (BuildKit only)
    "/session",
]

/// Endpoints structurally unsupported by the Apple Container / Apple Virtualization framework.
private let platformLimitationPaths: [String: String] = [
    "/containers/{id}/pause":           "Apple Container 1.0 does not support process suspension (SIGSTOP on VMs)",
    "/containers/{id}/unpause":         "Apple Container 1.0 does not support process resumption (SIGCONT on VMs)",
    "/containers/{id}/export":          "Apple Container 1.0 does not support streaming container filesystem as tar",
    "/containers/{id}/checkpoint":      "CRIU checkpointing is not available on Apple Silicon / macOS",
    "/containers/{id}/checkpoint/{id}": "CRIU checkpointing is not available on Apple Silicon / macOS",
]

/// Endpoints that could be implemented with a platform-level workaround even on Apple Container 1.0.
/// Not blocked by the platform — needs creative implementation in Socktainer.
private let doableWithWorkaroundPaths: [String: String] = [
    "/commit":                        "Could snapshot container filesystem layers into a new image (no live process needed)",
    "/containers/{id}/rename":        "Could update stored container metadata — no OS-level process rename needed",
    "/containers/{id}/restart":       "Could be implemented as graceful stop + start with saved configuration",
    "/containers/{id}/top":           "Could exec 'ps' inside the container VM and parse output",
    "/containers/{id}/changes":       "Could diff container layer against image base to list changed paths",
    "/containers/{id}/update":        "Could update resource limits on the running VM (memory, CPU shares)",
    "/networks/{id}/connect":         "Could attach container network interface to the target network bridge",
    "/networks/{id}/disconnect":      "Could detach container network interface from the network bridge",
    "/containers/{id}/copy":          "Legacy alias for PUT /containers/{id}/archive",
]

/// Method-specific not-applicable endpoints (Swarm/CSI features routed to specific HTTP methods
/// on paths that are otherwise valid for other methods).
private let methodNotApplicable: [String: String] = [
    "PUT /volumes/{name}": "Swarm cluster volumes only (CSI) — Docker Swarm not supported on Apple Container",
]

// MARK: - Swagger parser

/// Bundled swagger path (committed to the repo, updated manually when Docker API changes).
private let bundledSwaggerPath: String = {
    // Resolve relative to the executable: ../../Resources/docker-api-v28.5.2.json
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/docker-api-v28.5.2.json").path
    if FileManager.default.fileExists(atPath: cwdPath) { return cwdPath }
    // Fallback for direct binary: go up 4 levels from .build/arch/debug/bin
    let root = exe.deletingLastPathComponent().deletingLastPathComponent()
                  .deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("Resources/docker-api-v28.5.2.json").path
}()

public typealias SwaggerEndpoint = (method: String, path: String, operationId: String?, tag: String?)

public func fetchSwaggerEndpoints() async throws -> [SwaggerEndpoint] {
    // 1. Prefer bundled swagger (committed to repo, version-pinned)
    if let data = try? Data(contentsOf: URL(fileURLWithPath: bundledSwaggerPath)),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return extractEndpoints(from: json)
    }

    // 2. Fall back to user cache (~/.socktainer-probe/)
    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".socktainer-probe")
    let cachePath = cacheDir.appendingPathComponent("swagger-v28.5.2.json")

    if let attrs = try? FileManager.default.attributesOfItem(atPath: cachePath.path),
        let modified = attrs[.modificationDate] as? Date,
        Date().timeIntervalSince(modified) < 7 * 86400,
        let data = try? Data(contentsOf: cachePath),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return extractEndpoints(from: json)
    }

    // 3. Download from GitHub
    print("  ↓ Fetching Docker Engine API swagger (v28.5.2)...")
    let swaggerURL = "https://raw.githubusercontent.com/moby/moby/refs/tags/v28.5.2/api/swagger.yaml"
    let yamlData = try Process.output("/usr/bin/curl", "-fsSL", "--max-time", "30", swaggerURL)
    guard let yamlString = String(data: yamlData, encoding: .utf8), !yamlString.isEmpty else {
        throw CheckError.commandFailed("fetch swagger", "empty response")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
    process.arguments = ["-ryaml", "-rjson", "-e", "puts JSON.dump(YAML.safe_load(STDIN.read))"]
    let inPipe = Pipe(); let outPipe = Pipe()
    process.standardInput = inPipe; process.standardOutput = outPipe; process.standardError = Pipe()
    try process.run()
    inPipe.fileHandleForWriting.write(yamlString.data(using: .utf8)!)
    try inPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let jsonData = outPipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        throw CheckError.commandFailed("parse swagger", "YAML→JSON conversion failed")
    }
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try jsonData.write(to: cachePath)
    return extractEndpoints(from: json)
}

private func extractEndpoints(from swagger: [String: Any]) -> [SwaggerEndpoint] {
    guard let paths = swagger["paths"] as? [String: Any] else { return [] }
    var endpoints: [SwaggerEndpoint] = []
    for (path, value) in paths {
        if let ops = value as? [String: Any] {
            for method in ["get", "post", "put", "delete", "head"] {
                guard let op = ops[method] as? [String: Any] else { continue }
                let operationId = op["operationId"] as? String
                let tag = (op["tags"] as? [String])?.first
                endpoints.append((method.uppercased(), path, operationId, tag))
            }
        }
    }
    return endpoints.sorted { ($0.path, $0.method) < ($1.path, $1.method) }
}

// MARK: - Source-based coverage (no live probing, no crashes)

/// Result of extracting route registrations from Swift source files.
public struct ExtractedRoutes {
    public var implemented: Set<String> = []
    public var stubs: Set<String> = []
    public var all: Set<String> { implemented.union(stubs) }
    mutating func merge(_ other: ExtractedRoutes) {
        implemented.formUnion(other.implemented)
        stubs.formUnion(other.stubs)
    }
}

func extractSocktainerRoutes(from sourceDir: String) -> ExtractedRoutes {
    let fm = FileManager.default
    var result = ExtractedRoutes()
    guard let enumerator = fm.enumerator(atPath: sourceDir) else { return result }
    for case let file as String in enumerator where file.hasSuffix(".swift") {
        let fullPath = "\(sourceDir)/\(file)"
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
        result.merge(extractRoutesFromContent(content))
    }
    return result
}

/// Stub handler name fragments — routes using these are "registered but not implemented".
private let stubIndicators = ["stub", "notimplemented", "notImplemented", "501"]

private func extractRoutesFromContent(_ content: String) -> ExtractedRoutes {
    var result = ExtractedRoutes()

    // Match entire registerVersionedRoute(...) call blocks, possibly multi-line.
    guard let blockRegex = try? NSRegularExpression(
        pattern: #"registerVersionedRoute\([^)]+\)"#,
        options: [.dotMatchesLineSeparators]
    ) else { return result }
    guard let patternRegex = try? NSRegularExpression(pattern: #"pattern:\s*"([^"]+)""#) else { return result }

    let fullRange = NSRange(content.startIndex..., in: content)
    for block in blockRegex.matches(in: content, range: fullRange) {
        guard let blockRange = Range(block.range, in: content) else { continue }
        let blockStr = String(content[blockRange])
        let blockNS  = NSRange(blockStr.startIndex..., in: blockStr)

        guard let pm = patternRegex.firstMatch(in: blockStr, range: blockNS),
              let pr = Range(pm.range(at: 1), in: blockStr) else { continue }
        let route = String(blockStr[pr])

        let lower = blockStr.lowercased()
        let isStub = stubIndicators.contains { lower.contains($0.lowercased()) }
        if isStub { result.stubs.insert(route) }
        else      { result.implemented.insert(route) }
    }

    // Fallback: simple pattern: "..." match if no full block was found (e.g. different call style).
    if result.all.isEmpty {
        if let regex = try? NSRegularExpression(pattern: #"pattern:\s*"([^"]+)""#) {
            for match in regex.matches(in: content, range: fullRange) {
                if let range = Range(match.range(at: 1), in: content) {
                    result.implemented.insert(String(content[range]))
                }
            }
        }
    }
    return result
}

// MARK: - GitHub-based route fetching

private let routesCachePath: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".socktainer-probe/routes-github-cache.json")

/// Fetches registered routes from the Socktainer GitHub repo's Routes directory.
/// Caches results for 24 h so repeated launches don't hit the API.
public func fetchSocktainerRoutesFromGitHub(repoURL: String) async throws -> ExtractedRoutes {
    if let cached = loadRoutesCache() { return cached }

    let apiBase = repoURL
        .replacingOccurrences(of: "https://github.com/", with: "https://api.github.com/repos/")
        .trimmingCharacters(in: .init(charactersIn: "/"))
    let contentsURL = URL(string: "\(apiBase)/contents/Sources/socktainer/Routes")!

    var req = URLRequest(url: contentsURL)
    req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
    req.setValue("SocktainerProbe/1.0", forHTTPHeaderField: "User-Agent")

    let (listData, _) = try await URLSession.shared.data(for: req)
    guard let files = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
        throw CheckError.commandFailed("GitHub API", "unexpected listing response")
    }

    var extracted = ExtractedRoutes()
    for file in files {
        guard let name = file["name"] as? String, name.hasSuffix(".swift"),
              let rawStr = file["download_url"] as? String,
              let rawURL = URL(string: rawStr) else { continue }
        let (fileData, _) = try await URLSession.shared.data(from: rawURL)
        extracted.merge(extractRoutesFromContent(String(data: fileData, encoding: .utf8) ?? ""))
    }

    saveRoutesCache(extracted)
    return extracted
}

private struct RoutesCache: Codable {
    let implemented: [String]
    let stubs: [String]
}

private func loadRoutesCache() -> ExtractedRoutes? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: routesCachePath.path),
          let modified = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(modified) < 86400,
          let data = try? Data(contentsOf: routesCachePath),
          let cache = try? JSONDecoder().decode(RoutesCache.self, from: data)
    else { return nil }
    var r = ExtractedRoutes()
    r.implemented = Set(cache.implemented)
    r.stubs = Set(cache.stubs)
    return r
}

private func saveRoutesCache(_ routes: ExtractedRoutes) {
    let dir = routesCachePath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cache = RoutesCache(implemented: Array(routes.implemented), stubs: Array(routes.stubs))
    try? JSONEncoder().encode(cache).write(to: routesCachePath)
}

// Normalize swagger path to match Socktainer's pattern (e.g. {id} → {id})
private func normalizeSwaggerPath(_ path: String) -> String {
    // swagger uses {id}, {name}, {name:.*} etc. — normalize to match socktainer patterns
    var p = path
    p = p.replacingOccurrences(of: #"\{[^}]+\}"#, with: "{id}", options: .regularExpression)
    return p
}

private func normalizeSourcePath(_ path: String) -> String {
    // Socktainer uses {id}, {name:.*} etc.
    var p = path
    p = p.replacingOccurrences(of: #"\{[^}:]+:[^}]+\}"#, with: "{id}", options: .regularExpression)
    p = p.replacingOccurrences(of: #"\{[^}]+\}"#, with: "{id}", options: .regularExpression)
    return p
}

// MARK: - Run coverage check

public func runCoverageCheck(socktainerSourceDir: String?) async {
    section("Docker API Coverage (v28.5.2)")

    let endpoints: [SwaggerEndpoint]
    do {
        endpoints = try await fetchSwaggerEndpoints()
    } catch {
        print("  ❌ Failed to fetch swagger: \(error.localizedDescription)")
        return
    }

    // Extract routes from source if available
    let sourceDir = socktainerSourceDir
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/socktainer/Sources/socktainer/Routes").path
    let extracted = extractSocktainerRoutes(from: sourceDir)
    let implNorm  = Set(extracted.implemented.map { normalizeSourcePath($0) })
    let stubNorm  = Set(extracted.stubs.map      { normalizeSourcePath($0) })

    if extracted.all.isEmpty {
        print("  ⚠️  No source routes found at \(sourceDir)")
        print("     Pass --source /path/to/socktainer/Sources/socktainer/Routes")
        return
    }

    print("  Spec: \(endpoints.count) endpoints  |  Source: \(extracted.implemented.count) implemented, \(extracted.stubs.count) stubs\n")

    var results: [EndpointResult] = []
    for ep in endpoints {
        let (method, path, operationId, tag) = ep
        let normalized = normalizeSwaggerPath(path)
        let status: EndpointStatus
        let note: String?

        let methodKey = "\(method) \(path)"
        if let methodNote = methodNotApplicable[methodKey] {
            status = .notApplicable
            note = methodNote
        } else if notApplicablePaths.contains(path) {
            status = .notApplicable
            note = "requires Docker Swarm or Docker Desktop"
        } else if stubNorm.contains(normalized) || extracted.stubs.contains(path) {
            status = .stub
            note = "Registered but returns 501 Not Implemented"
        } else if implNorm.contains(normalized) || extracted.implemented.contains(path) {
            status = .implemented
            note = nil
        } else {
            status = .notImplemented
            note = nil
        }
        results.append(EndpointResult(method: method, path: path, status: status, note: note,
                                       testID: routeTestID(method: method, path: path),
                                       operationId: operationId, docTag: tag))
    }

    let implemented   = results.filter { $0.status == .implemented }.count
    let notApplicable = results.filter { $0.status == .notApplicable }.count
    let missing       = results.filter { $0.status == .notImplemented }.count
    let testable      = results.count - notApplicable
    let pct = testable > 0 ? Int(Double(implemented) * 100 / Double(testable)) : 0

    print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  Total endpoints in spec:    \(results.count)")
    print("  Not applicable (swarm etc): \(notApplicable)")
    print("  Testable:                   \(testable)")
    print("  ─────────────────────────────────────────────────────")
    print("  ✅ Implemented:             \(implemented) (\(pct)% of testable)")
    print("  ❌ Not yet implemented:     \(missing)")
    print()

    if missing > 0 {
        print("  ── Missing endpoints (not yet registered) ──")
        results.filter { $0.status == .notImplemented }
            .forEach { print("    \($0.method.padded(to: 7))\($0.path)") }
        print()
        print("  💡 Suggested: add 501 stubs so Docker clients get a clear error:")
        results.filter { $0.status == .notImplemented }
            .forEach {
                print("    // TODO: stub \($0.method) \($0.path)")
                print("    //   try routes.registerVersionedRoute(.\($0.method.lowercased()),")
                print("    //     pattern: \"\($0.path)\", use: stub501)")
            }
        print()
    }

    print("  ── Implemented endpoints (with test coverage) ──")
    results.filter { $0.status == .implemented }
        .forEach {
            let testId = routeTestID(method: $0.method, path: $0.path)
            let tag = testId.map { "  ← \($0)" } ?? ""
            print("  ✅ \($0.method.padded(to: 7))\($0.path)\(tag)")
        }
    print()
    print("  ── Not applicable (swarm/plugins) ──")
    results.filter { $0.status == .notApplicable }
        .forEach { print("  🚫 \($0.method.padded(to: 7))\($0.path)") }
}

// MARK: - Route → Test ID mapping

/// Maps a Docker API route to the socktainer-probe test ID that covers it.
private func routeTestID(method: String, path: String) -> String? {
    let key = "\(method.uppercased()) \(path)"
    return routeTestMap[key]
}

private let routeTestMap: [String: String] = [
    // ── Container lifecycle ──────────────────────────────────────────────────
    "GET /containers/json":          "CTR-001…005",
    "POST /containers/create":       "CTR-001…005",
    "POST /containers/{id}/start":   "CTR-001…005",
    "POST /containers/{id}/stop":    "CTR-001…005",
    "DELETE /containers/{id}":       "CTR-001…005, WT-001, WT-002",
    "POST /containers/{id}/attach":  "CTR-001…005, WS-001…004",
    "GET /containers/{id}/attach/ws":"WS-001…004",
    "POST /containers/{id}/kill":    "EVT-009, EVT-010",
    "POST /containers/{id}/rename":  "CTR-006, EVT-019",
    "POST /containers/{id}/restart": "CTR-007, EVT-020",
    "GET /containers/{id}/top":      "CTR-008",
    "POST /containers/prune":        "PRM-002",
    // ── Container inspection ─────────────────────────────────────────────────
    "GET /containers/{id}/json":     "HLT-001, HLT-002, TC-001…006",
    "GET /containers/{id}/logs":     "LOG-001, LOG-002, VOL-001",
    "GET /containers/{id}/stats":    "STS-001, MEM-001…003, CMP-001, CMP-002",
    "POST /containers/{id}/wait":    "WAI-001, WAI-002, CTR-001…005",
    // ── Exec ─────────────────────────────────────────────────────────────────
    "POST /containers/{id}/exec":    "EXEC-001, EXEC-002, EXEC-003",
    "POST /exec/{id}/start":         "EXEC-001, EXEC-002, EXEC-003",
    // ── Archive (docker cp) ───────────────────────────────────────────────────
    "GET /containers/{id}/archive":  "ARC-001",
    "PUT /containers/{id}/archive":  "ARC-002",
    "HEAD /containers/{id}/archive": "ARC-001",
    // ── Images ───────────────────────────────────────────────────────────────
    "GET /images/json":              "CTR-001…005",
    "POST /images/create":           "CTR-001…005",
    "GET /images/{name}/json":       "CTR-001…005",
    "GET /images/{name}/history":    "IMG-001",
    "DELETE /images/{name}":         "IMG-002, IMG-003",
    "POST /images/{name}/tag":       "IMG-002",
    // ── Networks ─────────────────────────────────────────────────────────────
    "GET /networks":                 "LBL-002, NET-001",
    "POST /networks/create":         "LBL-002, DNS-001, NET-002",
    "GET /networks/{id}":            "LBL-002",
    "DELETE /networks/{id}":         "LBL-002",
    "POST /networks/prune":          "NET-001",
    "POST /networks/{id}/connect":   "NET-002, TC-006, EVT-018",
    "POST /networks/{id}/disconnect":"NET-003, EVT-018",
    // ── Volumes ───────────────────────────────────────────────────────────────
    "GET /volumes":                  "VOL-006",
    "POST /volumes/create":          "VOL-001…004, LBL-003",
    "GET /volumes/{name}":           "VOL-002, VOL-003, LBL-003",
    "PUT /volumes/{name}":           "VOL-008",
    "DELETE /volumes/{name}":        "VOL-001…004, LBL-003",
    "POST /volumes/prune":           "VOL-007",
    // ── Auth & Build ──────────────────────────────────────────────────────────
    "POST /auth":                    "AUTH-001",
    "POST /build":                   "BLD-001",
    "POST /build/prune":             "BLD-002",
    // ── System ────────────────────────────────────────────────────────────────
    "GET /_ping":                    "all",
    "HEAD /_ping":                   "all",
    "GET /version":                  "all",
    "GET /info":                     "all",
    "GET /system/df":                "SDF-001",
    "GET /events":                   "EVT-001…020",
]

private func stub501Description() -> String {
    """
    // Add to configure.swift or a dedicated StubRoutes.swift:
    let stub501: @Sendable (Request) async throws -> Response = { _ in
        Response(status: .notImplemented)
    }
    """
}

private extension String {
    func padded(to length: Int) -> String {
        padding(toLength: max(count, length), withPad: " ", startingAt: 0)
    }
}
