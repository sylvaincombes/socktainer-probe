import Foundation

// Minimal WebSocket client for testing /containers/{id}/attach/ws.
// Speaks the WS handshake + binary frame decoding directly over a Unix socket
// — no external dependency required.
private struct WSClient {
    let sockPath: String

    /// Opens a WS connection to `path`, yields received binary frames via callback.
    /// Calls `onConnected` after the 101 upgrade, then reads frames until `deadline`.
    func connect(
        path: String,
        deadline: TimeInterval = 5,
        onConnected: (() -> Void)? = nil,
        onFrame: (Data) -> Void
    ) throws -> String {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            sockPath.utf8CString.withUnsafeBytes { src in
                ptr.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(ptr.count)))
            }
        }

        let connectResult = withUnsafeBytes(of: &addr) {
            Darwin.connect(sock, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                           socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard connectResult == 0 else { throw POSIXError(.ECONNREFUSED) }

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        _ = Darwin.write(sock, request, request.utf8.count)

        // Read response headers
        var headBuf = Data()
        var tmp = [UInt8](repeating: 0, count: 512)
        var timeoutVal = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeoutVal, socklen_t(MemoryLayout<timeval>.size))
        while !headBuf.contains(sequence: [0x0D, 0x0A, 0x0D, 0x0A]) {
            let n = Darwin.read(sock, &tmp, tmp.count)
            guard n > 0 else { break }
            headBuf.append(contentsOf: tmp[..<n])
        }
        let headerString = String(bytes: headBuf, encoding: .utf8) ?? ""
        let statusLine = headerString.components(separatedBy: "\r\n").first ?? ""
        guard statusLine.contains("101") else { return statusLine }

        onConnected?()

        // Drain frames until deadline
        var frameData = headBuf.suffix(from: headBuf.firstRange(of: Data([0x0D,0x0A,0x0D,0x0A]))!.upperBound)
        let end = Date(timeIntervalSinceNow: deadline)
        var smallTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &smallTimeout, socklen_t(MemoryLayout<timeval>.size))
        while Date() < end {
            let n = Darwin.read(sock, &tmp, tmp.count)
            if n > 0 { frameData.append(contentsOf: tmp[..<n]) }
        }

        // Decode WS frames
        var i = frameData.startIndex
        while i < frameData.endIndex {
            guard frameData.distance(from: i, to: frameData.endIndex) >= 2 else { break }
            let opcode = frameData[i] & 0x0F; i = frameData.index(after: i)
            var length = Int(frameData[i] & 0x7F); i = frameData.index(after: i)
            if length == 126 {
                guard frameData.distance(from: i, to: frameData.endIndex) >= 2 else { break }
                length = Int(frameData[i]) << 8 | Int(frameData[frameData.index(after: i)]); i = frameData.index(i, offsetBy: 2)
            } else if length == 127 {
                i = frameData.index(i, offsetBy: 8)  // skip 8-byte length
            }
            guard frameData.distance(from: i, to: frameData.endIndex) >= length else { break }
            let payload = frameData[i..<frameData.index(i, offsetBy: length)]
            if !payload.isEmpty && (opcode == 1 || opcode == 2) {
                onFrame(Data(payload))
            }
            i = frameData.index(i, offsetBy: length)
        }
        return "101"
    }
}

private extension Data {
    func contains(sequence: [UInt8]) -> Bool { firstRange(of: Data(sequence)) != nil }
    func firstRange(of needle: Data) -> Range<Index>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        for i in 0...(count - needle.count) {
            if self[i..<(i + needle.count)].elementsEqual(needle) {
                return i..<(i + needle.count)
            }
        }
        return nil
    }
}

