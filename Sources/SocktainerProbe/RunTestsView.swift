import AppKit
import SocktainerProbeCore
import SwiftUI

struct RunTestsView: View {
    @Bindable var vm: RunTestsViewModel
    @State private var showFailuresOnly = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.isSearchActive {
                searchPanel
            } else {
                content
                Divider()
                statusBar
            }
        }
        .navigationTitle("Run Tests")
        .overlay { if vm.isBuilding { buildOverlay } }
        .task { await vm.loadSuiteCounts() }
        .onChange(of: vm.report?.runId) { _, _ in
            if let report = vm.report, report.failed > 0 { showFailuresOnly = true }
        }
        .onChange(of: vm.searchText) { _, _ in
            // Clear selection when query changes so stale names don't carry over.
            vm.selectedTestNames = []
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !vm.isSearchActive {
                    SuiteSegmentedPicker(
                        selection: $vm.selectedSuite,
                        counts: vm.suiteCounts,
                        disabled: vm.isRunning
                    )
                }

                Spacer()

                // Search field — always visible
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tests…", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 140, maxWidth: 260)
                    if !vm.searchText.isEmpty {
                        Button { vm.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor)))

                if !vm.isSearchActive {
                    if !vm.liveResults.isEmpty {
                        Toggle(isOn: $showFailuresOnly) {
                            Label("Failures only", systemImage: "xmark.circle")
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .tint(showFailuresOnly ? .red : .secondary)
                        .keyboardShortcut("f", modifiers: .command)
                    }

                    if vm.isRunning {
                        Button(role: .destructive) { vm.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        if vm.report != nil {
                            Button { vm.reset(); showFailuresOnly = false } label: {
                                Label("Clear", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                        let runLabel = vm.report != nil ? "Run Again" : "Run"
                        if vm.isSourceFolderMode {
                            // Split button: primary = use compiled binary, dropdown = build first
                            Menu {
                                Button { vm.start(); showFailuresOnly = false } label: {
                                    Label("Run (compiled binary)", systemImage: "play.fill")
                                }
                                Button { vm.startWithBuild(); showFailuresOnly = false } label: {
                                    Label("Run & Build from Source", systemImage: "hammer.fill")
                                }
                            } label: {
                                Label(runLabel, systemImage: "play.fill")
                            } primaryAction: {
                                vm.start(); showFailuresOnly = false
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("r", modifiers: .command)
                        } else {
                            Button { vm.start(); showFailuresOnly = false } label: {
                                Label(runLabel, systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("r", modifiers: .command)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if vm.isRunning {
                if let progress = vm.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Build overlay

    private var buildOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header card
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Building Socktainer from source")
                                .font(.title3.weight(.semibold))
                            if let path = vm.buildSourcePath {
                                Text("make release  ·  \(path)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            ProgressView().controlSize(.regular)
                            Button("Cancel") { vm.stop() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    // Scrolling build output
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(vm.buildOutput.isEmpty ? "Starting build…" : vm.buildOutput)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .id("buildBottom")
                        }
                        .background(Color(NSColor.textBackgroundColor).opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor)))
                        .frame(maxHeight: 280)
                        .onChange(of: vm.buildOutput) { _, _ in
                            withAnimation { proxy.scrollTo("buildBottom", anchor: .bottom) }
                        }
                    }
                }
                .padding(24)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 6)
                .padding(.horizontal, 60)
            }
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    // MARK: - Search panel

    private var searchPanel: some View {
        let filtered = vm.filteredTests
        let sections = Dictionary(grouping: filtered, by: \.section).sorted { $0.key < $1.key }
        let allSelected = !filtered.isEmpty && filtered.allSatisfy { vm.selectedTestNames.contains($0.name) }

        return VStack(spacing: 0) {
            if vm.isRunning {
                // Show live results while a filtered run is executing
                VStack(spacing: 0) {
                    if let report = vm.report { completionBanner(report: report); Divider() }
                    resultsList
                }
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("No tests match \"\(vm.searchText)\"").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections, id: \.key) { sectionName, tests in
                        Section(sectionName) {
                            ForEach(tests) { test in
                                Toggle(isOn: Binding(
                                    get: { vm.selectedTestNames.contains(test.name) },
                                    set: { on in
                                        if on { vm.selectedTestNames.insert(test.name) }
                                        else  { vm.selectedTestNames.remove(test.name) }
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        if let id = test.testID {
                                            Text(id)
                                                .font(.system(.caption2, design: .monospaced))
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        }
                                        Text(test.name).font(.body)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack(spacing: 12) {
                    Button(allSelected ? "Deselect All" : "Select All") { vm.toggleAllFiltered() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)

                    Spacer()

                    Text("\(filtered.count) match\(filtered.count == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)

                    if !vm.selectedTestNames.isEmpty {
                        Button {
                            showFailuresOnly = false
                            vm.runSelectedTests()
                        } label: {
                            Label("Run selected (\(vm.selectedTestNames.count))", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                    }

                    Button {
                        showFailuresOnly = false
                        vm.runAllMatches()
                    } label: {
                        Label("Run all (\(filtered.count))", systemImage: "forward.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let msg = vm.failureMessage {
            errorView(msg)
        } else if vm.liveResults.isEmpty && !vm.isRunning {
            emptyState
        } else {
            VStack(spacing: 0) {
                if let report = vm.report {
                    completionBanner(report: report)
                    Divider()
                }
                resultsList
            }
        }
    }

    private func completionBanner(report: RunReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: report.failed == 0 ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(report.failed == 0 ? .green : .red)
            Text(report.failed == 0
                 ? "All \(report.passed) tests passed"
                 : "\(report.failed) failed · \(report.passed) passed")
                .fontWeight(.medium)
            Spacer()
            if report.failed > 0 {
                Button {
                    copyToClipboard(failuresMarkdown(results: report.results,
                                                    environment: report.environment))
                } label: {
                    Label("Copy failures", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Text("Run complete")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(report.failed == 0 ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Select a suite and press Run")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("⌘R")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") { vm.start() }
                .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        let visibleResults = showFailuresOnly
            ? vm.liveResults.filter { $0.status == .failed || $0.status == .knownFailure || $0.status == .unexpectedPass }
            : vm.liveResults
        let sections = Dictionary(grouping: visibleResults, by: \.section)
            .sorted { $0.key < $1.key }

        return ScrollViewReader { proxy in
            List {
                ForEach(sections, id: \.key) { sectionName, results in
                    Section(sectionName) {
                        ForEach(results, id: \.name) { result in
                            TestResultRow(result: result, environment: vm.report?.environment)
                                .id(result.name)
                        }
                    }
                }
                if vm.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .id("__running__")
                }
            }
            .listStyle(.inset)
            .onChange(of: vm.liveResults.count) {
                withAnimation {
                    proxy.scrollTo(vm.isRunning ? "__running__" : vm.liveResults.last?.name)
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 20) {
            let passed  = vm.liveResults.filter { $0.status == .passed }.count
            let failed  = vm.liveResults.filter { $0.status == .failed }.count
            let skipped = vm.liveResults.filter { $0.status == .skipped }.count
            let known   = vm.liveResults.filter { $0.status == .knownFailure }.count

            if !vm.liveResults.isEmpty {
                statusChip(count: passed,  icon: "checkmark.circle.fill", color: .green,  label: "passed")
                statusChip(count: failed,  icon: "xmark.circle.fill",     color: .red,    label: "failed")
                if skipped > 0 {
                    statusChip(count: skipped, icon: "forward.fill",       color: .gray,   label: "skipped")
                }
                if known > 0 {
                    statusChip(count: known,   icon: "exclamationmark.triangle.fill", color: .orange, label: "known")
                }
            }

            Spacer()

            if vm.isRunning {
                ElapsedLabel(startDate: vm.startDate)
            } else if let report = vm.report {
                let total = report.results.map { Double($0.durationMs) / 1000 }.reduce(0, +)
                Text(String(format: "%.1fs", total))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func statusChip(count: Int, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(count > 0 ? color : .secondary)
            Text("\(count) \(label)")
                .foregroundStyle(count > 0 ? .primary : .secondary)
        }
        .font(.system(.caption, design: .monospaced))
    }
}

// MARK: - Subviews

private struct TestResultRow: View {
    let result: TestResult
    var environment: RunEnvironment? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(statusIcon)
                .font(.system(size: 14))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let id = result.id {
                        Text(id)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(result.name)
                        .font(.system(.body))
                }
                if let reason = result.failureReason, result.status == .failed {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
            Spacer()
            Text(String(format: "%.2fs", Double(result.durationMs) / 1000))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                copyToClipboard(resultMarkdown(result, environment: environment))
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.clipboard")
            }
            if result.status == .failed {
                Button {
                    copyToClipboard(resultMarkdown(result, environment: environment))
                } label: {
                    Label("Copy failure details", systemImage: "exclamationmark.bubble")
                }
            }
            if let repro = result.reproCommand {
                Divider()
                Button {
                    copyToClipboard(repro)
                } label: {
                    Label("Copy repro command", systemImage: "terminal")
                }
            }
        }
    }

    private var statusIcon: String {
        switch result.status {
        case .passed:        "✅"
        case .failed:        "❌"
        case .skipped:       "⏭"
        case .knownFailure:  "⚠️"
        case .unexpectedPass: "🎉"
        }
    }
}

private struct ElapsedLabel: View {
    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let elapsed = startDate.map { context.date.timeIntervalSince($0) } ?? 0
            Text(String(format: "%.1fs", elapsed))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Suite picker with count badges

private struct SuiteSegmentedPicker: View {
    @Binding var selection: RunTestsViewModel.Suite
    let counts: [RunTestsViewModel.Suite: Int]
    let disabled: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(RunTestsViewModel.Suite.allCases) { suite in
                    suiteTab(suite)
                }
            }
            .padding(2)
            .background(Color(NSColor.controlColor), in: RoundedRectangle(cornerRadius: 7))
        }
        .allowsHitTesting(!disabled)
        .opacity(disabled ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.12), value: selection)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func suiteTab(_ suite: RunTestsViewModel.Suite) -> some View {
        let selected = selection == suite
        return Button { selection = suite } label: {
            HStack(spacing: 5) {
                Text(suite.rawValue)
                    .font(.system(.callout))
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)

                if let count = counts[suite] {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .background(
                            selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())          // full area is clickable
            .background(
                selected
                    ? AnyView(RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.10), radius: 1.5, x: 0, y: 1))
                    : AnyView(Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
