import Foundation

public func runWaitSection(sock: DockerCLI) async {
    section("Container wait")

    await check("docker wait returns exit code when container stops",
                id: "WAI-001", refs: [],
                repro: "docker --context socktainer run -d --name test alpine sh -c 'exit 42'\ndocker --context socktainer wait test") {
        let name = "check-wait-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sh", "-c", "sleep 1 && exit 42"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }

        // docker wait blocks until the container exits and prints the exit code
        let output = try await sock.waitAndGetExitCode(name: name)
        try assertEqual(output, "42", "docker wait must return the container exit code")
    }

    await check("docker wait condition=removed via REST API resolves after container deleted",
                id: "WAI-002", refs: [],
                repro: "curl --unix-socket ... -X POST localhost/v1.51/containers/test/wait?condition=removed\ndocker --context socktainer rm -f test") {
        let name = "check-wait2-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sleep", "30"]
        )

        // Start a REST wait for condition=removed in the background
        let waitTask = Task { try await sock.waitConditionRemoved(name: name) }
        try await Task.sleep(nanoseconds: 500_000_000)
        try await sock.remove(name: name, force: true)

        // The wait must resolve within 5s of the removal
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            waitTask.cancel()
        }
        do {
            try await waitTask.value
            timeoutTask.cancel()
        } catch is CancellationError {
            throw CheckError.assertionFailed("wait?condition=removed timed out after 5s")
        }
    }
}
