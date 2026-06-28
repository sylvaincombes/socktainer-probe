import Foundation

public func runVolumeSection(sock: DockerCLI) async {
    section("Volume sync mode")
    await check("default volume (nosync) — data persists across containers",
                id: "VOL-001", refs: ["#216"],
                repro: "docker --context socktainer volume create sync-vol\ndocker --context socktainer run -d -v sync-vol:/data alpine sh -c 'echo synced > /data/test.txt'\ndocker --context socktainer run -d -v sync-vol:/data alpine cat /data/test.txt") {
        let volName = "check-sync-\(Int.random(in: 1000...9999))"
        let readerName = "check-reader-\(Int.random(in: 1000...9999))"
        try await sock.volumeCreate(name: volName)
        defer { Task { try? await sock.volumeRemove(name: volName) } }
        let writerName = try await sock.runContainer(image: "public.ecr.aws/docker/library/alpine", volumes: ["\(volName):/data"], rm: false, detach: true, cmd: ["sh", "-c", "echo synced > /data/test.txt"])
        try await sock.wait(name: writerName)
        try await sock.remove(name: writerName)
        _ = try await sock.runContainer(name: readerName, image: "public.ecr.aws/docker/library/alpine", volumes: ["\(volName):/data"], rm: false, detach: true, cmd: ["cat", "/data/test.txt"])
        try await sock.wait(name: readerName)
        let output = try await sock.logs(name: readerName)
        try await sock.remove(name: readerName)
        try assertContains(output, "synced")
    }
    await check("per-volume sync=fsync label is stored and readable",
                id: "VOL-002", refs: ["#216"],
                repro: "docker --context socktainer volume create -o sync=fsync fsync-vol\ndocker --context socktainer volume inspect fsync-vol --format '{{index .Labels \"socktainer.volume.sync\"}}'") {
        let name = "check-fsync-\(Int.random(in: 1000...9999))"
        try await sock.volumeCreate(name: name, options: ["sync": "fsync"])
        defer { Task { try? await sock.volumeRemove(name: name) } }
        let labels = try await sock.volumeInspectLabels(name: name)
        try assertEqual(labels["socktainer.volume.sync"], "fsync", "sync label stored")
    }

    await check("all sync modes (nosync / fsync / full) store the correct label",
                id: "VOL-003", refs: ["#216"],
                repro: "docker --context socktainer volume create -o sync=nosync v1\ndocker --context socktainer volume create -o sync=full v2") {
        for mode in ["nosync", "full"] {
            let name = "check-sync-\(mode)-\(Int.random(in: 1000...9999))"
            try await sock.volumeCreate(name: name, options: ["sync": mode])
            defer { Task { try? await sock.volumeRemove(name: name) } }
            let labels = try await sock.volumeInspectLabels(name: name)
            try assertEqual(labels["socktainer.volume.sync"], mode, "sync=\(mode) label")
        }
    }

    await check("volume create is idempotent — re-creating an existing volume succeeds",
                id: "VOL-004", refs: [],
                repro: "docker --context socktainer volume create my-vol\ndocker --context socktainer volume create my-vol") {
        let name = "check-idem-\(Int.random(in: 1000...9999))"
        try await sock.volumeCreate(name: name, labels: ["marker": "first"])
        defer { Task { try? await sock.volumeRemove(name: name) } }

        // Second create with same name must not throw.
        try await sock.volumeCreate(name: name, labels: ["marker": "second"])

        // Original volume is returned unchanged (idempotent).
        let labels = try await sock.volumeInspectLabels(name: name)
        try assertEqual(labels["marker"], "first", "idempotent create must return existing volume")
    }

    // Pin postgres:16-alpine: small and uses the classic PGDATA=/var/lib/postgresql/data
    // layout. NOTE: postgres:latest is now 18+, which moved data to major-version-specific
    // dirs and refuses this mount path entirely. Only run when the image is already cached:
    // an uncached `docker run` blocks on the pull (the "stuck indefinitely" symptom) — and a
    // hung socktainer pull would block the whole suite. Pre-pull to run this test.
    let pgImage = "public.ecr.aws/docker/library/postgres:16-alpine"
    let pgCached = listMode ? true : await sock.imageExists(pgImage)
    if pgCached {
        await check(
            "Postgres initdb succeeds on a fresh named volume (lost+found removed)",
            id: "VOL-005",
            refs: ["#222"],
            repro: """
                docker --context socktainer volume create pgdata
                docker --context socktainer run --rm \\
                  -e POSTGRES_PASSWORD=x \\
                  -v pgdata:/var/lib/postgresql/data \\
                  postgres:16-alpine
                # Without the fix: initdb aborts — "directory is not empty ... lost+found"
                """
        ) {
            let volName = "check-pg-\(Int.random(in: 10000...99999))"
            let ctrName = "check-pg-ctr-\(Int.random(in: 10000...99999))"

            // Cleanup must be AWAITED, not fire-and-forget `defer { Task {...} }`: postgres holds
            // the synced volume and is slow to stop, so a detached removal lets the next test's
            // daemon call race a still-removing container and hang.
            // Remove the container before the volume — a volume in use can't be removed.
            func cleanup() async {
                try? await sock.remove(name: ctrName)
                try? await sock.volumeRemove(name: volName)
            }

            do {
                try await sock.volumeCreate(name: volName)

                _ = try await sock.runContainer(
                    name: ctrName,
                    image: pgImage,
                    env: ["POSTGRES_PASSWORD": "testpass"],
                    volumes: ["\(volName):/var/lib/postgresql/data"],
                    rm: false,
                    detach: true
                )

                // Give Postgres time to run initdb and start (or fail fast on lost+found).
                try await Task.sleep(nanoseconds: 10_000_000_000)

                let output = try await sock.logs(name: ctrName)

                // The fatal lost+found error:
                try assert(
                    !output.contains("not empty"),
                    "initdb aborted: data directory is not empty (lost+found present) — \(output.prefix(300))"
                )
                // Positive confirmation that init completed:
                try assert(
                    output.contains("database system is ready to accept connections"),
                    "Postgres did not reach ready state — \(output.prefix(300))"
                )
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    } else {
        skip("Postgres initdb succeeds on a fresh named volume (lost+found removed)",
             id: "VOL-005",
             reason: "postgres:16-alpine not cached — `docker pull \(pgImage)` first to run this test")
    }

    await check("docker volume ls lists created volumes",
                id: "VOL-006",
                repro: "docker --context socktainer volume create test-vol && docker --context socktainer volume ls") {
        let volName = "check-list-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: volName)
        defer { Task { try? await sock.volumeRemove(name: volName) } }
        let names = try await sock.volumeListNames()
        try assert(names.contains(volName), "volume '\(volName)' should appear in volume ls output")
    }

    await check("docker volume prune removes unused volumes",
                id: "VOL-007",
                repro: "docker --context socktainer volume create prune-me && docker --context socktainer volume prune --force") {
        let volName = "check-prune-vol-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: volName, labels: ["socktainer-probe-test": "prune"])
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await sock.volumePrune(force: true)
        let names = try await sock.volumeListNames()
        try assert(!names.contains(volName), "volume '\(volName)' should have been pruned")
    }

    // PUT /volumes/{name} — VolumeUpdate (cluster/CSI volume spec update).
    // Returns 404 on Socktainer 1.0.0 — route is not registered (not just "volume not found").
    // This is expected: PUT /volumes/{name} is primarily a Docker Swarm/CSI endpoint.
    // ── Filtering (PR #58 — DockerFilterUtility) ─────────────────────────────

    await check("docker volume ls --filter 'label=key' lists only labelled volumes",
                id: "VOL-009", refs: ["#58"],
                repro: "docker --context socktainer volume create --label probe=yes v1\ndocker --context socktainer volume ls --filter 'label=probe'") {
        let tagged   = "check-filt-yes-\(Int.random(in: 10000...99999))"
        let untagged = "check-filt-no-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: tagged,   labels: ["socktainer-probe-filter": "yes"])
        try await sock.volumeCreate(name: untagged)
        defer {
            Task { try? await sock.volumeRemove(name: tagged) }
            Task { try? await sock.volumeRemove(name: untagged) }
        }
        let filtered = try await sock.volumeListNames(filters: ["label": "socktainer-probe-filter"])
        try assert(filtered.contains(tagged),    "labelled volume '\(tagged)' should appear in filtered list")
        try assert(!filtered.contains(untagged), "untagged volume '\(untagged)' should not appear in filtered list")
    }

    await check("docker volume ls --filter 'label=key=val' filters by label value",
                id: "VOL-010", refs: ["#58"],
                repro: "docker --context socktainer volume create --label env=prod v1\ndocker --context socktainer volume create --label env=dev v2\ndocker --context socktainer volume ls --filter 'label=env=prod'") {
        let prod = "check-filt-prod-\(Int.random(in: 10000...99999))"
        let dev  = "check-filt-dev-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: prod, labels: ["socktainer-probe-env": "prod"])
        try await sock.volumeCreate(name: dev,  labels: ["socktainer-probe-env": "dev"])
        defer {
            Task { try? await sock.volumeRemove(name: prod) }
            Task { try? await sock.volumeRemove(name: dev) }
        }
        let prodOnly = try await sock.volumeListNames(filters: ["label": "socktainer-probe-env=prod"])
        try assert(prodOnly.contains(prod), "prod volume should appear with 'env=prod' filter")
        try assert(!prodOnly.contains(dev), "dev volume should not appear with 'env=prod' filter")
    }

    await check("docker volume prune --filter 'label=key=val' prunes only matching volumes",
                id: "VOL-011", refs: ["#58"],
                repro: "docker --context socktainer volume create --label prune-me=yes v1\ndocker --context socktainer volume prune --filter 'label=prune-me=yes' --force") {
        let toDelete = "check-prune-match-\(Int.random(in: 10000...99999))"
        let toKeep   = "check-prune-keep-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: toDelete, labels: ["socktainer-probe-prune": "yes"])
        try await sock.volumeCreate(name: toKeep,   labels: ["socktainer-probe-prune": "no"])
        defer { Task { try? await sock.volumeRemove(name: toKeep) } }
        _ = try await sock.volumePrune(force: true, filters: ["label": "socktainer-probe-prune=yes"])
        let after = try await sock.volumeListNames()
        try assert(!after.contains(toDelete), "volume with 'prune=yes' should have been pruned")
        try assert(after.contains(toKeep),    "volume with 'prune=no' should have survived filter prune")
    }

    // PUT /volumes/{name} = VolumeUpdate: "Valid only for Swarm cluster volumes" (Docker docs).
    // Out of scope for Apple Container / Socktainer — same category as Swarm endpoints.
    await xfail("PUT /volumes/{name} (VolumeUpdate — Swarm cluster volumes only)",
                id: "VOL-008",
                reason: "Swarm-only: VolumeUpdate is valid only for Docker Swarm cluster volumes (CSI) — not applicable for Apple Container",
                repro: "curl --unix-socket ~/.socktainer/container.sock -X PUT -H 'Content-Type: application/json' -d '{\"Spec\":{}}' http://localhost/v1.51/volumes/{name}") {
        let volName = "check-put-vol-\(Int.random(in: 10000...99999))"
        try await sock.volumeCreate(name: volName)
        defer { Task { try? await sock.volumeRemove(name: volName) } }

        let socketPath = "\(NSHomeDirectory())/.socktainer/container.sock"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-s", "-w", "\n%{http_code}",
            "--unix-socket", socketPath,
            "-X", "PUT",
            "-H", "Content-Type: application/json",
            "-d", #"{"Spec":{},"Version":{"Index":0}}"#,
            "http://localhost/v1.51/volumes/\(volName)",
        ]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        let raw   = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        let body  = lines.dropLast().joined(separator: "\n")
        let code  = lines.last ?? ""

        // 501 → confirmed stub
        try assert(code != "501",
                   "PUT /volumes/{name} returned 501 — route registered but not implemented (stub)")
        // Empty body → silent stub
        try assert(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "PUT /volumes/{name} returned empty body (HTTP \(code)) — likely a silent stub")
        // 404 for unknown volume name would be a bug since we just created it
        try assert(code != "404",
                   "PUT /volumes/{name} returned 404 for an existing volume '\(volName)'")
        // 400 "not a cluster volume" is the expected correct response for a non-CSI volume
        // That means the endpoint exists and is working correctly
    }
}
