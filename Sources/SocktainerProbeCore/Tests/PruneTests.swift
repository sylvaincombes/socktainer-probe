import Foundation

public func runPruneSection(sock: DockerCLI) async {
    section("Prune operations")

    await check("docker network prune removes unused networks, keeps default",
                id: "NET-001", refs: [],
                repro: "docker --context socktainer network create prune-me\ndocker --context socktainer network prune --force") {
        let netName = "check-prune-net-\(Int.random(in: 1000...9999))"
        try await sock.networkCreate(name: netName)

        _ = try await sock.networkPrune(force: true)

        // Pruned network must be gone
        let networks = try await sock.networkList()
        try assert(!networks.contains(netName), "network \(netName) should have been pruned")

        // 'default' must survive
        try assert(networks.contains("default"), "'default' network must not be pruned")
    }

    await check("docker container prune removes stopped containers",
                id: "PRM-002", refs: [],
                repro: "docker --context socktainer run --name test alpine echo hi\ndocker --context socktainer container prune --force") {
        let name = "check-prune-ctr-\(Int.random(in: 1000...9999))"
        // Run a container that exits immediately
        _ = try await sock.runContainer(
            name: name, image: "public.ecr.aws/docker/library/alpine",
            rm: false,
            cmd: ["echo", "done"]
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        _ = try await sock.containerPrune(force: true)

        // Pruned container must be gone
        let containers = try await sock.containerList(all: true)
        try assert(!containers.contains(name), "stopped container \(name) should have been pruned")
    }
}
