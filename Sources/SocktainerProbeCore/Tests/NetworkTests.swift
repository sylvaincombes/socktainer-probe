import Foundation

public func runNetworkSection(sock: DockerCLI) async {
    section("Network connect / disconnect")

    await xfail("docker network connect attaches a running container to a network",
                id: "NET-002",
                reason: "POST /networks/{id}/connect not yet implemented in Socktainer 1.0.0",
                repro: """
                    docker --context socktainer network create test-net
                    docker --context socktainer run -d --name ctr alpine sleep 30
                    docker --context socktainer network connect test-net ctr
                    docker --context socktainer inspect ctr --format '{{json .NetworkSettings.Networks}}'
                    """) {
        let net = "check-nc-net-\(Int.random(in: 10000...99999))"
        let ctr = "check-nc-ctr-\(Int.random(in: 10000...99999))"
        try await sock.networkCreate(name: net)
        defer {
            Task {
                try? await sock.networkDisconnect(network: net, container: ctr)
                try? await sock.networkRemove(name: net)
            }
        }
        _ = try await sock.runContainer(name: ctr, image: "public.ecr.aws/docker/library/alpine",
                                        rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: ctr, force: true) } }
        try await sock.networkConnect(network: net, container: ctr)
        let info = try await sock.inspect(name: ctr)
        let networks = ((info["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any]) ?? [:]
        try assert(networks.keys.contains(net),
                   "container should be attached to '\(net)', got networks: \(Array(networks.keys))")
    }

    // ── Network filtering (PR #58 — DockerNetworkFilterUtility) ──────────────

    await check("docker network ls --filter 'label=key=val' lists only labelled networks",
                id: "NET-004", refs: ["#58"],
                repro: "docker --context socktainer network create --label probe=yes net1\ndocker --context socktainer network ls --filter 'label=probe=yes'") {
        let tagged   = "check-netfilt-yes-\(Int.random(in: 10000...99999))"
        let untagged = "check-netfilt-no-\(Int.random(in: 10000...99999))"
        try await sock.networkCreate(name: tagged,   labels: ["socktainer-probe-net-filter": "yes"])
        try await sock.networkCreate(name: untagged)
        defer {
            Task { try? await sock.networkRemove(name: tagged) }
            Task { try? await sock.networkRemove(name: untagged) }
        }
        // docker network ls --filter 'label=key=val'
        let result = try await sock.run_(["network", "ls", "--format", "{{.Name}}", "--filter", "label=socktainer-probe-net-filter=yes"])
        let listed = result.split(separator: "\n").map(String.init)
        try assert(listed.contains(tagged),    "labelled network '\(tagged)' should appear in filtered list")
        try assert(!listed.contains(untagged), "untagged network '\(untagged)' should not appear in filtered list")
    }

    await xfail("docker network disconnect detaches a container from a network",
                id: "NET-003",
                reason: "POST /networks/{id}/disconnect not yet implemented in Socktainer 1.0.0",
                repro: """
                    docker --context socktainer network create test-net
                    docker --context socktainer run -d --network test-net --name ctr alpine sleep 30
                    docker --context socktainer network disconnect test-net ctr
                    """) {
        let net = "check-nd-net-\(Int.random(in: 10000...99999))"
        let ctr = "check-nd-ctr-\(Int.random(in: 10000...99999))"
        try await sock.networkCreate(name: net)
        defer { Task { try? await sock.networkRemove(name: net) } }
        _ = try await sock.runContainer(name: ctr, image: "public.ecr.aws/docker/library/alpine",
                                        network: net, rm: false, detach: true, cmd: ["sleep", "30"])
        defer { Task { try? await sock.remove(name: ctr, force: true) } }
        try await sock.networkDisconnect(network: net, container: ctr, force: true)
        let info = try await sock.inspect(name: ctr)
        let networks = ((info["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any]) ?? [:]
        try assert(!networks.keys.contains(net),
                   "container should no longer be on '\(net)', got networks: \(Array(networks.keys))")
    }
}
