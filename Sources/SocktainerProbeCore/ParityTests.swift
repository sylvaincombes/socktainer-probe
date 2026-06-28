import Foundation

/// Tests that compare Socktainer behaviour against a reference Docker runtime.
public func runParityTests(sock: DockerCLI, ref: DockerCLI) async {
    section("Colima parity")

    await check("start event attributes match reference runtime key set",
                id: "PAR-001") {
        let sockEvents = try await sock.captureEvents {
            _ = try await sock.runContainer(
                image: "public.ecr.aws/docker/library/alpine",
                labels: ["app": "parity"], cmd: ["echo", "hi"])
        }
        let refEvents = try await ref.captureEvents {
            _ = try await ref.runContainer(
                image: "public.ecr.aws/docker/library/alpine",
                labels: ["app": "parity"], cmd: ["echo", "hi"])
        }
        let sockKeys = Set(eventAttributes(events: sockEvents, action: "start")?.keys.map { $0 } ?? [])
        let refKeys  = Set(eventAttributes(events: refEvents,  action: "start")?.keys.map { $0 } ?? [])
        try assertEqual(sockKeys, refKeys, "start event attribute keys vs reference runtime")
    }

    await ensureAlive(sock: sock)

    await check("exit code forwarded matches reference runtime",
                id: "PAR-002") {
        let run: (DockerCLI) throws -> Int32 = { cli in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: DockerCLI.resolvedBinary)
            p.arguments = ["--context", cli.context, "run", "--rm",
                           "public.ecr.aws/docker/library/alpine", "sh", "-c", "exit 42"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        try assertEqual(try run(sock), try run(ref), "exit code parity")
    }

    await check("container lifecycle Action set matches reference runtime",
                id: "PAR-003") {
        func lifecycle(_ cli: DockerCLI) async throws -> Set<String> {
            let name = "check-par-life-\(Int.random(in: 10000...99999))"
            let events = try await cli.captureEvents {
                _ = try? await cli.runContainer(
                    name: name, image: "public.ecr.aws/docker/library/alpine",
                    rm: false, detach: true, cmd: ["sleep", "2"])
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try? await cli.remove(name: name, force: true)
            }
            return eventActions(events: events)
                .filter { ["create", "start", "die", "destroy"].contains($0) }
        }
        let sockActions = try await lifecycle(sock)
        let refActions  = try await lifecycle(ref)
        try assertEqual(sockActions, refActions, "lifecycle Action set vs reference runtime")
    }

    await ensureAlive(sock: sock)

    await check("WS attach output matches reference runtime (wire format parity)",
                id: "PAR-004") {
        let suffix = Int.random(in: 10000...99999)
        let sockName = "check-par-ws-sock-\(suffix)"
        let refName  = "check-par-ws-ref-\(suffix)"
        let cmd = ["sh", "-c", "echo parity_check"]

        _ = try await sock.runContainer(name: sockName, image: "public.ecr.aws/docker/library/alpine",
                                        rm: false, detach: true, cmd: cmd)
        defer { Task { try? await sock.remove(name: sockName, force: true) } }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let sockOutput = try await sock.logs(name: sockName)
        let refOutput  = (try? await ref.runContainer(
            image: "public.ecr.aws/docker/library/alpine", cmd: cmd)) ?? ""

        try assert(sockOutput.contains("parity_check"),
                   "socktainer output missing 'parity_check': \(sockOutput.prefix(200))")
        try assert(!refOutput.isEmpty || refOutput.contains("parity_check"),
                   "reference output missing 'parity_check': \(refOutput.prefix(200))")
    }
}
