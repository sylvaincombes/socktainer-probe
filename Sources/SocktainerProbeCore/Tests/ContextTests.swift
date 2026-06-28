import Foundation

public func runContextSection(sock: DockerCLI) async {
    section("Docker context")
    await check("socktainer context is auto-registered in docker context ls",
                id: "CTX-001", refs: ["#215"],
                repro: "docker context ls --format '{{.Name}}'") {
        let names = try await sock.contextNames()
        try assert(names.contains("socktainer"), "socktainer context present")
    }
    await check("socktainer context points to the correct socket",
                id: "CTX-002", refs: ["#215"],
                repro: "docker context inspect socktainer --format '{{.Endpoints.docker.Host}}'") {
        let host = try await sock.contextEndpoint("socktainer")
        try assert(host.contains(".socktainer/container.sock"), "context points to correct socket, got: \(host)")
    }
}
