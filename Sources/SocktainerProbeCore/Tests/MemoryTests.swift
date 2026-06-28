import Foundation

public func runMemorySection(sock: DockerCLI) async {
    section("VM memory — --memory flag")
    let mib = 1024 * 1024
    let gib = 1024 * mib
    await check("--memory 512m → memory_stats.limit = 536870912 bytes",
                id: "MEM-001", refs: ["#230"],
                repro: "docker --context socktainer run -d --memory 512m alpine sleep 30") {
        let name = "check-mem512-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", memory: "512m", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name) } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try assertEqual(try await sock.containerMemoryLimitBytes(name: name), 512 * mib, "memory limit bytes")
    }
    await check("--memory 2g → memory_stats.limit = 2147483648 bytes",
                id: "MEM-002", refs: ["#230"],
                repro: "docker --context socktainer run -d --memory 2g alpine sleep 30") {
        let name = "check-mem2g-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", memory: "2g", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name) } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try assertEqual(try await sock.containerMemoryLimitBytes(name: name), 2 * gib, "memory limit bytes")
    }
    await check("no --memory → Apple Container default 1 GiB",
                id: "MEM-003", refs: ["#230"],
                repro: "docker --context socktainer run -d alpine sleep 30") {
        let name = "check-memdef-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name) } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try assertEqual(try await sock.containerMemoryLimitBytes(name: name), gib, "default memory limit (1 GiB)")
    }
}
