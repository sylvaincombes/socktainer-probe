import Foundation

// MARK: - Harness helpers

public func ensureAlive(sock: DockerCLI) async {
    if listMode || collectMode { return }
    guard (try? await sock.ping()) != true else { return }
    print("  🔄 Socktainer crashed — restarting")
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if (try? await sock.ping()) == true { return }
    }
}

// MARK: - Sequential orchestrator (default)

/// Runs all integration tests sequentially — each section completes before the next starts.
public func runIntegrationTests(sock: DockerCLI, ref: DockerCLI, environment: RunEnvironment) async {
    resetResults()
    markRunStart()
    await runContainerSection(sock: sock)
    await runLogsSection(sock: sock)
    await runWaitSection(sock: sock)
    await runExecSection(sock: sock)
    await runArchiveSection(sock: sock)
    await runImageSection(sock: sock)
    await runPruneSection(sock: sock)
    await runEventsSection(sock: sock, ref: ref)
    await runEventParitySection(sock: sock, ref: ref)
    await runLabelSection(sock: sock)
    await runHealthcheckSection(sock: sock)
    await runStatsSection(sock: sock)
    await runVolumeSection(sock: sock)
    await runNetworkSection(sock: sock)
    await runContextSection(sock: sock)
    await runMemorySection(sock: sock)
    await runSystemSection(sock: sock)
    await runDnsSection(sock: sock)
    await runAttachWSSection(sock: sock, ref: ref)
    await runComposeSection(sock: sock)
    await runDevcontainerSection(sock: sock)
    await runTestcontainerSection(sock: sock)
    await runSupabaseSection(sock: sock)
}

// MARK: - Parallel orchestrator (--parallel)

/// Runs independent sections concurrently in waves for faster wall-clock time.
///
/// Parallel strategy:
/// - Wave 1 (parallel): lightweight sections — no container creation, no VMs spun up.
///   These complete quickly and don't stress the daemon.
/// - Waves 2-6 (sequential): container-heavy sections — Apple Container serialises
///   concurrent VM creation internally, so running them in parallel causes contention
///   and flaky failures. Sequential is both reliable and nearly as fast.
public func runIntegrationTestsParallel(sock: DockerCLI, ref: DockerCLI, environment: RunEnvironment) async {
    resetResults()
    markRunStart()
    print("\n⚡ Running in parallel mode")

    // Wave 1 — parallel: lightweight, no container/VM creation
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await runContextSection(sock: sock) }
        group.addTask { await runSystemSection(sock: sock) }
        group.addTask { await runLabelSection(sock: sock) }
        group.addTask { await runStatsSection(sock: sock) }
    }

    // Waves 2+ — sequential: heavy container/compose operations
    await runContainerSection(sock: sock)
    await runLogsSection(sock: sock)
    await runWaitSection(sock: sock)
    await runExecSection(sock: sock)
    await runArchiveSection(sock: sock)
    await runImageSection(sock: sock)
    await runPruneSection(sock: sock)
    await runVolumeSection(sock: sock)
    await runMemorySection(sock: sock)
    await runHealthcheckSection(sock: sock)
    await runEventsSection(sock: sock, ref: ref)
    await runEventParitySection(sock: sock, ref: ref)
    await runNetworkSection(sock: sock)
    await runDnsSection(sock: sock)
    await runAttachWSSection(sock: sock, ref: ref)
    await runComposeSection(sock: sock)
    await runDevcontainerSection(sock: sock)
    await runTestcontainerSection(sock: sock)
    await runSupabaseSection(sock: sock)
}
