import Foundation

/// Tests that simulate the Docker networking patterns used by Supabase's local stack.
///
/// Uses Docker Compose — exactly like `supabase start` does — and verifies that a
/// multi-service stack comes up cleanly, with services reaching each other by name
/// over the compose network (not via 127.0.0.1 loopback).
public func runSupabaseSection(sock: DockerCLI) async {
    section("Supabase multi-container patterns")

    // SUP-001 — Multi-service compose stack: app reaches db by service name
    //
    // This mirrors the exact failure mode Supabase's local stack hit: postgres,
    // kong, auth etc. must find each other by hostname (e.g. DB_HOST=db), NOT
    // via 127.0.0.1 which doesn't cross container boundaries. The compose network
    // provides the DNS; this test verifies it works end-to-end.
    await check(
        "supabase-style compose stack comes up and app reaches db by service name",
        id: "SUP-001",
        repro: """
            # Mirrors: supabase start (docker compose up)
            # db starts with a healthcheck; app waits for it, then connects by hostname.
            docker compose -f /tmp/supabase-probe/compose.yml run --rm app
            # must exit 0 — meaning the ping to $DB_HOST succeeded
            """
    ) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sck-sup-\(Int.random(in: 10000...99999))")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let composeFile = tmpDir.appendingPathComponent("compose.yml").path
        try """
            services:
              db:
                image: public.ecr.aws/docker/library/alpine
                command: sh -c 'touch /tmp/ready && sleep 60'
                healthcheck:
                  test: ["CMD", "test", "-f", "/tmp/ready"]
                  interval: 1s
                  timeout: 3s
                  retries: 10
              app:
                image: public.ecr.aws/docker/library/alpine
                environment:
                  DB_HOST: db
                command: sh -c 'ping -c1 $$DB_HOST && echo SUPABASE_STACK_OK'
                depends_on:
                  db:
                    condition: service_healthy
            """.write(toFile: composeFile, atomically: true, encoding: .utf8)

        // docker compose run starts db (waiting for healthy) then runs app.
        // If the inter-service ping fails, app exits non-zero → compose throws.
        let out: String
        do {
            out = try await sock.compose(file: composeFile, args: ["run", "--rm", "app"])
        } catch {
            // Always clean up before propagating.
            try? await sock.compose(file: composeFile, args: ["down", "--remove-orphans"])
            try? FileManager.default.removeItem(at: tmpDir)
            throw error
        }
        try? await sock.compose(file: composeFile, args: ["down", "--remove-orphans"])
        try? FileManager.default.removeItem(at: tmpDir)

        try assertContains(out, "SUPABASE_STACK_OK")
    }
}
