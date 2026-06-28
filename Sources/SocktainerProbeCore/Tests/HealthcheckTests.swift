import Foundation

public func runHealthcheckSection(sock: DockerCLI) async {
    section("Healthcheck (detailed)")
    await check("container with healthcheck reaches healthy state",
                id: "HLT-001", refs: ["#214"],
                repro: "docker --context socktainer run -d --name test --health-cmd 'true' --health-interval 1s alpine sleep 30\nsleep 3 && docker --context socktainer inspect test --format '{{.State.Health.Status}}'") {
        let name = "check-hc-real-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", healthCmd: "true", healthInterval: "1s", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        var status = "starting"
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 500_000_000)
            status = (try? await sock.healthStatus(name: name)) ?? "unknown"
            if status == "healthy" { break }
        }
        try assertEqual(status, "healthy", "health status")
    }
    await check("detached container starts and is inspectable",
                id: "HLT-002", refs: [],
                repro: "docker --context socktainer run -d --name test alpine sleep 10\ndocker --context socktainer inspect test --format '{{.State.Status}}'") {
        let name = "check-hc-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "10"])
        let inspected = try await sock.inspect(name: name)
        try assert(inspected["State"] != nil, "State present in inspect")
        try await sock.remove(name: name, force: true)
    }
}
