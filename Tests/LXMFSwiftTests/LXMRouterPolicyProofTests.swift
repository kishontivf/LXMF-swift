//
//  LXMRouterPolicyProofTests.swift
//  LXMFSwiftTests
//
//  Drives `deliveryPacket` end to end over a link and pins the proof-after-admission rule:
//  a packet the host's delivery policy rejects is never proved, one it admits is proved once.
//

#if DEBUG  // Uses ReticulumSwift's `_setStateForTesting` (DEBUG-only).
import CryptoKit
import XCTest
@testable import LXMFSwift
@testable import ReticulumSwift

final class LXMRouterPolicyProofTests: XCTestCase {
    private struct Fixture {
        let router: LXMRouter
        let link: Link
        let linkId: Data
        let captured: ProofCapture
        let me: Identity
    }

    private func makeFixture() async throws -> Fixture {
        let me = Identity()
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-policy-proof-\(UUID().uuidString).db").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        let router = try await LXMRouter(identity: me, databasePath: dbPath)
        let transport = ReticulumTransport()
        await router.setTransport(transport)

        let dest = Destination(identity: me, appName: "lxmf", aspects: ["delivery"])
        var requestData = Data()
        requestData.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        requestData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        requestData.append(IncomingLinkRequest.encodeSignaling(mtu: 500, mode: LinkConstants.MODE_DEFAULT))
        let lrPacket = Packet(header: PacketHeader(headerType: .header1, hasContext: false, transportType: .broadcast,
                                                   destinationType: .single, packetType: .linkRequest, hopCount: 0),
                              destination: dest.hash, context: 0x00, data: requestData)
        let link = Link(incomingRequest: try IncomingLinkRequest(data: requestData, packet: lrPacket),
                        destination: dest, identity: me)
        let captured = ProofCapture()
        await link.setSendCallback { data in await captured.append(data) }
        await link._setStateForTesting(.active)
        await transport.registerLink(link)
        return Fixture(router: router, link: link, linkId: await link.linkId, captured: captured, me: me)
    }

    /// A link DATA packet carrying a complete, signed LXMF message from `sender`.
    private func linkPacket(from sender: Identity, to fixture: Fixture, content: String) throws -> Packet {
        let recipient = Destination.hash(identity: fixture.me, appName: "lxmf", aspects: ["delivery"])
        var message = LXMessage(destinationHash: recipient, sourceIdentity: sender, content: Data(content.utf8),
                                title: Data(), fields: nil, desiredMethod: .direct)
        let packed = try message.pack()
        return Packet(header: PacketHeader(headerType: .header1, hasContext: false, transportType: .broadcast,
                                           destinationType: .link, packetType: .data, hopCount: 0),
                      destination: fixture.linkId, context: 0x00, data: packed)
    }

    func testPolicyRejectedPacketIsNotProved() async throws {
        let fixture = try await makeFixture()
        let sender = Identity()
        await fixture.router.registerIdentity(sender)
        await fixture.router.setDeliveryPolicy { _, _ in false }
        let packet = try linkPacket(from: sender, to: fixture, content: "blocked")

        await fixture.router.deliveryPacket(packet.data, packet)

        let sent = await fixture.captured.drain()
        XCTAssertTrue(sent.isEmpty, "A policy-rejected packet must leave the sender unproven")
    }

    func testAdmittedPacketIsProvedOnce() async throws {
        let fixture = try await makeFixture()
        let sender = Identity()
        await fixture.router.registerIdentity(sender)
        await fixture.router.setDeliveryPolicy { _, _ in true }
        let packet = try linkPacket(from: sender, to: fixture, content: "allowed")

        await fixture.router.deliveryPacket(packet.data, packet)

        let sent = await fixture.captured.drain()
        XCTAssertEqual(sent.count, 1)
        let proof = try Packet(from: try XCTUnwrap(sent.first))
        XCTAssertEqual(proof.header.packetType, .proof)
        XCTAssertEqual(Data(proof.data.prefix(32)), packet.getFullHash())
    }

    func testDuplicateIsProvedAgain() async throws {
        let fixture = try await makeFixture()
        let sender = Identity()
        await fixture.router.registerIdentity(sender)
        let packet = try linkPacket(from: sender, to: fixture, content: "twice")

        await fixture.router.deliveryPacket(packet.data, packet)
        await fixture.router.deliveryPacket(packet.data, packet)

        let sent = await fixture.captured.drain()
        XCTAssertEqual(sent.count, 2, "a sender whose first proof was lost must get another")
    }
}

private actor ProofCapture {
    private var packets: [Data] = []

    func append(_ data: Data) {
        packets.append(data)
    }

    func drain() -> [Data] {
        let copy = packets
        packets = []
        return copy
    }
}
#endif
