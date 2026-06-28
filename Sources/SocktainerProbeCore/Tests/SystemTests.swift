import Foundation

public func runSystemSection(sock: DockerCLI) async {
    section("System")
    await check("docker system df returns image, container and volume usage",
                id: "SDF-001", refs: ["#191"],
                repro: "docker --context socktainer system df") {
        let rows = try await sock.systemDf()
        try assert(!rows.isEmpty, "system df returned at least one row")
        let types = Set(rows.compactMap { $0["Type"] as? String })
        try assert(types.contains("Images"), "Images row present")
        try assert(types.contains("Containers"), "Containers row present")
        try assert(types.contains("Local Volumes"), "Local Volumes row present")
    }

    // POST /auth is registered in Socktainer's source but its implementation status is uncertain.
    // This test probes it to distinguish real implementation from a silent stub:
    // - A real implementation would validate credentials and return {"IdentityToken":"..."} or an error JSON
    // - A stub might return 200 OK with empty body, or 501 NotImplemented
    await check("POST /auth endpoint responds with a parseable JSON body (not silent stub)",
                id: "AUTH-001",
                repro: "curl --unix-socket ~/.socktainer/container.sock -X POST -H 'Content-Type: application/json' -d '{\"username\":\"test\",\"password\":\"test\",\"serveraddress\":\"registry-1.docker.io\"}' http://localhost/v1.51/auth") {
        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-s", "--unix-socket", socketPath,
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", #"{"username":"probe-test","password":"probe-test","serveraddress":"registry-1.docker.io"}"#,
            "http://localhost/v1.51/auth",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        let body = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Must return a non-empty JSON body — silent empty response = silent stub
        try assert(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "POST /auth returned empty body — likely a silent stub")

        // Must be valid JSON
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CheckError.assertionFailed("POST /auth did not return JSON: \(body.prefix(200))") }

        // A stub returning 501 would have {"message":"Not Implemented"} or {"message":"not implemented"}
        if let msg = json["message"] as? String {
            let lower = msg.lowercased()
            try assert(!lower.contains("not implemented") && !lower.contains("501"),
                       "POST /auth returned 501 stub: \(msg) — route is registered but not implemented")
        }
        // If we got here: endpoint responds with JSON that isn't a 501 — considered implemented
    }

    // POST /build — Confirmed implemented in Socktainer 1.0.0.
    
    
    await check("POST /build endpoint responds with a real error (not a 501 stub)",
                id: "BLD-001",
                repro: "curl --unix-socket ~/.socktainer/container.sock -X POST http://localhost/v1.51/build") {
        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-s", "-w", "\n%{http_code}",
            "--unix-socket", socketPath,
            "-X", "POST",
            "-H", "Content-Type: application/x-tar",
            "http://localhost/v1.51/build",
        ]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        let raw  = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        let body = lines.dropLast().joined(separator: "\n")
        let code = lines.last ?? ""

        // 501 → confirmed stub
        try assert(code != "501",
                   "POST /build returned 501 — route is registered but not implemented (stub)")
        // Empty body with 200 → silent stub
        try assert(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "POST /build returned empty body (HTTP \(code)) — likely a silent stub")
        // If we get a 400/500 with an error message that's fine — real endpoint rejecting bad input
    }

    // POST /build/prune — Confirmed implemented in Socktainer 1.0.0.
    await check("POST /build/prune endpoint responds (not a 501 stub)",
                id: "BLD-002",
                repro: "curl --unix-socket ~/.socktainer/container.sock -X POST http://localhost/v1.51/build/prune") {
        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-s", "-w", "\n%{http_code}",
            "--unix-socket", socketPath,
            "-X", "POST",
            "http://localhost/v1.51/build/prune",
        ]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        let raw   = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        let body  = lines.dropLast().joined(separator: "\n")
        let code  = lines.last ?? ""

        try assert(code != "501",
                   "POST /build/prune returned 501 — route is registered but not implemented (stub)")
        try assert(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "POST /build/prune returned empty body (HTTP \(code)) — likely a silent stub")
        // A real implementation returns {"SpaceReclaimed": N, "CachesDeleted": [...]}
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = json["message"] as? String {
                try assert(!msg.lowercased().contains("not implemented"),
                           "POST /build/prune returned 501 stub message: \(msg)")
            }
        }
    }
}
