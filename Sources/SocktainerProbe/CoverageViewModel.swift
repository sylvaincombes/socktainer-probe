import AppKit
import Foundation
import SocktainerProbeCore

@MainActor
@Observable
final class CoverageViewModel {

    enum LoadState { case idle, loading, fetchingGitHub, loaded, noSource }
    enum SpecialFilter: Equatable { case noTest }

    static let defaultRepoURL = "https://github.com/socktainer/socktainer"

    var state: LoadState = .idle
    var results: [EndpointResult] = []
    var summary: CoverageSummary? = nil
    var filterStatus: EndpointStatus? = nil
    var specialFilter: SpecialFilter? = nil
    var searchText: String = ""

    var filtered: [EndpointResult] {
        results.filter { r in
            let statusMatch: Bool
            if let sf = specialFilter {
                switch sf {
                case .noTest: statusMatch = r.status == .implemented && r.testID == nil
                }
            } else {
                statusMatch = filterStatus == nil || r.status == filterStatus
            }
            let searchMatch = searchText.isEmpty
                || r.path.localizedCaseInsensitiveContains(searchText)
                || r.method.localizedCaseInsensitiveContains(searchText)
                || (r.testID?.localizedCaseInsensitiveContains(searchText) ?? false)
            return statusMatch && searchMatch
        }
    }

    // MARK: - Load

    func load() async {
        guard case .idle = state else { return }
        state = .loading

        let config = CheckConfig.load()
        let sourceDir = resolveSourceDir(from: config)

        // Try local source first; if not found, try GitHub automatically
        let (res, sum, found) = await Task.detached(priority: .userInitiated) {
            await computeCoverageResults(
                socktainerSourceDir: sourceDir,
                githubRepoURL: nil  // first pass: local only
            )
        }.value

        if found {
            results = res; summary = sum; state = .loaded
            return
        }

        // Local not found → fetch from GitHub
        state = .fetchingGitHub
        let (ghRes, ghSum, ghFound) = await Task.detached(priority: .userInitiated) {
            await computeCoverageResults(
                socktainerSourceDir: sourceDir,
                githubRepoURL: Self.defaultRepoURL
            )
        }.value

        results = ghRes; summary = ghSum
        state = ghFound ? .loaded : .noSource
    }

    func reload() {
        // Bust the GitHub cache so a fresh fetch is forced
        let cachePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".socktainer-probe/routes-github-cache.json")
        try? FileManager.default.removeItem(at: cachePath)
        state = .idle; results = []; summary = nil
        Task { await load() }
    }

    // MARK: - Browse

    func browseForSourceDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the Socktainer Routes directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var config = CheckConfig.load() ?? CheckConfig(
            dockerBinary: DockerCLI.resolvedBinary, socktainerSource: nil, referenceContext: "colima")
        config.socktainerSource = .sourceFolder(path: url.path, buildBeforeStart: false)
        try? config.save()
        state = .idle; results = []; summary = nil
        Task { await load() }
    }

    // MARK: - Source links

    func sourceURL(for endpoint: EndpointResult) -> URL? {
        guard endpoint.status == .implemented else { return nil }
        return URL(string: "\(Self.defaultRepoURL)/tree/main/Sources/socktainer/Routes")
    }

    // MARK: - Markdown export

    func copyAsMarkdown() {
        guard let sum = summary else { return }
        var md = "## Docker Engine API v28.5.2 Coverage — Socktainer\n\n"
        md += "> Source: [socktainer/socktainer](\(Self.defaultRepoURL)) · "
        md += "Spec: [Moby v28.5.2](https://github.com/moby/moby/blob/v28.5.2/api/swagger.yaml)\n\n"
        md += "| | Metric | Value |\n|---|---|---|\n"
        md += "| ✅ | Implemented | \(sum.implemented)/\(sum.testable) (\(sum.implementedPct)%) |\n"
        md += "| 🧪 | With test coverage | \(sum.testedCount)/\(sum.implemented) (\(sum.testedPct)%) |\n"
        md += "| ❌ | Missing (straightforward) | \(sum.notImplemented) |\n"
        md += "| 🔧 | Doable with workaround | \(sum.doableWithWorkaround) |\n"
        md += "| 🔴 | Platform limitation (Apple Container 1.0) | \(sum.platformLimitations) |\n"
        md += "| 🚫 | Not applicable (Swarm/Plugins) | \(sum.notApplicable) |\n\n"

        let workarounds = results.filter { $0.status == .doableWithWorkaround }
        if !workarounds.isEmpty {
            md += "<details>\n<summary>🔧 Doable with workaround (\(workarounds.count))</summary>\n\n"
            md += "| Method | Endpoint | Suggestion |\n|---|---|---|\n"
            for e in workarounds { md += "| `\(e.method)` | `\(e.path)` | \(e.note ?? "") |\n" }
            md += "\n</details>\n\n"
        }

        let missing = results.filter { $0.status == .notImplemented }
        if !missing.isEmpty {
            md += "<details>\n<summary>❌ Missing endpoints (\(missing.count))</summary>\n\n"
            md += "| Method | Endpoint |\n|---|---|\n"
            for e in missing { md += "| `\(e.method)` | `\(e.path)` |\n" }
            md += "\n</details>\n\n"
        }

        let noTest = results.filter { $0.status == .implemented && $0.testID == nil }
        if !noTest.isEmpty {
            md += "<details>\n<summary>🧪 Implemented but untested (\(noTest.count))</summary>\n\n"
            md += "| Method | Endpoint |\n|---|---|\n"
            for e in noTest { md += "| `\(e.method)` | `\(e.path)` |\n" }
            md += "\n</details>\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    // MARK: - Private

    private func resolveSourceDir(from config: CheckConfig?) -> String? {
        if let dir = config?.socktainerSource?.sourceDirForCoverage { return dir }
        if case .binary(let bin) = config?.socktainerSource {
            let candidate = URL(fileURLWithPath: bin)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/socktainer/Routes").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
