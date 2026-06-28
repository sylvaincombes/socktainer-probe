import Foundation

public func runArchiveSection(sock: DockerCLI) async {
    section("Container archive (docker cp)")

    await check("docker cp exports a file from container to host",
                id: "ARC-001", refs: [],
                repro: "docker --context socktainer run --name test alpine sh -c 'echo payload > /data.txt'\ndocker --context socktainer cp test:/data.txt /tmp/") {
        let name = "check-arc-\(Int.random(in: 1000...9999))"
        let localPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-arc-\(name).txt").path

        // Create a container that writes a known file, then exits.
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false,
            cmd: ["sh", "-c", "echo payload-arc > /data.txt"]
        )
        defer {
            Task { try? await sock.remove(name: name, force: true) }
            try? FileManager.default.removeItem(atPath: localPath)
        }

        try await sock.cpFromContainer(container: name, containerPath: "/data.txt", localPath: localPath)

        let content = try String(contentsOfFile: localPath, encoding: .utf8)
        try assert(content.trimmingCharacters(in: .whitespacesAndNewlines) == "payload-arc",
                   "copied file must contain 'payload-arc', got: \(content)")
    }

    await check("docker cp imports a file from host into a running container",
                id: "ARC-002", refs: [],
                repro: "echo 'host-content' > /tmp/inject.txt\ndocker --context socktainer run -d --name test alpine sleep 30\ndocker --context socktainer cp /tmp/inject.txt test:/inject.txt\ndocker --context socktainer exec test cat /inject.txt") {
        let name = "check-arc2-\(Int.random(in: 1000...9999))"
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-inject-\(name).txt").path

        try "host-content".write(toFile: localFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: localFile) }

        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sleep", "30"]
        )
        defer { Task { try? await sock.remove(name: name, force: true) } }

        try await sock.cpToContainer(localPath: localFile, container: name, containerPath: "/inject.txt")

        let output = try await sock.exec(name: name, cmd: ["cat", "/inject.txt"])
        try assert(output.trimmingCharacters(in: .whitespacesAndNewlines) == "host-content",
                   "injected file must contain 'host-content', got: \(output)")
    }
}
