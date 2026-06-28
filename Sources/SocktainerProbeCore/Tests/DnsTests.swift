import Foundation

// DNS tests use docker compose to create a real network with two services,
// then verify one service can resolve the other's hostname. This directly
// validates that the embedded dns-forwarder sidecar works end-to-end.
public func runDnsSection(sock: DockerCLI) async {
    section("Inter-container DNS")

    await check("compose service resolves peer hostname via dns-forwarder",
                id: "DNS-001", refs: ["socktainer/dns-forwarder#1", "#238"],
                repro: "docker compose up -d server && docker compose run --rm client ping -c 1 server") {
        let suffix = Int.random(in: 10000...99999)
        let composeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-dns-\(suffix).yml").path
        let content = """
            name: sck-dns-\(suffix)
            services:
              server:
                image: alpine
                command: sleep 30
              client:
                image: alpine
                command: sleep 1
            """
        try content.write(toFile: composeFile, atomically: true, encoding: .utf8)

        // Start the server service so it gets a hostname and IP registered in SocktainerDNSServer.
        _ = try await sock.compose(file: composeFile, "up", "-d", "server")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Run the client in the same compose network — it must resolve 'server' via the
        // dns-forwarder sidecar (socktainer-dns:embedded → SocktainerDNSServer on host).
        let output = try await sock.compose(
            file: composeFile,
            args: ["run", "--rm", "client", "sh", "-c",
                   "ping -c 1 -W 3 server > /dev/null 2>&1 && echo DNS-RESOLVED || echo DNS-FAILED"]
        )
        _ = try? await sock.compose(file: composeFile, "down", "--remove-orphans")
        try? FileManager.default.removeItem(atPath: composeFile)

        try assert(output.contains("DNS-RESOLVED"),
                   "hostname 'server' should resolve via dns-forwarder — got: \(output)")
    }
}
