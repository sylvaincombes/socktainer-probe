import Foundation

/// Manages the lifecycle of a Socktainer binary for integration testing.
///
/// When a binary path is given, the harness kills any running Socktainer,
/// starts the specified binary on the standard socket, and tears it down
/// at the end. Without a binary path, it uses the already-running instance.
public actor SocktainerHarness {
    public let context = "socktainer"

    private var process: Process?
    public let binaryPath: String?
    /// Set in source mode — the repo root from which `make release` is run.
    private let sourcePath: String?
    private let shouldBuild: Bool

    /// Called with each chunk of build output when building from source.
    /// Set this before calling `start()` to receive progress in the UI.
    /// Declared nonisolated(unsafe) so callers can set it without an actor hop.
    public nonisolated(unsafe) var buildProgressCallback: (@Sendable (String) -> Void)? = nil

    /// The active `make release` process. nonisolated(unsafe) so it can be
    /// terminated from a withTaskCancellationHandler onCancel closure.
    private nonisolated(unsafe) var buildProcess: Process? = nil

    public static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".socktainer/container.sock").path

    /// Where the harness-spawned daemon's stdout/stderr is captured, so its logs
    /// (e.g. diagnostic probes) survive instead of going to /dev/null.
    public static let daemonLogPath = "/tmp/socktainer-daemon.log"

    /// Returns a write handle to the daemon log, creating/truncating it on first
    /// start and appending on restart so a whole run lands in one file.
    public static func makeDaemonLogHandle(truncate: Bool) -> FileHandle {
        let fm = FileManager.default
        if truncate || !fm.fileExists(atPath: daemonLogPath) {
            fm.createFile(atPath: daemonLogPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: daemonLogPath) else {
            return FileHandle.nullDevice
        }
        if truncate { handle.truncateFile(atOffset: 0) } else { handle.seekToEndOfFile() }
        return handle
    }

    public static func system() -> SocktainerHarness {
        SocktainerHarness(binaryPath: nil, sourcePath: nil, shouldBuild: false)
    }

    public static func custom(binaryPath: String) -> SocktainerHarness {
        SocktainerHarness(binaryPath: binaryPath, sourcePath: nil, shouldBuild: false)
    }

    /// Source-folder mode: derives the binary from `{sourcePath}/.build/release/socktainer`
    /// and optionally runs `make release` before starting.
    public static func fromSource(sourcePath: String, buildBeforeStart: Bool) -> SocktainerHarness {
        let binary = "\(sourcePath)/.build/release/socktainer"
        return SocktainerHarness(binaryPath: binary, sourcePath: sourcePath, shouldBuild: buildBeforeStart)
    }

    private init(binaryPath: String?, sourcePath: String?, shouldBuild: Bool) {
        self.binaryPath = binaryPath
        self.sourcePath = sourcePath
        self.shouldBuild = shouldBuild
    }

    public func start() async throws {
        // Build from source if configured.
        if shouldBuild, let src = sourcePath {
            let callback = buildProgressCallback
            if callback == nil { print("🔨 Building Socktainer from source (make release)…") }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let make = Process()
                    self.buildProcess = make
                    make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
                    make.arguments = ["release"]
                    make.currentDirectoryURL = URL(fileURLWithPath: src)

                    if let callback {
                        let pipe = Pipe()
                        make.standardOutput = pipe
                        make.standardError = pipe
                        pipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                            if let text = String(data: data, encoding: .utf8) { callback(text) }
                        }
                    } else {
                        make.standardOutput = FileHandle.standardOutput
                        make.standardError = FileHandle.standardError
                    }

                    make.terminationHandler = { [weak self] p in
                        self?.buildProcess = nil
                        if p.terminationStatus == 0 {
                            cont.resume()
                        } else {
                            cont.resume(throwing: CheckError.commandFailed(
                                "make release", "exit \(p.terminationStatus)"))
                        }
                    }
                    do { try make.run() } catch {
                        self.buildProcess = nil
                        cont.resume(throwing: error)
                    }
                }
            } onCancel: {
                self.buildProcess?.terminate()
                self.buildProcess = nil
            }

            if callback == nil { print("✅ Build complete") }
        }

        guard let binary = binaryPath else { return }

        // Stop any running Socktainer before starting our own
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        running.arguments = ["-f", "socktainer"]
        running.standardOutput = FileHandle.nullDevice
        running.standardError = FileHandle.nullDevice
        try? running.run()
        running.waitUntilExit()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: (binary as NSString).expandingTildeInPath)
        let logHandle = Self.makeDaemonLogHandle(truncate: true)
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        process = p

        // Wait for socket (up to 10s)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: Self.socketPath) {
            guard Date() < deadline else {
                throw CheckError.commandFailed("socktainer start",
                    "socket never appeared at \(Self.socketPath)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        print("🚀 Started \((binary as NSString).lastPathComponent) → \(Self.socketPath)")
    }

    public func restart() async throws {
        guard let binary = binaryPath else { return }
        process?.terminate()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: (binary as NSString).expandingTildeInPath)
        let logHandle = Self.makeDaemonLogHandle(truncate: false)
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        process = p

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: Self.socketPath) {
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    public func stop() {
        guard binaryPath != nil else { return }
        process?.terminate()
    }
}

public extension DockerCLI {
    static var resolvedBinary: String {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"]
            .first { FileManager.default.fileExists(atPath: $0) } ?? "docker"
    }
}
