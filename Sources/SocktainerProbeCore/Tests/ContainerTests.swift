import Foundation

public func runContainerSection(sock: DockerCLI) async {
    section("Container lifecycle")
    await check("docker run --rm alpine echo hi",
                id: "CTR-001", refs: ["#220"],
                repro: "docker --context socktainer run --rm alpine echo hi") {
        let output = try await sock.runContainer(image: "public.ecr.aws/docker/library/alpine", cmd: ["echo", "hi"])
        try assertContains(output, "hi")
    }
    await check("exit code forwarded correctly",
                id: "CTR-002", refs: ["#220"],
                repro: "docker --context socktainer run --rm alpine sh -c 'exit 42'") {
        do {
            _ = try await sock.runContainer(image: "public.ecr.aws/docker/library/alpine", cmd: ["sh", "-c", "exit 42"])
            throw CheckError.assertionFailed("expected non-zero exit")
        } catch CheckError.commandFailed { }
    }
    await check("multi-line output",
                id: "CTR-003", refs: ["#220"],
                repro: "docker --context socktainer run --rm alpine sh -c 'echo line1 && echo line2 && echo line3'") {
        let output = try await sock.runContainer(
            image: "public.ecr.aws/docker/library/alpine", cmd: ["sh", "-c", "echo line1 && echo line2 && echo line3"])
        try assertContains(output, "line1"); try assertContains(output, "line2"); try assertContains(output, "line3")
    }
    await check("devcontainer mode (-a STDOUT -a STDERR --sig-proxy=false)",
                id: "CTR-004", refs: ["#220"],
                repro: "docker --context socktainer run --sig-proxy=false -a STDOUT -a STDERR --rm alpine sh -c 'echo Container started'") {
        let output = try await sock.runContainer(image: "public.ecr.aws/docker/library/alpine", cmd: ["sh", "-c", "echo Container started"])
        try assertContains(output, "Container started")
    }
    await check("output after sleep",
                id: "CTR-005", refs: ["#220"],
                repro: "docker --context socktainer run --rm alpine sh -c 'sleep 0.2; echo after'") {
        let output = try await sock.runContainer(image: "public.ecr.aws/docker/library/alpine", cmd: ["sh", "-c", "sleep 0.2; echo after"])
        try assertContains(output, "after")
    }

    await xfail("docker rename changes the container name",
                id: "CTR-006",
                reason: "POST /containers/{id}/rename not yet implemented in Socktainer 1.0.0",
                repro: "docker --context socktainer run -d --name old-name alpine sleep 30\ndocker --context socktainer rename old-name new-name") {
        let original = "check-rename-src-\(Int.random(in: 10000...99999))"
        let renamed  = "check-rename-dst-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: original, image: "public.ecr.aws/docker/library/alpine",
                                        rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: renamed, force: true) } }
        try await sock.rename(name: original, newName: renamed)
        let containers = try await sock.containerList(all: true)
        try assert(containers.contains(renamed), "container should appear under new name '\(renamed)'")
        try assert(!containers.contains(original), "old name '\(original)' should be gone after rename")
    }

    await check("docker restart restarts a running container",
                id: "CTR-007",
                repro: "docker --context socktainer run -d --name ctr alpine sleep 30\ndocker --context socktainer restart ctr") {
        let name = "check-restart-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine",
                                        rm: false, detach: true, cmd: ["sleep", "60"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        let before = try await sock.inspect(name: name)
        let startedAtBefore = (before["State"] as? [String: Any])?["StartedAt"] as? String ?? ""
        try await sock.restart(name: name, timeout: 3)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = try await sock.inspect(name: name)
        let startedAtAfter = (after["State"] as? [String: Any])?["StartedAt"] as? String ?? ""
        try assert(startedAtAfter != startedAtBefore, "StartedAt should differ after restart")
        try assertEqual((after["State"] as? [String: Any])?["Status"] as? String, "running", "container should be running")
    }

    // CTR-009 — regression guard for the exec/attach hang bug.
    // A foreground docker run (attach stdout + wait) must return promptly when the container
    // exits — driven by pipe-EOF, not blocked on the XPC fallback timeout (~10s).
    // Tests both immediate-exit and work-then-exit shapes.
    await check("foreground docker run closes stream and returns promptly on container exit",
                id: "CTR-009",
                refs: [],
                repro: "time docker --context socktainer run --rm busybox echo hi   # should be ~1s, not ~11s") {
        // Shape 1: immediate exit — should complete in < 5s (was: ~11s with hang)
        let t1 = Date()
        let out1 = try await sock.runContainer(image: "public.ecr.aws/docker/library/busybox", cmd: ["echo", "hello-from-socktainer"])
        let elapsed1 = Date().timeIntervalSince(t1)
        try assertContains(out1, "hello-from-socktainer")
        try assert(elapsed1 < 5.0,
                   "immediate exit took \(String(format: "%.1f", elapsed1))s — expected < 5s (exec-hang regression?)")

        // Shape 2: work-then-exit (sleep 2) — total should be ~3s, not 12s
        let t2 = Date()
        let out2 = try await sock.runContainer(image: "public.ecr.aws/docker/library/busybox",
                                               cmd: ["sh", "-c", "echo start; sleep 2; echo done"])
        let elapsed2 = Date().timeIntervalSince(t2)
        try assertContains(out2, "done")
        try assert(elapsed2 < 8.0,
                   "sleep-2 run took \(String(format: "%.1f", elapsed2))s — expected < 8s (exec-hang regression?)")
        try assert(elapsed2 >= 1.5,
                   "sleep-2 run returned in \(String(format: "%.1f", elapsed2))s — suspiciously fast, sleep may not have run")
    }

    await xfail("docker top returns running processes in a container",
                id: "CTR-008",
                reason: "GET /containers/{id}/top not yet implemented in Socktainer 1.0.0",
                repro: "docker --context socktainer run -d --name ctr alpine sleep 30\ndocker --context socktainer top ctr") {
        let name = "check-top-\(Int.random(in: 10000...99999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine",
                                        rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: name, force: true) } }
        let processes = try await sock.top(name: name)
        try assert(!processes.isEmpty, "docker top should return at least one process")
        try assert(processes.contains { $0.values.contains { $0.contains("sleep") } },
                   "expected 'sleep' process in top output, got: \(processes)")
    }
}
