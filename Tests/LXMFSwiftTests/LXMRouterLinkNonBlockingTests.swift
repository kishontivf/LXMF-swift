// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterLinkNonBlockingTests.swift
//  LXMFSwiftTests
//
//  Fork deviation: a DIRECT send never waits inline for a link handshake. An unanswered link
//  reports `.linkPending` at once, and a failed handshake is reported on the next attempt.
//

import XCTest
import ReticulumSwift
@testable import LXMFSwift

final class LXMRouterLinkNonBlockingTests: XCTestCase {

    /// Router + transport with a route to a recipient that will never answer a link request.
    private func makeSilentPeer() async throws -> (LXMRouter, Data) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-nonblocking-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        let router = try await LXMRouter(identity: Identity(), databasePath: dbPath)

        let transport = ReticulumTransport()
        try await transport.addInterface(SilentInterface(id: "silent"))
        await router.setTransport(transport)

        let recipient = Identity()
        let destHash = Destination.hash(identity: recipient, appName: "lxmf", aspects: ["delivery"])
        await transport.getPathTable().record(entry: PathEntry(destinationHash: destHash,
                                                               publicKeys: recipient.publicKeys,
                                                               interfaceId: "silent",
                                                               hopCount: 1,
                                                               expiration: 86400,
                                                               randomBlob: Data(repeating: 0x5A, count: 10),
                                                               nextHop: nil))
        return (router, destHash)
    }

    private func directMessage(to destHash: Data) throws -> LXMessage {
        var message = LXMessage(destinationHash: destHash, sourceIdentity: Identity(),
                                content: Data("hi".utf8), title: Data(), fields: nil, desiredMethod: .direct)
        _ = try message.pack()
        return message
    }

    private func sendDirectError(_ router: LXMRouter, to destHash: Data) async throws -> LXMFError? {
        var message = try directMessage(to: destHash)
        do {
            try await router.sendDirect(&message)
            return nil
        } catch let error as LXMFError {
            return error
        }
    }

    func testUnansweredLinkReportsPendingWithoutWaiting() async throws {
        let (router, destHash) = try await makeSilentPeer()
        let started = ContinuousClock.now

        let first = try await sendDirectError(router, to: destHash)
        let firstLink = await router.deliveryLinks[destHash]
        let second = try await sendDirectError(router, to: destHash)

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "must not wait for the handshake")
        guard case .linkPending = first, case .linkPending = second else {
            return XCTFail("expected .linkPending twice, got \(String(describing: first)) / \(String(describing: second))")
        }
        let secondLink = await router.deliveryLinks[destHash]
        XCTAssertNotNil(firstLink)
        XCTAssertTrue(firstLink === secondLink, "a handshake in flight is reused, not re-dialled")
    }

    func testFailedHandshakeIsReportedOnTheNextAttempt() async throws {
        let (router, destHash) = try await makeSilentPeer()
        _ = try await sendDirectError(router, to: destHash)
        let cachedLink = await router.deliveryLinks[destHash]
        let pendingLink = try XCTUnwrap(cachedLink)

        await pendingLink.close(reason: .timeout)
        for _ in 0..<30 {
            guard await router.deliveryLinks[destHash] != nil else { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        let afterFailure = try await sendDirectError(router, to: destHash)
        guard case .linkFailed = afterFailure else {
            return XCTFail("the failed handshake must bill the next attempt, got \(String(describing: afterFailure))")
        }
        let redial = try await sendDirectError(router, to: destHash)
        guard case .linkPending = redial else {
            return XCTFail("the attempt after that dials again, got \(String(describing: redial))")
        }
    }
}

/// Swallows everything it is asked to send, so a link request is never answered.
private actor SilentInterface: NetworkInterface {
    let id: String
    let config: InterfaceConfig
    nonisolated var state: InterfaceState { .connected }

    init(id: String) {
        self.id = id
        self.config = InterfaceConfig(id: id, name: id, type: .tcp, enabled: true, mode: .full,
                                      host: "127.0.0.1", port: 0)
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws {}
    func setDelegate(_ delegate: any InterfaceDelegate) async {}
}