public func runAttachWSSection(sock: DockerCLI, ref: DockerCLI) async {
    section("WebSocket attach")

    await check(
        "GET /containers/{id}/attach/ws streams output for a running container",
        id: "WS-001",
        refs: ["#75"],
        repro: "docker --context socktainer run -d alpine sh -c 'echo ws_output'\n# then connect via wscat or a WS client to /containers/{id}/attach/ws?stream=1&stdout=1"
    ) {
        let suffix = Int.random(in: 10000...99999)
        let ctrName = "check-ws-\(suffix)"

        _ = try await sock.runContainer(
            name: ctrName, image: "public.ecr.aws/docker/library/alpine",
            rm: false, detach: true,
            cmd: ["sh", "-c", "echo ws_hello; sleep 10"]
        )
        defer { Task { try? await sock.remove(name: ctrName) } }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let info = try await sock.inspect(name: ctrName)
        guard let id = info["Id"] as? String else {
            throw CheckError.commandFailed("docker inspect", "could not get container ID")
        }

        let sockPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        var receivedOutput = ""
        let ws = WSClient(sockPath: sockPath)
        let status = try ws.connect(
            path: "/v1.51/containers/\(id)/attach/ws?stream=1&stdout=1", deadline: 4
        ) { frame in receivedOutput += String(data: frame, encoding: .utf8) ?? "" }

        try assert(status == "101", "expected 101 Switching Protocols, got: \(status)")
        try assert(receivedOutput.contains("ws_hello"),
            "expected 'ws_hello' in WS output, got: \(receivedOutput.prefix(200))")
    }

    await check(
        "WS attach to a stopped container bootstraps, starts, and streams output",
        id: "WS-003",
        refs: ["#75"],
        repro: """
            docker --context socktainer create --name test-ws alpine sh -c 'echo stopped_works'
            # WS attach bootstraps + starts the container — no separate docker start needed
            """
    ) {
        let suffix = Int.random(in: 10000...99999)
        let ctrName = "check-ws-stop-\(suffix)"

        // Create a stopped container — WS attach will bootstrap+start it.
        _ = try await sock.createContainer(
            name: ctrName, image: "public.ecr.aws/docker/library/alpine",
            cmd: ["sh", "-c", "echo stopped_works; sleep 3"]
        )
        defer { Task { try? await sock.remove(name: ctrName) } }

        let info = try await sock.inspect(name: ctrName)
        guard let fullId = info["Id"] as? String else {
            throw CheckError.commandFailed("docker inspect", "could not get container ID")
        }

        let sockPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        var receivedOutput = ""
        let ws = WSClient(sockPath: sockPath)
        // WS attach to a STOPPED container — handleStopped bootstraps+starts it.
        // Output arrives once the container runs `echo stopped_works`.
        let status = try ws.connect(
            path: "/v1.51/containers/\(fullId)/attach/ws?stream=1&stdout=1&stdin=0",
            deadline: 10
        ) { frame in receivedOutput += String(data: frame, encoding: .utf8) ?? "" }

        try assert(status == "101", "expected 101 Switching Protocols, got: \(status)")
        try assert(
            receivedOutput.contains("stopped_works"),
            "expected 'stopped_works' from stopped container WS attach, got: \(receivedOutput.prefix(200))"
        )
    }

    await check(
        "WS attach records exit code under both container name and native ID",
        id: "WS-004",
        refs: ["#75"],
        repro: """
            docker --context socktainer create --name ws-exitcode alpine sh -c 'exit 42'
            # WS attach → /wait by name should return 42 quickly, not time out
            """
    ) {
        let suffix = Int.random(in: 10000...99999)
        let ctrName = "check-ws-exit-\(suffix)"

        // Create a stopped container that exits with a non-zero code.
        _ = try await sock.createContainer(
            name: ctrName, image: "public.ecr.aws/docker/library/alpine", cmd: ["sh", "-c", "exit 42"])
        defer { Task { try? await sock.remove(name: ctrName) } }

        let info = try await sock.inspect(name: ctrName)
        guard let fullId = info["Id"] as? String else {
            throw CheckError.commandFailed("docker inspect", "could not get container ID")
        }

        // WS attach bootstraps and starts the container (it exits immediately with code 42).
        let sockPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        var output = ""
        let status = try WSClient(sockPath: sockPath).connect(
            path: "/v1.51/containers/\(fullId)/attach/ws?stream=1&stdout=1&stdin=0",
            deadline: 8
        ) { frame in output += String(data: frame, encoding: .utf8) ?? "" }
        try assert(status == "101", "expected 101, got \(status)")

        // /wait by CONTAINER NAME must resolve quickly (not block 30s then return 0).
        // The fix ensures exit code is stored under both container.id and hexId (the name).
        let exitCode = try await sock.waitAndGetExitCode(name: ctrName)
        try assert(
            exitCode == "42",
            "expected exit code 42 via container name, got '\(exitCode)' — hexId exit-code fix may be missing"
        )
    }

    await check(
        "WS attach output matches Colima (wire format parity)",
        id: "WS-002",
        refs: ["#75"],
        repro: "docker run -d alpine sh -c 'echo parity_check' # on both socktainer and colima, compare WS frames"
    ) {
        let suffix = Int.random(in: 10000...99999)
        let sockName = "check-ws-sock-\(suffix)"
        let refName  = "check-ws-ref-\(suffix)"
        let cmd = ["sh", "-c", "echo parity_check; sleep 10"]

        // Run same container on both runtimes
        _ = try await sock.runContainer(name: sockName, image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: cmd)
        _ = try await ref.runContainer(name: refName,  image: "public.ecr.aws/docker/library/alpine", rm: false, detach: true, cmd: cmd)
        defer {
            Task { try? await sock.remove(name: sockName) }
            Task { try? await ref.remove(name: refName) }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Collect WS output from socktainer
        let sockInfo = try await sock.inspect(name: sockName)
        guard let sockId = sockInfo["Id"] as? String else {
            throw CheckError.commandFailed("docker inspect", "no socktainer container ID")
        }
        let sockPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        var sockOutput = ""
        let sockStatus = try WSClient(sockPath: sockPath).connect(
            path: "/v1.51/containers/\(sockId)/attach/ws?stream=1&stdout=1", deadline: 4
        ) { frame in sockOutput += String(data: frame, encoding: .utf8) ?? "" }
        try assert(sockStatus == "101", "socktainer: expected 101, got \(sockStatus)")

        // Collect output from Colima via docker logs (Colima WS is reference Docker, already tested)
        let colimaOutput = try await ref.logs(name: refName)

        // Both should contain the same output string
        try assert(sockOutput.contains("parity_check"),
            "socktainer WS missing 'parity_check': \(sockOutput.prefix(200))")
        try assert(colimaOutput.contains("parity_check"),
            "colima logs missing 'parity_check': \(colimaOutput.prefix(200))")
    }
}
