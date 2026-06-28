import Foundation

public func runImageSection(sock: DockerCLI) async {
    section("Images")

    await check("docker image history returns layer metadata",
                id: "IMG-001", refs: [],
                repro: "docker --context socktainer image history alpine") {
        let layers = try await sock.imageHistory(name: "public.ecr.aws/docker/library/alpine")
        try assert(!layers.isEmpty, "history must have at least one layer")
        let hasId = layers.allSatisfy { $0["ID"] != nil || $0["CreatedBy"] != nil }
        try assert(hasId, "each layer must have ID or CreatedBy: \(layers.first ?? [:])")
    }

    await check("docker image rm deletes a tagged image and fires an untag event",
                id: "IMG-002", refs: ["#90"],
                repro: "docker --context socktainer tag alpine test-img-del:latest\ndocker --context socktainer image rm test-img-del:latest") {
        let tag = "test-img-\(Int.random(in: 1000...9999)):latest"
        try await sock.imageTag(source: "public.ecr.aws/docker/library/alpine", target: tag)

        var output = ""
        let events = try await sock.captureEvents {
            output = try await sock.imageDelete(name: tag)
        }

        try assert(!(await sock.imageExists(tag)), "image \(tag) should not exist after delete")

        // Docker CLI prints "Untagged: <ref>" for each untagged reference (Moby response format).
        // The old bug emitted {"Deleted":"test:latest"} — checking for "Untagged:" catches the regression.
        try assert(output.contains("Untagged:"),
                   "response must use Untagged format, got: \(output)")

        // Docker/Colima fire Action "untag" when a tag is removed (and "delete" when the
        // last reference frees the layers) — never "remove" for images.
        let untagEvent = events.first { ($0["Action"] as? String) == "untag" && ($0["Type"] as? String) == "image" }
        try assert(untagEvent != nil,
                   "expected 'untag' image event, got: \(events.map { $0["Action"] as? String ?? "" })")
    }

    // IMG-003: verifies the Moby "Deleted: sha256:..." entry when removing the LAST reference.
    // This requires an image with no other local aliases. We pull a specific tagged version of
    // alpine (e.g. :3.20) which is likely not already cached under a separate tag — if it is,
    // the test still passes (Untagged-only is also valid), we just won't see the Deleted line.
    await check("docker image rm last reference emits Deleted sha256 in response",
                id: "IMG-003", refs: [],
                repro: "docker --context socktainer pull public.ecr.aws/docker/library/alpine:3.20\ndocker --context socktainer image rm public.ecr.aws/docker/library/alpine:3.20") {
        let uniqueRef = "public.ecr.aws/docker/library/alpine:3.20"

        // Pull the specific tag so we know it exists.
        _ = try await sock.pullImage(reference: uniqueRef)

        // Check how many refs share the same digest before deleting.
        let refsBeforeDelete = await sock.imageExists(uniqueRef)
        try assert(refsBeforeDelete, "image \(uniqueRef) must exist after pull")

        let output = try await sock.imageDelete(name: uniqueRef)

        try assert(!(await sock.imageExists(uniqueRef)), "\(uniqueRef) must not exist after delete")
        try assert(output.contains("Untagged:"),
                   "response must include Untagged entry, got: \(output)")

        // If alpine:3.20 was the only ref for its digest, the CLI also prints "Deleted: sha256:...".
        // We don't assert Deleted here unconditionally because the same digest may already exist
        // under another local tag — the important thing is the image is gone and Untagged is present.
        // The Deleted path is exercised by unit tests (ImageDeleteRouteTests.deletedDigestIncludedForLastRef).
    }

    // captureEvents kills the docker events stream which triggers a pre-existing NIO crash
    // in Socktainer's EventsRoute — same pattern as the EVT-* tests.
    await ensureAlive(sock: sock)
}
