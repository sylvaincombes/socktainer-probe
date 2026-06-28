import Foundation
import SocktainerProbeCore

@MainActor
@Observable
final class SettingsViewModel {

    enum SourceMode: String, CaseIterable {
        case running      = "Use running instance"
        case binary       = "Binary path"
        case sourceFolder = "Source folder"
    }

    var dockerBinary: String = ""
    var sourceMode: SourceMode = .running
    var socktainerBinary: String = ""
    var socktainerSourceFolder: String = ""
    var buildBeforeStart: Bool = false
    var referenceContext: String = "colima"

    var discoveredDockerBinaries: [DiscoveredBinary] = []
    var discoveredSocktainerBinaries: [DiscoveredBinary] = []
    var discoveredSocktainerSources: [DiscoveredBinary] = []
    var availableContexts: [String] = []

    var isLoading = false
    var saveStatus: SaveStatus = .idle
    var verifyStatus: VerifyStatus = .idle

    enum SaveStatus: Equatable { case idle, saved, error(String) }
    enum VerifyStatus: Equatable {
        case idle, verifying
        case ok(docker: String, socktainer: String, appleContainer: String)
        case error(String)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        if let config = CheckConfig.load() {
            dockerBinary = config.dockerBinary
            referenceContext = config.referenceContext
            switch config.socktainerSource {
            case .binary(let path):
                sourceMode = .binary
                socktainerBinary = path
            case .sourceFolder(let path, let build):
                sourceMode = .sourceFolder
                socktainerSourceFolder = path
                buildBeforeStart = build
            case nil:
                sourceMode = .running
            }
        }

        discoveredDockerBinaries    = discoverDockerBinaries()
        discoveredSocktainerBinaries = discoverSocktainerBinaries()
        discoveredSocktainerSources  = discoverSocktainerSources()

        if dockerBinary.isEmpty {
            dockerBinary = discoveredDockerBinaries.first?.path ?? DockerCLI.resolvedBinary
        }

        DockerCLI.configuredBinary = dockerBinary
        let docker = DockerCLI(context: "default")
        if let contexts = try? await docker.contextNames() {
            availableContexts = contexts.filter { $0 != "socktainer" && !$0.isEmpty }
        }
        if availableContexts.isEmpty { availableContexts = ["colima", "orbstack", "default"] }
        if !availableContexts.contains(referenceContext), let first = availableContexts.first {
            referenceContext = first
        }
    }

    func save() {
        let source: SocktainerSource?
        switch sourceMode {
        case .running:
            source = nil
        case .binary:
            source = socktainerBinary.isEmpty ? nil : .binary(path: socktainerBinary)
        case .sourceFolder:
            source = socktainerSourceFolder.isEmpty ? nil
                : .sourceFolder(path: socktainerSourceFolder, buildBeforeStart: buildBeforeStart)
        }
        let config = CheckConfig(dockerBinary: dockerBinary, socktainerSource: source,
                                 referenceContext: referenceContext)
        do {
            try config.save()
            DockerCLI.configuredBinary = dockerBinary
            saveStatus = .saved
            Task { try? await Task.sleep(for: .seconds(2)); saveStatus = .idle }
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    func verifyConnection() async {
        verifyStatus = .verifying
        DockerCLI.configuredBinary = dockerBinary
        let sock = DockerCLI(context: "socktainer")

        do {
            let dockerVer = (try? await sock.info()) ?? "unknown"
            let containerVerData = try? Process.output("/usr/local/bin/container", "--version")
            let containerVer = containerVerData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            verifyStatus = .ok(
                docker: dockerBinary.components(separatedBy: "/").last ?? "docker",
                socktainer: dockerVer.components(separatedBy: "\n").first ?? dockerVer,
                appleContainer: containerVer
            )
        }
    }
}
