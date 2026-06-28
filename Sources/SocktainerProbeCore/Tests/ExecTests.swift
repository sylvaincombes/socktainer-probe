import Foundation

public func runExecSection(sock: DockerCLI) async {
    section("Docker exec")

    await check("docker exec runs command in running container",
                id: "EXEC-001", refs: [],
                repro: "docker --context socktainer run -d --name test alpine sleep 30\ndocker --context socktainer exec test echo hello") {
        let name = "check-exec-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)
        let output = try await sock.exec(name: name, cmd: ["echo", "hello"])
        try assertContains(output, "hello")
    }

    // #245 (fix/exec-io-crash) is merged: StdioPipes replaced Pipe() so concurrent
    // high-output exec no longer corrupts the NIO fd table. Promoted from xfail → check.
    await check(
        "concurrent high-output exec does not crash the daemon",
        id: "EXEC-003",
        refs: ["#107", "#245"],
        repro: """
            docker --context socktainer run -d --name pg postgres:latest
            # run 3 concurrent yes-flood exec sessions:
            docker --context socktainer exec pg sh -c 'yes s | head 50000' &
            docker --context socktainer exec pg sh -c 'yes s | head 50000' &
            docker --context socktainer exec pg sh -c 'yes s | head 50000' &
            wait
            docker --context socktainer info   # crashes before fix
            """
    ) {
        let name = "check-exec3-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sleep", "60"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Run 3 concurrent exec sessions each producing ~50k lines of output.
        // Before the fix this caused a libdispatch crash within the first round.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try? await sock.exec(name: name, cmd: ["sh", "-c", "yes s | head -10000"])
                }
            }
        }

        // Daemon must still respond after the flood.
        let alive = try await sock.ping()
        try assert(alive, "daemon crashed under concurrent high-output exec — see #107")
    }

    await check("docker exec forwards non-zero exit code",
                id: "EXEC-002", refs: [],
                repro: "docker --context socktainer run -d --name test alpine sleep 30\ndocker --context socktainer exec test sh -c 'exit 42'") {
        let name = "check-exec2-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)
        do {
            _ = try await sock.exec(name: name, cmd: ["sh", "-c", "exit 42"])
            throw CheckError.assertionFailed("expected non-zero exit from exec")
        } catch CheckError.commandFailed { }
    }
}
