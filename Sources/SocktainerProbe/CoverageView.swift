import AppKit
import SocktainerProbeCore
import SwiftUI

struct CoverageView: View {
    @Bindable var vm: CoverageViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch vm.state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView("Loading Docker Engine API v28.5.2 spec…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .fetchingGitHub:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Fetching route registrations from github.com/socktainer/socktainer…")
                        .foregroundStyle(.secondary)
                    Text("Results are cached for 24 hours.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noSource:
                noSourceView
            case .loaded:
                loadedView
            }
        }
        .navigationTitle("API Coverage")
        .task { await vm.load() }
    }

    // MARK: - No source

    private var noSourceView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Socktainer source not found")
                .font(.title3).fontWeight(.semibold)
            VStack(spacing: 6) {
                Text("Coverage analysis parses registered routes from Socktainer's Swift source.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Expected at `~/Projects/socktainer/Sources/socktainer/Routes`")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button("Choose source directory…") { vm.browseForSourceDir() }
                    .buttonStyle(.bordered)
                Button { vm.reload() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
            }
            if let sum = vm.summary, sum.total > 0 {
                Text("Spec loaded: \(sum.total) Docker Engine API v28.5.2 endpoints.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loaded

    private var loadedView: some View {
        VStack(spacing: 0) {
            if let sum = vm.summary { summaryBar(sum) }
            Divider()
            filterBar
            Divider()
            endpointTable
        }
    }

    // MARK: - Summary bar

    private func summaryBar(_ s: CoverageSummary) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Docker Engine API v28.5.2 — Moby/Moby")
                    .font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 16) {
                    summaryChip("\(s.implementedPct)%", label: "implemented", color: .green)
                    summaryChip("\(s.implemented)/\(s.testable)", label: "testable", color: .blue)
                    summaryChip("\(s.testedCount)", label: "with test", color: .purple)
                    summaryChip("\(s.notImplemented)", label: "missing", color: .red)
                    summaryChip("\(s.doableWithWorkaround)", label: "workaround",
                                color: Color(red: 0.8, green: 0.6, blue: 0.0))
                    summaryChip("\(s.platformLimitations)", label: "platform limit", color: .purple.opacity(0.7))
                    summaryChip("\(s.notApplicable)", label: "N/A", color: .secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button { vm.copyAsMarkdown() } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered).controlSize(.small)
                TextField("Search endpoints…", text: $vm.searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func summaryChip(_ value: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.semibold).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(.callout))
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("All", status: nil)
                filterChip("Implemented", status: .implemented)
                filterChip("No test (\(vm.summary.map { $0.implemented - $0.testedCount } ?? 0))",
                           status: nil, special: .noTest)
                filterChip("Missing (\(vm.summary?.notImplemented ?? 0))", status: .notImplemented)
                filterChip("Workaround (\(vm.summary?.doableWithWorkaround ?? 0))",
                           status: .doableWithWorkaround)
                filterChip("Platform limit (\(vm.summary?.platformLimitations ?? 0))",
                           status: .platformLimitation)
                filterChip("N/A (Swarm)", status: .notApplicable)
                filterChip("Stub", status: .stub)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    private func filterChip(_ label: String, status: EndpointStatus?,
                             special: CoverageViewModel.SpecialFilter? = nil) -> some View {
        let active = special == nil ? vm.filterStatus == status && vm.specialFilter == nil
                                    : vm.specialFilter == special
        return Button {
            vm.filterStatus = status
            vm.specialFilter = special
        } label: {
            Text(label)
                .font(.system(.caption, weight: active ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Table

    @ViewBuilder
    private var endpointTable: some View {
        let rows = vm.filtered
        if rows.isEmpty {
            Text("No endpoints match the current filter.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("") { row in
                    MethodBadge(method: row.method)
                }
                .width(min: 55, ideal: 65, max: 75)

                TableColumn("Endpoint") { row in
                    HStack(spacing: 6) {
                        Text(row.path)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(row.status == .notApplicable ? .tertiary : .primary)
                        if let note = row.note, row.status == .notApplicable {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                TableColumn("Status") { row in
                    StatusBadge(status: row.status)
                }
                .width(min: 120, ideal: 140, max: 160)

                TableColumn("Test coverage") { row in
                    if let tid = row.testID {
                        Text(tid)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.purple)
                    } else if row.status == .implemented {
                        Text("no test")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .width(min: 90, ideal: 130)

                TableColumn("Links") { row in
                    HStack(spacing: 8) {
                        if let docsURL = row.docsURL {
                            Link(destination: docsURL) {
                                Label("Docs", systemImage: "book")
                                    .font(.caption).labelStyle(.titleAndIcon)
                                    .foregroundStyle(Color.blue)
                            }
                        }
                        if row.status == .implemented, let srcURL = vm.sourceURL(for: row) {
                            Link(destination: srcURL) {
                                Label("Src", systemImage: "chevron.left.forwardslash.chevron.right")
                                    .font(.caption).labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
                .width(min: 80, ideal: 100)
            }
        }
    }
}

// MARK: - Badges

private struct MethodBadge: View {
    let method: String
    var body: some View {
        Text(method)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch method {
        case "GET": return .blue; case "POST": return .green
        case "DELETE": return .red; case "PUT": return .orange
        default: return .secondary
        }
    }
}

private struct StatusBadge: View {
    let status: EndpointStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(.caption))
        }
        .foregroundStyle(color)
    }
    private var label: String {
        switch status {
        case .implemented:          "Implemented"
        case .stub:                 "Stub"
        case .notImplemented:       "Missing"
        case .notApplicable:        "N/A"
        case .platformLimitation:   "Platform limit"
        case .doableWithWorkaround: "Workaround possible"
        }
    }
    private var color: Color {
        switch status {
        case .implemented:          .green
        case .stub:                 .orange
        case .notImplemented:       .red
        case .notApplicable:        .secondary
        case .platformLimitation:   .purple
        case .doableWithWorkaround: Color(red: 0.8, green: 0.6, blue: 0.0) // amber
        }
    }
}
