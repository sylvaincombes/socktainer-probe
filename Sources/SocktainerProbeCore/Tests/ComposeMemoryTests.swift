import Foundation

// Compose must run sequentially — timing-sensitive after other compose operations.
public func runComposeSection(sock: DockerCLI) async {
    section("Compose memory limits")
    let mib = 1024 * 1024
    let gib = 1024 * mib

    await check("compose mem_limit: 512m → memory_stats.limit = 536870912 bytes",
                id: "CMP-001", refs: [],
                repro: "docker compose up -d (with mem_limit: 512m)") {
        let suffix = Int.random(in: 10000...99999)
        let composeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-mem-\(suffix).yml").path
        let content = "name: sck-mem-\(suffix)\nservices:\n  memsvc:\n    image: alpine\n    command: sleep 30\n    mem_limit: 512m\n"
        try content.write(toFile: composeFile, atomically: true, encoding: .utf8)

        _ = try await sock.compose(file: composeFile, "up", "-d")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let ps = try await sock.compose(file: composeFile, "ps", "--format", "{{.Name}}")
        let ctrName = ps.split(separator: "\n").first.map(String.init) ?? ""
        try assert(!ctrName.isEmpty, "compose started a container")

        // Get stats BEFORE bringing compose down
        let limit = try await sock.containerMemoryLimitBytes(name: ctrName)

        _ = try? await sock.compose(file: composeFile, "down", "--remove-orphans")
        try? FileManager.default.removeItem(atPath: composeFile)

        try assertEqual(limit, 512 * mib, "mem_limit: 512m → \(limit) bytes")
    }

    await check("compose deploy.resources.limits.memory: 2g → memory_stats.limit = 2147483648 bytes",
                id: "CMP-002", refs: [],
                repro: "docker compose up -d (with deploy.resources.limits.memory: 2g)") {
        let suffix = Int.random(in: 10000...99999)
        let composeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-mem-\(suffix).yml").path
        let content = "name: sck-mem-\(suffix)\nservices:\n  memsvc:\n    image: alpine\n    command: sleep 30\n    deploy:\n      resources:\n        limits:\n          memory: 2g\n"
        try content.write(toFile: composeFile, atomically: true, encoding: .utf8)

        _ = try await sock.compose(file: composeFile, "up", "-d")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let ps = try await sock.compose(file: composeFile, "ps", "--format", "{{.Name}}")
        let ctrName = ps.split(separator: "\n").first.map(String.init) ?? ""
        try assert(!ctrName.isEmpty, "compose started a container")

        // Get stats BEFORE bringing compose down
        let limit = try await sock.containerMemoryLimitBytes(name: ctrName)

        _ = try? await sock.compose(file: composeFile, "down", "--remove-orphans")
        try? FileManager.default.removeItem(atPath: composeFile)

        try assertEqual(limit, 2 * gib, "deploy.resources: 2g → \(limit) bytes")
    }
}
