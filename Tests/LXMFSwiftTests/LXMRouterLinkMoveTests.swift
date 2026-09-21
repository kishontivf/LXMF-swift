// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterLinkMoveTests.swift
//  LXMFSwiftTests
//
//  `linkShouldMove` (fork deviation): a cached delivery link is replaced when the route moved
//  to another non-fallback interface or its own interface is gone — never onto a fallback.
//

import XCTest
import CryptoKit
import ReticulumSwift
@testable import LXMFSwift

final class LXMRouterLinkMoveTests: XCTestCase {

    private let destHash = Data(repeating: 0x42, count: 16)

    /// Router + transport with `relay`, `wifi` and fallback `ble` interfaces, and the best path
    /// to `destHash` on `pathInterface`.
    private func makeRouter(pathInterface: String) async throws -> (LXMRouter, ReticulumTransport) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-linkmove-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        let router = try await LXMRouter(identity: Identity(), databasePath: dbPath)

        let pathTable = PathTable()
        await pathTable.setFallbackInterface("ble")
        await pathTable.record(entry: PathEntry(destinationHash: destHash,
                                                publicKeys: Data(repeating: 0xAA, count: 64),
                                                interfaceId: pathInterface,
                                                hopCount: 1,
                                                randomBlob: Data(repeating: 0xBB, count: 10),
                                                nextHop: nil))
        let transport = ReticulumTransport(pathTable: pathTable)
        for id in ["relay", "wifi", "ble"] {
            try await transport.addInterface(StubInterface(id: id))
        }
        await router.setTransport(transport)
        return (router, transport)
    }

    /// A real link attached to `interfaceId`. Mirrors `LXMRouterLinkCloseTests.makeLink`.
    private func makeLink(attachedTo interfaceId: String) async throws -> Link {
        let identity = Identity()
        let dest = Destination(identity: identity, appName: "test", aspects: ["link-move"])
        var requestData = Data()
        requestData.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        requestData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        requestData.append(IncomingLinkRequest.encodeSignaling(mtu: 500, mode: LinkConstants.MODE_DEFAULT))
        let header = PacketHeader(headerType: .header1, hasContext: false, transportType: .broadcast,
                                  destinationType: .single, packetType: .linkRequest, hopCount: 0)
        let packet = Packet(header: header, destination: dest.hash, context: 0x00, data: requestData)
        let link = Link(incomingRequest: try IncomingLinkRequest(data: requestData, packet: packet),
                        destination: dest, identity: identity)
        await link.setAttachedInterface(interfaceId)
        return link
    }

    func testMovesWhenRouteReachedAnotherNormalInterface() async throws {
        let (router, transport) = try await makeRouter(pathInterface: "wifi")
        let link = try await makeLink(attachedTo: "relay")
        let shouldMove = await router.linkShouldMove(link, to: destHash, transport: transport)
        XCTAssertTrue(shouldMove)
    }

    func testStaysWhenRouteIsOnTheLinksInterface() async throws {
        let (router, transport) = try await makeRouter(pathInterface: "relay")
        let link = try await makeLink(attachedTo: "relay")
        let shouldMove = await router.linkShouldMove(link, to: destHash, transport: transport)
        XCTAssertFalse(shouldMove)
    }

    func testStaysWhenRouteMovedToFallback() async throws {
        let (router, transport) = try await makeRouter(pathInterface: "ble")
        let link = try await makeLink(attachedTo: "relay")
        let shouldMove = await router.linkShouldMove(link, to: destHash, transport: transport)
        XCTAssertFalse(shouldMove, "bulk stays on the relay rather than moving onto BLE")
    }

    func testMovesWhenLinksInterfaceIsGone() async throws {
        let (router, transport) = try await makeRouter(pathInterface: "ble")
        let link = try await makeLink(attachedTo: "icWebrtc0-despawned")
        let shouldMove = await router.linkShouldMove(link, to: destHash, transport: transport)
        XCTAssertTrue(shouldMove)
    }
}

private actor StubInterface: NetworkInterface {
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
