// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterPathlessRetryTests.swift
//  LXMFSwiftTests
//
//  Pins the fix for messages being permanently discarded while a device is offline.
//
//  `MAX_DELIVERY_ATTEMPTS` counts transmissions. Before the fix, a message with no path
//  was billed an attempt for every pass in which sending was impossible, so it exhausted
//  all 8 attempts in ~151 seconds and was removed from the queue — while
//  `MAX_OUTBOUND_AGE` (24h) advertises that an offline device keeps its queue. The
//  2026-08-12 field test lost two messages this way 66s and 82s BEFORE connectivity
//  returned: the device recovered, the messages did not.
//
//  Reference: `LXMRouter.rescheduleWithoutPath(_:)`.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterPathlessRetryTests: XCTestCase {

    // MARK: - Helpers

    /// Router backed by a unique temp-file DB, with NO transport and NO path table — the
    /// in-process equivalent of a device that has lost every radio.
    private func makeOfflineRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-pathless-retry-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    /// Queue one small (opportunistic) message to a destination nothing can route to.
    private func enqueueUnroutableMessage(on router: LXMRouter) async throws -> Data {
        var message = LXMessage(
            destinationHash: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            sourceIdentity: Identity(),
            content: "offline".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .opportunistic
        )
        try await router.handleOutbound(&message)
        return message.hash
    }

    /// Drive `processOutbound` `count` times, defeating the `nextDeliveryAttempt` gate each
    /// pass so the accounting is exercised without waiting out real backoff.
    private func runPasses(_ count: Int, on router: LXMRouter) async {
        for _ in 0..<count {
            await router.forceAllDueForTest()
            await router.processOutbound()
        }
    }

    // MARK: - Tests

    /// The regression: far more passes than `MAX_DELIVERY_ATTEMPTS`, all with no path.
    /// The message must still be queued — being unable to send is not a failed delivery.
    func testPathlessMessageSurvivesFarMorePassesThanMaxDeliveryAttempts() async throws {
        let router = try await makeOfflineRouter()
        let hash = try await enqueueUnroutableMessage(on: router)

        await runPasses(LXMRouter.MAX_DELIVERY_ATTEMPTS * 3, on: router)

        let stillQueued = await router.pendingOutbound.contains { $0.hash == hash }
        XCTAssertTrue(stillQueued,
                      "A message with no path was discarded after \(LXMRouter.MAX_DELIVERY_ATTEMPTS * 3) "
                      + "pathless passes. It must survive until MAX_OUTBOUND_AGE so it can be sent "
                      + "when connectivity returns.")
    }

    /// The mechanism behind the fix: a pass that could not transmit must not bill an attempt,
    /// so the retry budget is still intact for real sends once a path exists.
    func testPathlessPassesDoNotConsumeTheDeliveryBudget() async throws {
        let router = try await makeOfflineRouter()
        let hash = try await enqueueUnroutableMessage(on: router)

        await runPasses(LXMRouter.MAX_DELIVERY_ATTEMPTS * 3, on: router)

        let attempts = await router.pendingOutbound.first { $0.hash == hash }?.deliveryAttempts
        XCTAssertEqual(attempts, 0,
                       "Pathless passes consumed the delivery budget (attempts=\(attempts as Any)). "
                       + "MAX_DELIVERY_ATTEMPTS counts transmissions; nothing reached the wire here.")
    }

    /// The curve itself: doubling from `RETRY_BACKOFF_BASE`, flat at `RETRY_BACKOFF_CAP`.
    /// Most interruptions are brief, so the first retry has to be fast; a peer that is genuinely
    /// gone has to become cheap quickly. Doubling is what satisfies both.
    func testRetryBackoffDoublesAndCaps() {
        XCTAssertEqual(LXMRouter.retryBackoff(step: 0), 2)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 1), 4)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 2), 8)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 3), 16)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 4), 32)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 7), 256)
        XCTAssertEqual(LXMRouter.retryBackoff(step: 8), LXMRouter.RETRY_BACKOFF_CAP)
        // Must not overflow or wrap for an absurd step count.
        XCTAssertEqual(LXMRouter.retryBackoff(step: 10_000), LXMRouter.RETRY_BACKOFF_CAP)
        XCTAssertEqual(LXMRouter.retryBackoff(step: -1), LXMRouter.RETRY_BACKOFF_BASE)
    }

    /// Successive pathless passes must actually climb the curve, not repeat the first delay.
    func testSuccessivePathlessPassesBackOffFurtherEachTime() async throws {
        let router = try await makeOfflineRouter()
        let hash = try await enqueueUnroutableMessage(on: router)

        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            await router.forceAllDueForTest()
            await router.processOutbound()
            let next = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
            delays.append(try XCTUnwrap(next).timeIntervalSinceNow)
        }

        for (earlier, later) in zip(delays, delays.dropFirst()) {
            XCTAssertGreaterThan(later, earlier,
                                 "Each pathless retry must wait longer than the last; got \(delays)")
        }
    }

    /// The backoff must stay bounded rather than pinning the 1s loop to a send-storm, and must
    /// keep the message due again — a coverage gap should recover promptly, not stall for hours.
    func testPathlessRetryIsScheduledAndBounded() async throws {
        let router = try await makeOfflineRouter()
        let hash = try await enqueueUnroutableMessage(on: router)

        await runPasses(1, on: router)

        let next = await router.pendingOutbound.first { $0.hash == hash }?.nextDeliveryAttempt
        let retry = try XCTUnwrap(next, "A pathless message must be rescheduled, not left ungated")
        let delay = retry.timeIntervalSinceNow
        XCTAssertGreaterThan(delay, 0, "Retry must be in the future so the 1s loop can't storm")
        XCTAssertLessThanOrEqual(delay, 300, "Retry backoff must stay capped at 5 minutes")
    }
}

// MARK: - Test hooks
extension LXMRouter {
    /// Make every queued message due immediately, so a test can exercise many delivery passes
    /// without waiting out real backoff. Test-only: `pendingOutbound` is `internal`, and this
    /// keeps the mutation inside the actor rather than handing tests a way to race it.
    func forceAllDueForTest() {
        for i in pendingOutbound.indices {
            pendingOutbound[i].nextDeliveryAttempt = Date.distantPast
        }
    }
}
