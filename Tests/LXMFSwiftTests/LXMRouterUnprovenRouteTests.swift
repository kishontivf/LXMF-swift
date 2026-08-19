// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterUnprovenRouteTests.swift
//  LXMFSwiftTests
//
//  Pins the handling of a route that accepts sends but never returns a delivery proof.
//
//  Field test 2026-08-12 (Session04): a peer that was merely out of BLE range still had a
//  stale 4-hop relay path in the table, so `hasPath` was true and every send "succeeded" at
//  the transport layer. No proof ever came back, the message burned all 8 attempts in 71-87s,
//  and was permanently discarded — 21 messages lost that way in one short walk, including a
//  message the tester sent specifically to check whether it would arrive. It did not.
//
//  Two behaviours are pinned here:
//    1. The attempt budget is NOT terminal — `MAX_OUTBOUND_AGE` is the only bound.
//    2. Exhausting the budget CLEARS the path, so a nearer carrier can win it back.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterUnprovenRouteTests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-unproven-route-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    /// A path entry that looks live — the stale-relay shape from the field: a real interface,
    /// several hops away, nowhere near expiry.
    private func makeStalePath(to destinationHash: Data) -> PathEntry {
        PathEntry(
            destinationHash: destinationHash,
            publicKeys: Data(repeating: 0x01, count: 64),
            interfaceId: "argonath.paydogs.hu",
            hopCount: 4,
            expires: Date().addingTimeInterval(3600),
            randomBlob: Data(repeating: 0x02, count: 10)
        )
    }

    private func enqueueMessage(on router: LXMRouter, to destinationHash: Data) async throws -> Data {
        var message = LXMessage(
            destinationHash: destinationHash,
            sourceIdentity: Identity(),
            content: "unproven".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .opportunistic
        )
        try await router.handleOutbound(&message)
        return message.hash
    }

    /// Simulate a route that swallowed its whole budget without ever proving delivery, then run
    /// the pass that reacts to it.
    private func exhaustBudget(on router: LXMRouter, hash: Data) async {
        await router.setAttemptsForTest(hash: hash, attempts: LXMRouter.MAX_DELIVERY_ATTEMPTS)
        await router.forceAllDueForTest()
        await router.processOutbound()
    }

    // MARK: - Tests

    /// The regression: a spent attempt budget must not discard the message.
    func testExhaustedAttemptBudgetDoesNotDiscardTheMessage() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = try await enqueueMessage(on: router, to: destination)

        await exhaustBudget(on: router, hash: hash)

        let stillQueued = await router.pendingOutbound.contains { $0.hash == hash }
        XCTAssertTrue(stillQueued,
                      "Spending MAX_DELIVERY_ATTEMPTS discarded the message. Eight unproven sends "
                      + "means the route isn't delivering, not that the message is undeliverable — "
                      + "MAX_OUTBOUND_AGE is the only terminal bound.")
    }

    /// The budget resets and the entry returns to `.outbound`, so the next round genuinely
    /// re-sends rather than sitting at `.sent` awaiting a proof that will never arrive.
    func testExhaustedBudgetResetsForTheNextRoute() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = try await enqueueMessage(on: router, to: destination)

        await exhaustBudget(on: router, hash: hash)

        let entry = await router.pendingOutbound.first { $0.hash == hash }
        XCTAssertEqual(entry?.deliveryAttempts, 0, "Budget must reset for the replacement route")
        XCTAssertEqual(entry?.state, .outbound, "Entry must be re-sendable, not parked at .sent")
        let delay = try XCTUnwrap(entry?.nextDeliveryAttempt).timeIntervalSinceNow
        XCTAssertGreaterThan(delay, 0, "Must back off rather than retry immediately")
        XCTAssertLessThanOrEqual(delay, LXMRouter.UNPROVEN_ROUTE_RETRY_WAIT + 1,
                                 "Back-off must stay bounded so a peer returning to range is picked up")
    }

    /// Detecting a dead ROUTE must be fast, and is independent of how long the MESSAGE lives.
    /// Session05 measured 354s of replies fired into an `icWifi0` path belonging to a LAN the
    /// peer had already left, because invalidation waited for the whole attempt budget.
    func testDeadRouteIsClearedLongBeforeTheBudgetIsSpent() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let pathTable = try PathTable()
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        await router.setPathTableForTest(pathTable)

        let hash = try await enqueueMessage(on: router, to: destination)
        // One short of the demote threshold, so the next pass crosses it.
        await router.setAttemptsForTest(hash: hash, attempts: LXMRouter.PATH_DEMOTE_ATTEMPTS - 1)
        await router.forceAllDueForTest()
        await router.processOutbound()

        let stillHasPath = await pathTable.hasPath(for: destination)
        XCTAssertFalse(stillHasPath,
                       "The dead route survived PATH_DEMOTE_ATTEMPTS. Route invalidation must not "
                       + "wait for MAX_DELIVERY_ATTEMPTS — that took ~6 minutes in the field.")
        XCTAssertLessThan(LXMRouter.PATH_DEMOTE_ATTEMPTS, LXMRouter.MAX_DELIVERY_ATTEMPTS,
                          "Route verdict must come well before the message is given up on")
    }

    /// A parked message must be released the moment a usable path exists, rather than serving out
    /// `UNPROVEN_ROUTE_RETRY_WAIT` while a working route sits unused.
    func testParkedMessageIsReleasedAsSoonAsAPathReturns() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = try await enqueueMessage(on: router, to: destination)

        // Park it: budget spent, no path anywhere.
        await exhaustBudget(on: router, hash: hash)
        let parkedRetry = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
        let parkedDelay = try XCTUnwrap(parkedRetry).timeIntervalSinceNow
        XCTAssertGreaterThan(parkedDelay, 60, "precondition: the message is parked on a long timer")

        // The peer comes back into range: a path appears.
        let pathTable = try PathTable()
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        await router.setPathTableForTest(pathTable)
        await router.processOutbound()

        // Not asserted as ~0: releasing the message makes it due, so it is retried within the same
        // pass. That retry fails here (the harness has no transport) and earns the ordinary
        // RETRY_BACKOFF_BASE. What matters is that it is back on the normal retry curve rather
        // than serving out the park.
        let retryNow = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
        let delayNow = try XCTUnwrap(retryNow).timeIntervalSinceNow
        XCTAssertLessThan(delayNow, LXMRouter.UNPROVEN_ROUTE_RETRY_WAIT / 10,
                          "Parked message stayed on its timer after a path returned (delay "
                          + "\(Int(delayNow))s). The park exists to avoid hammering an unreachable "
                          + "peer; it must end when that stops being true.")
    }

    /// A message merely climbing the pathless backoff curve — never parked — must also be released
    /// when its destination becomes reachable. Session06 lost ~105s to exactly this case: the
    /// backoff had reached ~128s and was served out in full after connectivity had returned.
    func testBackedOffMessageIsReleasedWhenPathReturnsEvenIfNeverParked() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = try await enqueueMessage(on: router, to: destination)

        // Climb the pathless curve a few times, with no path anywhere. Never parked: the attempt
        // budget is never spent, because pathless passes don't bill it.
        for _ in 0..<5 {
            await router.forceAllDueForTest()
            await router.processOutbound()
        }
        let backedOff = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
        let backedOffDelay = try XCTUnwrap(backedOff).timeIntervalSinceNow
        XCTAssertGreaterThan(backedOffDelay, 8, "precondition: the curve has climbed")

        // The peer returns.
        let pathTable = try PathTable()
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        await router.setPathTableForTest(pathTable)
        await router.processOutbound()

        let afterRetry = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
        let afterDelay = try XCTUnwrap(afterRetry).timeIntervalSinceNow
        XCTAssertLessThan(afterDelay, backedOffDelay,
                          "A backed-off message must be released when a path returns, not serve out "
                          + "a delay accumulated during the outage")
    }

    /// Clearing the same destination's path repeatedly is churn: each clear also fires a path
    /// request, and a stale announce simply re-learns the route. Session06 did this 366 times.
    func testPathInvalidationIsRateLimitedPerDestination() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let pathTable = try PathTable()
        await router.setPathTableForTest(pathTable)

        // First invalidation clears; an immediate second must be suppressed by the cooldown.
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        let first = await router.invalidateUnprovenPathForTest(destination)
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        let second = await router.invalidateUnprovenPathForTest(destination)

        XCTAssertTrue(first, "the first invalidation must clear the dead route")
        XCTAssertFalse(second, "a second clear within the cooldown must be suppressed")
        let stillHasPath = await pathTable.hasPath(for: destination)
        XCTAssertTrue(stillHasPath, "the re-learned route must survive to be tried at least once")
    }

    /// The second half of the fix: the unproven path is removed, so a nearer carrier's announce
    /// can win the route instead of every retry going back into the same dead relay.
    func testExhaustedBudgetClearsTheUnprovenPath() async throws {
        let router = try await makeRouter()
        let destination = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let pathTable = try PathTable()
        _ = await pathTable.record(entry: makeStalePath(to: destination))
        let hadPathBefore = await pathTable.hasPath(for: destination)
        XCTAssertTrue(hadPathBefore, "precondition: the stale path is in the table")
        await router.setPathTableForTest(pathTable)

        let hash = try await enqueueMessage(on: router, to: destination)
        await exhaustBudget(on: router, hash: hash)

        let stillHasPath = await pathTable.hasPath(for: destination)
        XCTAssertFalse(stillHasPath,
                       "The unproven path survived. markPathUnresponsive alone was not enough in "
                       + "the field — a transport node re-announcing the dead relay simply "
                       + "re-asserted it, and every retry went back into the same hole.")
    }
}

// MARK: - Test hooks
extension LXMRouter {
    /// Force a queued message's attempt count, to reach the exhausted-budget branch without
    /// performing eight real sends. Kept inside the actor rather than exposing `pendingOutbound`
    /// mutation to tests.
    func setAttemptsForTest(hash: Data, attempts: Int) {
        guard let index = pendingOutbound.firstIndex(where: { $0.hash == hash }) else { return }
        pendingOutbound[index].deliveryAttempts = attempts
    }

    func setPathTableForTest(_ table: PathTable) {
        pathTable = table
    }

    /// Exercise the cooldown directly; driving it through `processOutbound` would need eight real
    /// sends per cycle and would not isolate the rate limit from the surrounding retry logic.
    func invalidateUnprovenPathForTest(_ destinationHash: Data) async -> Bool {
        await invalidateUnprovenPath(destinationHash)
    }
}
