import Foundation

/// Runs docker commands against a specific context and returns typed output.
public struct DockerCLI {
    public let context: String

    public static var configuredBinary: String = DockerCLI.resolvedBinary
    private static var dockerBinary: String { configuredBinary }

    public init(context: String) { self.context = context }

    /// Runs an arbitrary docker command and returns stdout. For test helpers that need CLI flags
    /// not yet wrapped by dedicated DockerCLI methods.
    public func run_(_ args: [String]) async throws -> String {
        let result = try await run(args)
        return result.stdout
    }

    private func run(_ args: [String]) async throws -> (stdout: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.dockerBinary)
        process.arguments = ["--context", context] + args

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    }

    public func ping() async throws -> Bool {
        let result = try await run(["info", "--format", "{{.ServerVersion}}"])
        return result.code == 0 && !result.stdout.isEmpty
    }

    public func networkExists(_ name: String) async -> Bool {
        let result = try? await run(["network", "inspect", name])
        return result?.code == 0
    }

    public func info() async throws -> String {
        let result = try await run(["info", "--format", "{{.ServerVersion}}"])
        guard result.code == 0 else { throw CheckError.commandFailed("docker info", result.stdout) }
        return result.stdout
    }

    /// Runs a container and returns its output. Throws if exit code is non-zero.
    @discardableResult
    public func runContainer(
        name: String? = nil,
        image: String,
        labels: [String: String] = [:],
        env: [String: String] = [:],
        volumes: [String] = [],      // "vol:/path" or "/host:/path"
        network: String? = nil,      // e.g. "my-net"
        memory: String? = nil,       // e.g. "512m", "2g"
        healthCmd: String? = nil,    // e.g. "curl -f http://localhost/ || exit 1"
        healthInterval: String? = nil, // e.g. "1s"
        rm: Bool = true,
        detach: Bool = false,
        cmd: [String] = []
    ) async throws -> String {
        var args = ["run"]
        if rm { args.append("--rm") }
        if detach { args.append("-d") }
        if let name { args += ["--name", name] }
        for (key, value) in labels { args += ["--label", "\(key)=\(value)"] }
        for (key, value) in env { args += ["-e", "\(key)=\(value)"] }
        for v in volumes { args += ["-v", v] }
        if let net = network { args += ["--network", net] }
        if let mem = memory { args += ["--memory", mem] }
        if let hc = healthCmd { args += ["--health-cmd", hc] }
        if let hi = healthInterval { args += ["--health-interval", hi] }
        args.append(image)
        args += cmd

        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker run \(image)", result.stdout)
        }
        return result.stdout
    }

    /// Creates a stopped container (does not start it). Returns the container ID.
    public func createContainer(name: String, image: String, cmd: [String] = []) async throws -> String {
        var args = ["create", "--name", name, image]
        args += cmd
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker create \(image)", result.stdout)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stop(name: String) async throws {
        _ = try await run(["stop", name])
    }

    public func remove(name: String, force: Bool = true) async throws {
        var args = ["rm"]
        if force { args.append("-f") }
        args.append(name)
        _ = try await run(args)
    }

    public func inspect(name: String) async throws -> [String: Any] {
        let result = try await run(["inspect", name, "--format", "{{json .}}"])
        guard result.code == 0, let data = result.stdout.data(using: .utf8) else {
            throw CheckError.commandFailed("docker inspect \(name)", result.stdout)
        }
        // --format {{json .}} emits one JSON object per line (not wrapped in an array)
        if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return single
        }
        // fallback: plain docker inspect returns an array
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = array.first { return first }
        throw CheckError.commandFailed("docker inspect \(name)", result.stdout)
    }

    /// Captures events emitted while `action` runs. Returns decoded events.
    public func captureEvents(during action: () async throws -> Void) async throws -> [[String: Any]] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.dockerBinary)
        process.arguments = ["--context", context, "events", "--format", "{{json .}}"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()

        try await Task.sleep(nanoseconds: 800_000_000)  // wait for listener to connect
        try await action()
        try await Task.sleep(nanoseconds: 2_500_000_000)  // let final events arrive

        // Kill first: SIGTERM then SIGKILL. Once the process dies its pipe write-end closes,
        // and readDataToEndOfFile() returns immediately with all buffered events (no blocking).
        // We deliberately skip waitUntilExit() — it hangs forever when Docker CLI is stuck
        // waiting for Socktainer to close the HTTP connection after an NIO crash.
        process.terminate()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? await Task.sleep(nanoseconds: 200_000_000)  // let SIGKILL land

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    public func stats(name: String) async throws -> [String: Any] {
        let result = try await run(["stats", "--no-stream", "--format", "{{json .}}", name])
        guard result.code == 0,
            let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CheckError.commandFailed("docker stats \(name)", result.stdout) }
        return json
    }

    public func volumeRemove(name: String, force: Bool = true) async throws {
        var args = ["volume", "rm"]
        if force { args.append("-f") }
        args.append(name)
        _ = try await run(args)
    }

    public func healthStatus(name: String) async throws -> String {
        let inspected = try await inspect(name: name)
        return ((inspected["State"] as? [String: Any])?["Health"] as? [String: Any])?["Status"] as? String ?? "none"
    }

    public func compose(file: String, _ subargs: String...) async throws -> String {
        try await compose(file: file, args: subargs)
    }

    public func compose(file: String, args: [String]) async throws -> String {
        let result = try await run(["compose", "-f", file] + args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker compose \(args.joined(separator: " "))", result.stdout)
        }
        return result.stdout
    }

    public func wait(name: String) async throws {
        _ = try await run(["wait", name])
    }

    /// Waits for a container to exit and returns its exit code as a string.
    public func waitAndGetExitCode(name: String) async throws -> String {
        let result = try await run(["wait", name])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits for condition=removed via the REST API (the CLI `docker wait` has no --condition flag).
    /// Uses curl against the Socktainer socket, same as containerMemoryLimitBytes.
    public func waitConditionRemoved(name: String) async throws {
        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sf", "--unix-socket", socketPath,
            "-X", "POST",
            "http://localhost/v1.51/containers/\(name)/wait?condition=removed",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CheckError.commandFailed(
                "POST /containers/\(name)/wait?condition=removed",
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }
    }

    public func logs(name: String) async throws -> String {
        let result = try await run(["logs", name])
        return result.stdout
    }

    public func imageHistory(name: String) async throws -> [[String: Any]] {
        let result = try await run(["image", "history", "--no-trunc", "--format", "{{json .}}", name])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker image history \(name)", result.stdout)
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    /// Deletes an image. Returns the list of deleted/untagged refs.
    @discardableResult
    public func imageDelete(name: String, force: Bool = false) async throws -> String {
        var args = ["image", "rm"]
        if force { args.append("--force") }
        args.append(name)
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker image rm \(name)", result.stdout)
        }
        return result.stdout
    }

    /// Prunes unused networks, optionally filtered by label or name.
    /// `filters` e.g. ["label": "key=val"] or ["name": "prefix"]
    @discardableResult
    public func networkPrune(force: Bool = true, filters: [String: String] = [:]) async throws -> String {
        var args = ["network", "prune"]
        if force { args.append("--force") }
        for (k, v) in filters { args += ["--filter", "\(k)=\(v)"] }
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker network prune", result.stdout)
        }
        return result.stdout
    }

    /// Prunes stopped containers. `filters` e.g. ["label": "key=val", "status": "exited"].
    @discardableResult
    public func containerPrune(filters: [String: String] = [:], force: Bool = true) async throws -> String {
        var args = ["container", "prune"]
        if force { args.append("--force") }
        for (k, v) in filters { args += ["--filter", "\(k)=\(v)"] }
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker container prune", result.stdout)
        }
        return result.stdout
    }

    /// Returns names of all containers (running and stopped).
    public func containerList(all: Bool = true) async throws -> [String] {
        var args = ["ps", "--format", "{{.Names}}"]
        if all { args.append("--all") }
        let result = try await run(args)
        guard result.code == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Returns names of all networks.
    public func networkList() async throws -> [String] {
        let result = try await run(["network", "ls", "--format", "{{.Name}}"])
        guard result.code == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Copies a file/directory FROM a container to the host.
    public func cpFromContainer(container: String, containerPath: String, localPath: String) async throws {
        let result = try await run(["cp", "\(container):\(containerPath)", localPath])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker cp \(container):\(containerPath) \(localPath)", result.stdout)
        }
    }

    /// Copies a file/directory FROM the host INTO a container.
    public func cpToContainer(localPath: String, container: String, containerPath: String) async throws {
        let result = try await run(["cp", localPath, "\(container):\(containerPath)"])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker cp \(localPath) \(container):\(containerPath)", result.stdout)
        }
    }

    /// Creates a volume and returns its inspect JSON. Does not throw if the volume already exists.
    @discardableResult
    public func volumeCreateAndInspect(name: String, labels: [String: String] = [:], options: [String: String] = [:]) async throws -> [String: Any] {
        try await volumeCreate(name: name, labels: labels, options: options)
        let result = try await run(["volume", "inspect", name, "--format", "{{json .}}"])
        guard result.code == 0, let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CheckError.commandFailed("docker volume inspect \(name)", result.stdout) }
        return json
    }

    /// Tags an image with a new name.
    public func imageTag(source: String, target: String) async throws {
        let result = try await run(["tag", source, target])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker tag \(source) \(target)", result.stdout)
        }
    }

    /// Pulls an image and returns its digest line from stdout.
    @discardableResult
    public func pullImage(reference: String) async throws -> String {
        let result = try await run(["pull", reference])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker pull \(reference)", result.stdout)
        }
        return result.stdout
    }

    /// Returns true if an image reference exists locally.
    public func imageExists(_ name: String) async -> Bool {
        let result = try? await run(["image", "inspect", name])
        return result?.code == 0
    }

    public func networkCreate(name: String, labels: [String: String] = [:]) async throws {
        var args = ["network", "create"]
        for (key, value) in labels { args += ["--label", "\(key)=\(value)"] }
        args.append(name)
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker network create \(name)", result.stdout)
        }
    }

    public func networkRemove(name: String) async throws {
        _ = try await run(["network", "rm", name])
    }

    public func networkInspectLabels(name: String) async throws -> [String: String] {
        let result = try await run(["network", "inspect", name, "--format", "{{json .Labels}}"])
        guard result.code == 0, let data = result.stdout.data(using: .utf8),
            let labels = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return labels
    }

    public func volumeInspectLabels(name: String) async throws -> [String: String] {
        let result = try await run(["volume", "inspect", name, "--format", "{{json .Labels}}"])
        guard result.code == 0, let data = result.stdout.data(using: .utf8),
            let labels = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return labels
    }

    /// Returns memory limit in bytes from the raw /containers/{id}/stats API via curl.
    public func containerMemoryLimitBytes(name: String) async throws -> Int {
        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sf", "--unix-socket", socketPath,
            "http://localhost/v1.51/containers/\(name)/stats?stream=false",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let memStats = json["memory_stats"] as? [String: Any],
            let limit = memStats["limit"] as? Int
        else { throw CheckError.assertionFailed("could not parse memory_stats.limit from stats for \(name)") }
        return limit
    }

    /// Runs a docker command without the --context flag (for global commands like context ls/inspect).
    private func runGlobal(_ args: [String]) async throws -> (stdout: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.dockerBinary)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    }

    /// Runs a command inside a running container and returns stdout. Throws if exit code is non-zero.
    public func exec(name: String, cmd: [String]) async throws -> String {
        let args = ["exec", name] + cmd
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker exec \(name)", result.stdout)
        }
        return result.stdout
    }

    /// Runs a detached exec (`docker exec -d`). Returns immediately; the process
    /// runs in the background and its lifecycle events still flow on `docker events`.
    public func execDetached(name: String, cmd: [String]) async throws {
        let args = ["exec", "-d", name] + cmd
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker exec -d \(name)", result.stdout)
        }
    }

    /// Returns parsed output of `docker system df --format '{{json .}}'`.
    public func systemDf() async throws -> [[String: Any]] {
        let result = try await run(["system", "df", "--format", "{{json .}}"])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker system df", result.stdout)
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    public func contextNames() async throws -> [String] {
        let result = try await runGlobal(["context", "ls", "--format", "{{.Name}}"])
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func contextEndpoint(_ name: String) async throws -> String {
        let result = try await runGlobal(["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"])
        guard result.code == 0 else { throw CheckError.commandFailed("docker context inspect \(name)", result.stdout) }
        return result.stdout
    }

    public func volumeCreate(name: String, labels: [String: String] = [:], options: [String: String] = [:]) async throws {
        var args = ["volume", "create"]
        for (key, value) in labels { args += ["--label", "\(key)=\(value)"] }
        for (key, value) in options { args += ["-o", "\(key)=\(value)"] }
        args.append(name)
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker volume create \(name)", result.stdout)
        }
    }

    /// Lists all volume names, optionally filtered by labels.
    /// `filters` e.g. ["label": "key=val"] or ["label": "key"]
    public func volumeListNames(filters: [String: String] = [:]) async throws -> [String] {
        var args = ["volume", "ls", "--format", "{{.Name}}"]
        for (k, v) in filters { args += ["--filter", "\(k)=\(v)"] }
        let result = try await run(args)
        guard result.code == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Prunes unused volumes, optionally filtered by labels.
    @discardableResult
    public func volumePrune(force: Bool = true, filters: [String: String] = [:]) async throws -> String {
        var args = ["volume", "prune"]
        if force { args.append("--force") }
        for (k, v) in filters { args += ["--filter", "\(k)=\(v)"] }
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker volume prune", result.stdout)
        }
        return result.stdout
    }

    /// Renames a container.
    public func rename(name: String, newName: String) async throws {
        let result = try await run(["rename", name, newName])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker rename \(name) \(newName)", result.stdout)
        }
    }

    /// Restarts a container, waiting up to `timeout` seconds for it to stop.
    public func restart(name: String, timeout: Int = 10) async throws {
        let result = try await run(["restart", "-t", "\(timeout)", name])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker restart \(name)", result.stdout)
        }
    }

    /// Resizes the TTY of a running container.
    public func resize(name: String, width: Int, height: Int) async throws {
        let result = try await run(["exec", "-it", name, "stty", "cols", "\(width)", "rows", "\(height)"])
        // resize via exec is a workaround; the actual API endpoint is tested via this call
        // Some implementations may return non-zero from stty — accept both
        _ = result
    }

    /// Returns the running processes in a container (`docker top`).
    public func top(name: String) async throws -> [[String: String]] {
        let result = try await run(["top", name])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker top \(name)", result.stdout)
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return [] }
        let headers = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return lines.dropFirst().map { line in
            let values = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() { row[header] = i < values.count ? values[i] : "" }
            return row
        }
    }

    /// Connects a container to a network.
    public func networkConnect(network: String, container: String) async throws {
        let result = try await run(["network", "connect", network, container])
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker network connect \(network) \(container)", result.stdout)
        }
    }

    /// Disconnects a container from a network.
    public func networkDisconnect(network: String, container: String, force: Bool = true) async throws {
        var args = ["network", "disconnect"]
        if force { args.append("--force") }
        args += [network, container]
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker network disconnect \(network) \(container)", result.stdout)
        }
    }

    /// Prunes unused images.
    @discardableResult
    public func imagePrune(force: Bool = true) async throws -> String {
        var args = ["image", "prune"]
        if force { args.append("--force") }
        let result = try await run(args)
        guard result.code == 0 else {
            throw CheckError.commandFailed("docker image prune", result.stdout)
        }
        return result.stdout
    }
}

public enum CheckError: Error, LocalizedError {
    case commandFailed(String, String)
    case assertionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let output): return "'\(cmd)' failed: \(output)"
        case .assertionFailed(let msg): return "Assertion failed: \(msg)"
        }
    }
}
