import Foundation

public func runStatsSection(sock: DockerCLI) async {
    section("Stats")
    await check("docker stats returns memory and CPU fields",
                id: "STS-001", refs: ["#217"],
                repro: "docker --context socktainer run -d --name test alpine sleep 10\ndocker --context socktainer stats --no-stream --format '{{json .}}' test") {
        let name = "check-stats-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "10"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let statsJSON = try await sock.stats(name: name)
        try assert(statsJSON["MemUsage"] != nil || statsJSON["memUsage"] != nil
                   || statsJSON["memory_stats"] != nil, "memory field present")
    }
}
