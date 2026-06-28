import Foundation

public func runLabelSection(sock: DockerCLI) async {
    section("Label normalization")
    await check("mixed-case label key round-trips through docker inspect",
                id: "LBL-001", refs: ["#221"],
                repro: "docker --context socktainer run -d --name test --label MyApp=test alpine sleep 5\ndocker --context socktainer inspect test --format '{{json .Config.Labels}}'") {
        let name = "check-label-\(Int.random(in: 1000...9999))"
        _ = try await sock.runContainer(name: name, image: "public.ecr.aws/docker/library/alpine", labels: ["MyApp": "test", "com.example.Version": "1.2"], rm: false, detach: true, cmd: ["sleep", "5"])
        let inspected = try await sock.inspect(name: name)
        let labels = (inspected["Config"] as? [String: Any])?["Labels"] as? [String: String]
        try assertEqual(labels?["MyApp"], "test", "MyApp key preserved")
        try assertEqual(labels?["com.example.Version"], "1.2", "dotted key preserved")
        try await sock.remove(name: name, force: true)
    }
    section("Label normalization — networks and volumes")
    await check("network: mixed-case label round-trips via inspect",
                id: "LBL-002", refs: ["#221"],
                repro: "docker --context socktainer network create --label 'org.testcontainers.sessionId=net1' lbl-net") {
        let name = "check-net-\(Int.random(in: 1000...9999))"
        try await sock.networkCreate(name: name, labels: ["org.testcontainers.sessionId": "net1"])
        defer { Task { try? await sock.networkRemove(name: name) } }
        let labels = try await sock.networkInspectLabels(name: name)
        try assertEqual(labels["org.testcontainers.sessionId"], "net1", "network label round-trip")
    }
    await check("volume: mixed-case label round-trips via inspect",
                id: "LBL-003", refs: ["#221"],
                repro: "docker --context socktainer volume create --label 'MyApp=prod' lbl-vol") {
        let name = "check-vol-\(Int.random(in: 1000...9999))"
        try await sock.volumeCreate(name: name, labels: ["MyApp": "prod"])
        defer { Task { try? await sock.volumeRemove(name: name) } }
        let labels = try await sock.volumeInspectLabels(name: name)
        try assertEqual(labels["MyApp"], "prod", "volume label round-trip")
    }
}
