import AppKit
import SocktainerProbeCore

// MARK: - Markdown formatting

func resultMarkdown(_ result: TestResult, environment: RunEnvironment? = nil) -> String {
    var md = ""

    let idLabel = result.id.map { "[\($0)] " } ?? ""
    let statusLabel: String
    switch result.status {
    case .passed:        statusLabel = "✅ Passed"
    case .failed:        statusLabel = "❌ Failed"
    case .skipped:       statusLabel = "⏭ Skipped"
    case .knownFailure:  statusLabel = "⚠️ Known failure"
    case .unexpectedPass: statusLabel = "🎉 Unexpected pass"
    }

    md += "### \(idLabel)\(result.name)\n\n"
    md += "**Status:** \(statusLabel)  \n"
    md += "**Section:** \(result.section)  \n"
    md += "**Duration:** \(String(format: "%.2fs", Double(result.durationMs) / 1000))  \n"

    if !result.refs.isEmpty {
        md += "**Related:** \(result.refs.joined(separator: ", "))\n"
    }

    if let reason = result.failureReason {
        md += "\n**Failure:**\n```\n\(reason)\n```\n"
    }

    if let repro = result.reproCommand {
        md += "\n**Repro:**\n```sh\n\(repro)\n```\n"
    }

    if let env = environment {
        md += "\n**Environment:**\n"
        md += "- Socktainer: `\(env.socktainerVersion)`\n"
        md += "- Apple Container: `\(env.appleContainerVersion)`\n"
        md += "- macOS: \(env.macosVersion)\n"
        md += "- Machine: \(env.machineSummary)\n"
    }

    return md
}

func failuresMarkdown(results: [TestResult], environment: RunEnvironment? = nil,
                      suiteName: String? = nil) -> String {
    let failures = results.filter { $0.status == .failed }
    guard !failures.isEmpty else { return "No failures." }

    var md = "## Socktainer test failures"
    if let suite = suiteName { md += " — \(suite)" }
    md += "\n\n"
    md += "**\(failures.count) failed / \(results.count) total**\n\n"

    if let env = environment {
        md += "> **Environment:** Socktainer `\(env.socktainerVersion)` · "
        md += "Apple Container `\(env.appleContainerVersion)` · "
        md += "\(env.machineSummary) · \(env.macosVersion)\n\n"
    }

    md += "---\n\n"
    for failure in failures {
        md += resultMarkdown(failure)
        md += "\n---\n\n"
    }

    return md.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Clipboard helpers

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
