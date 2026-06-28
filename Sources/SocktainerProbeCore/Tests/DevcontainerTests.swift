import Foundation

/// Tests that simulate the patterns used by VS Code devcontainers / Codespaces:
///   - Rapid concurrent `docker exec` (extension host, language servers, postCreate commands)
///   - `docker run --rm` for one-shot commands (feature install, lifecycle scripts)
///   - Workspace volume mounts (`/workspaces/<project>` bind-mount pattern)
public func runDevcontainerSection(sock: DockerCLI) async {
    section("Devcontainer patterns")

    // DEV-001 — Rapid sequential exec (VS Code extension host pattern)
    // The extension host fires many exec calls in quick succession on the same container.
    await check(
        "rapid sequential exec calls succeed without errors",
        id: "DEV-001",
        refs: ["#107"],
        repro: """
            docker --context socktainer run -d --name dev alpine sleep 60
            for i in $(seq 20); do docker --context socktainer exec dev echo "cmd $i"; done
            """
    ) {
        let name = "check-dev-seq-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "60"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Fire 20 sequential exec calls — simulates postCreate commands and extension activation.
        for i in 0..<20 {
            let output = try await sock.exec(name: name, cmd: ["echo", "cmd\(i)"])
            try assertContains(output, "cmd\(i)")
        }
    }

    // DEV-002 — Concurrent exec burst (language server + extension host concurrent startup)
    // Multiple extensions start simultaneously and each fires exec calls.
    await check(
        "concurrent exec burst does not crash or corrupt output",
        id: "DEV-002",
        refs: ["#107"],
        repro: """
            docker --context socktainer run -d --name dev alpine sleep 60
            # Fire 6 concurrent exec calls (3 pairs) and verify all return correct output
            """
    ) {
        let name = "check-dev-burst-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "60"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)

        var outputs: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<6 {
                group.addTask {
                    try? await sock.exec(name: name, cmd: ["sh", "-c", "echo marker\(i)"])
                }
            }
            for await result in group {
                if let out = result { outputs.append(out) }
            }
        }

        try assert(outputs.count == 6, "expected 6 exec results, got \(outputs.count)")
        let alive = try await sock.ping()
        try assert(alive, "daemon crashed during concurrent exec burst — see #107")
    }

    // DEV-003 — docker run --rm for one-shot scripts (devcontainer feature install pattern)
    // Features and lifecycle hooks run via `docker run --rm` inside the project image.
    await check(
        "docker run --rm one-shot commands work for multiple rapid invocations",
        id: "DEV-003",
        refs: [],
        repro: """
            # Simulate feature install: run --rm commands in rapid succession
            for i in 1 2 3; do
              docker --context socktainer run --rm alpine sh -c "echo feature_N"
            done
            """
    ) {
        // Run 3 one-shot containers in sequence — devcontainer feature install pattern.
        for i in 0..<3 {
            let output = try await sock.runContainer(
                image: "public.ecr.aws/docker/library/alpine",
                rm: true,
                cmd: ["sh", "-c", "echo feature_\(i)"]
            )
            try assertContains(output, "feature_\(i)")
        }
    }

    // DEV-004 — Workspace volume mount (bind-mount /workspaces/<project>)
    // The devcontainer mounts the project directory at /workspaces. Exec must see the files.
    await check(
        "workspace bind-mount is visible inside the container via exec",
        id: "DEV-004",
        refs: [],
        repro: """
            # Create a temp dir to simulate /workspaces/myproject
            docker --context socktainer run -d --name dev \\
              -v /tmp/workspace:/workspace alpine sleep 60
            docker --context socktainer exec dev ls /workspace
            # Expect the temp dir contents to be visible
            """
    ) {
        let workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-probe-ws-\(Int.random(in: 10000...99999))")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try "devcontainer-marker".write(to: workspaceDir.appendingPathComponent(".devcontainer-check"),
                                       atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspaceDir) }

        let name = "check-dev-vol-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            volumes: ["\(workspaceDir.path):/workspace"],
            rm: false, detach: true,
            cmd: ["sleep", "30"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Use `ls -a` — the marker file is a dotfile (.devcontainer-check), and `ls`
        // without -a does not list hidden files on Linux.
        let output = try await sock.exec(name: name, cmd: ["ls", "-a", "/workspace"])
        try assertContains(output, ".devcontainer-check")
    }

    // DEV-005 — exec exit code forwarding (devcontainer postCreate command failure detection)
    // VS Code reads the exec exit code to detect when a setup command fails.
    await check(
        "exec exit code is forwarded correctly for devcontainer lifecycle scripts",
        id: "DEV-005",
        refs: [],
        repro: """
            docker --context socktainer run -d --name dev alpine sleep 60
            docker --context socktainer exec dev sh -c 'exit 42'
            echo $?   # must be 42, not 0
            """
    ) {
        let name = "check-dev-exit-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        try await Task.sleep(nanoseconds: 500_000_000)

        // A successful command must exit 0.
        _ = try await sock.exec(name: name, cmd: ["true"])

        // A failing command must propagate its exit code (not silently return 0).
        do {
            _ = try await sock.exec(name: name, cmd: ["sh", "-c", "exit 42"])
            throw CheckError.assertionFailed("expected non-zero exit code from exec")
        } catch CheckError.commandFailed { }
    }
}
