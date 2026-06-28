import Foundation

public func runLogsSection(sock: DockerCLI) async {
    section("Container logs")

    await check("docker logs returns container output",
                id: "LOG-001", refs: [],
                repro: "docker --context socktainer run --name test alpine sh -c 'echo hello && echo world'\ndocker --context socktainer logs test") {
        let name = "check-logs-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false,
            cmd: ["sh", "-c", "echo hello && echo world"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }
        let output = try await sock.logs(name: name)
        try assertContains(output, "hello")
        try assertContains(output, "world")
    }

    await check("docker logs for detached container captures output",
                id: "LOG-002", refs: [],
                repro: "docker --context socktainer run -d --name test alpine sh -c 'echo detached-log'\ndocker --context socktainer logs test") {
        let name = "check-logs2-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sh", "-c", "echo detached-log"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)
        let output = try await sock.logs(name: name)
        try assertContains(output, "detached-log")
    }
}
