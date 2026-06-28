import AppKit
import SocktainerProbeCore
import SwiftUI

struct SettingsView: View {
    var runIsActive: Bool = false
    @State private var vm = SettingsViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Detecting configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if runIsActive { runningBanner }
                        configForm
                        saveBar
                    }
                    .padding(32)
                }
                .disabled(runIsActive)
            }
        }
        .task { await vm.load() }
        .navigationTitle("Settings")
    }

    private var runningBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("A test run is in progress — settings are locked.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 20)
    }

    // MARK: - Form

    private var configForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            dockerSection
            socktainerSection
            referenceSection
            verifySection
        }
    }

    // MARK: - Docker

    private var dockerSection: some View {
        SettingsSection(title: "Docker CLI", icon: "shippingbox") {
            BinaryPicker(
                label: "Binary",
                value: $vm.dockerBinary,
                discovered: vm.discoveredDockerBinaries
            )
        }
    }

    // MARK: - Socktainer

    private var socktainerSection: some View {
        SettingsSection(title: "Socktainer", icon: "powerplug") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $vm.sourceMode) {
                    ForEach(SettingsViewModel.SourceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)

                switch vm.sourceMode {
                case .running:
                    Label("Tests run against the already-running Socktainer instance.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)

                case .binary:
                    VStack(alignment: .leading, spacing: 6) {
                        BinaryPicker(
                            label: "Binary path",
                            value: $vm.socktainerBinary,
                            discovered: vm.discoveredSocktainerBinaries
                        )
                        Text("The probe will stop any running Socktainer, start this binary, run tests, then stop it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                case .sourceFolder:
                    VStack(alignment: .leading, spacing: 10) {
                        FolderPicker(
                            label: "Source folder",
                            value: $vm.socktainerSourceFolder,
                            discovered: vm.discoveredSocktainerSources,
                            placeholder: "~/Projects/socktainer"
                        )
                        Toggle("Build with `make release` before each test session", isOn: $vm.buildBeforeStart)
                            .toggleStyle(.checkbox)
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar").foregroundStyle(.secondary)
                            Text("API coverage analysis uses this folder's source automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reference

    private var referenceSection: some View {
        SettingsSection(title: "Reference Runtime", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Used for parity comparisons (e.g. Colima, OrbStack, default)")
                    .font(.caption).foregroundStyle(.secondary)
                if vm.availableContexts.isEmpty {
                    TextField("Context name", text: $vm.referenceContext)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Context", selection: $vm.referenceContext) {
                        ForEach(vm.availableContexts, id: \.self) { ctx in
                            Text(ctx).tag(ctx)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    // MARK: - Verify

    private var verifySection: some View {
        SettingsSection(title: "Connection", icon: "antenna.radiowaves.left.and.right") {
            HStack(spacing: 16) {
                Button {
                    Task { await vm.verifyConnection() }
                } label: {
                    if case .verifying = vm.verifyStatus {
                        Label("Verifying…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Verify Connection", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(vm.verifyStatus == .verifying)

                Group {
                    switch vm.verifyStatus {
                    case .idle: EmptyView()
                    case .verifying: ProgressView().controlSize(.small)
                    case .ok(let docker, let socktainer, let apple):
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Docker CLI: \(docker)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                            Label("Socktainer: \(socktainer)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                            Label("Apple Container: \(apple)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                        }
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                .animation(.easeInOut, value: vm.verifyStatus)
            }
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack {
            Spacer()
            Group {
                switch vm.saveStatus {
                case .idle: EmptyView()
                case .saved:
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).transition(.opacity)
                case .error(let msg):
                    Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .animation(.easeInOut, value: vm.saveStatus)

            Button("Save") { vm.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 24)
    }
}

// MARK: - Reusable components

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            Divider()
            content().padding(.leading, 4)
        }
    }
}

private struct BinaryPicker: View {
    let label: String
    @Binding var value: String
    let discovered: [DiscoveredBinary]
    @State private var isCustom: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !discovered.isEmpty {
                Picker(label, selection: $value) {
                    ForEach(discovered, id: \.path) { bin in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bin.path).font(.system(.body, design: .monospaced))
                            Text(bin.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(bin.path)
                    }
                    Divider()
                    Text("Custom path…").tag("__custom__")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 400)
                .onChange(of: value) { _, new in
                    isCustom = (new == "__custom__")
                    if isCustom { value = "" }
                }
            }
            if discovered.isEmpty || isCustom || !discovered.map(\.path).contains(value) {
                HStack {
                    TextField("Path to binary", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…") { browseForFile() }
                }
            }
        }
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Select binary"
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}

private struct FolderPicker: View {
    let label: String
    @Binding var value: String
    let discovered: [DiscoveredBinary]
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !discovered.isEmpty {
                Picker(label, selection: $value) {
                    ForEach(discovered, id: \.path) { src in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.path).font(.system(.body, design: .monospaced))
                            Text(src.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(src.path)
                    }
                    Divider()
                    Text("Custom path…").tag("__custom__")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 400)
                .onChange(of: value) { _, new in if new == "__custom__" { value = "" } }
            }
            if discovered.isEmpty || !discovered.map(\.path).contains(value) {
                HStack {
                    TextField(placeholder, text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…") { browseForFolder() }
                }
            }
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Select Socktainer source folder"
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}
