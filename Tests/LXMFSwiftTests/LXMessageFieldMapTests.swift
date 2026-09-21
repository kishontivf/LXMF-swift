// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMessageFieldMapTests.swift
//  LXMFSwiftTests
//
//  Multi-entry maps inside fields: int-keyed round trip, and signature validation that does not
//  depend on the sender's map key order (Swift dictionaries iterate in a per-process order).
//

import XCTest
import CryptoKit
@testable import LXMFSwift
import ReticulumSwift

final class LXMessageFieldMapTests: XCTestCase {
    private let target = Data((0..<32).map { UInt8($0) })
    private let emoji = Data("👍".utf8)

    func testReactionFieldRoundTrip() throws {
        let identity = Identity()
        var message = LXMessage(
            destinationHash: Identity().hash,
            sourceIdentity: identity,
            content: Data(),
            title: Data(),
            fields: [LXMessage.FIELD_REACTION: [LXMessage.REACTION_TO: target,
                                                LXMessage.REACTION_CONTENT: emoji] as [UInt8: Any]],
            desiredMethod: .direct
        )
        let packed = try message.pack()

        let unpacked = try LXMessage.unpackFromBytes(packed, sourceIdentity: identity)
        XCTAssertTrue(unpacked.signatureValidated)
        XCTAssertEqual(unpacked.hash, message.hash)
        let reaction = try XCTUnwrap(unpacked.fields?[LXMessage.FIELD_REACTION] as? [UInt8: Any])
        XCTAssertEqual(reaction[LXMessage.REACTION_TO] as? Data, target)
        XCTAssertEqual(reaction[LXMessage.REACTION_CONTENT] as? Data, emoji)
    }

    /// Both key orders of the same map must verify — a receiver that re-encodes would fail one.
    func testSignatureValidatesForEitherMapKeyOrder() throws {
        let identity = Identity()
        let destination = Identity().hash
        let source = Data(repeating: 0xAB, count: 16)

        for reversed in [false, true] {
            let payload = makePayload(reversedKeys: reversed, stamp: nil)
            let packed = try sign(payload: payload, destination: destination, source: source, identity: identity)
            let unpacked = try LXMessage.unpackFromBytes(packed, sourceIdentity: identity)
            XCTAssertTrue(unpacked.signatureValidated, "key order reversed=\(reversed)")
        }
    }

    /// The stamp rides outside the hash; slicing it off the received bytes must keep the map order.
    func testSignatureValidatesWithStamp() throws {
        let identity = Identity()
        let destination = Identity().hash
        let source = Data(repeating: 0xCD, count: 16)
        let stamp = Data(repeating: 0x5A, count: 32)

        for reversed in [false, true] {
            let hashed = makePayload(reversedKeys: reversed, stamp: nil)
            let signature = try signature(for: hashed, destination: destination, source: source, identity: identity)
            let wirePayload = makePayload(reversedKeys: reversed, stamp: stamp)
            let packed = destination + source + signature + wirePayload
            let unpacked = try LXMessage.unpackFromBytes(packed, sourceIdentity: identity)
            XCTAssertTrue(unpacked.signatureValidated, "key order reversed=\(reversed)")
            XCTAssertEqual(unpacked.stamp, stamp)
        }
    }
}

// MARK: - Hand-encoded payloads
private extension LXMessageFieldMapTests {
    /// `[timestamp, title, content, {0x40: {0x00: target, 0x01: emoji}}, stamp?]`, encoded by hand so
    /// the nested map's key order is fixed rather than whatever `Dictionary` iterates.
    func makePayload(reversedKeys: Bool, stamp: Data?) -> Data {
        var bytes = Data([stamp == nil ? 0x94 : 0x95])
        bytes.append(0xCB)
        withUnsafeBytes(of: Double(1_700_000_000.5).bitPattern.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: [0xC4, 0x00])  // title: empty bin8
        bytes.append(contentsOf: [0xC4, 0x00])  // content: empty bin8
        bytes.append(contentsOf: [0x81, 0x40, 0x82])
        let to = Data([0x00, 0xC4, UInt8(target.count)]) + target
        let content = Data([0x01, 0xC4, UInt8(emoji.count)]) + emoji
        bytes.append(reversedKeys ? content + to : to + content)
        if let stamp {
            bytes.append(contentsOf: [0xC4, UInt8(stamp.count)])
            bytes.append(stamp)
        }
        return bytes
    }

    func signature(for payload: Data, destination: Data, source: Data, identity: Identity) throws -> Data {
        let hashedPart = destination + source + payload
        let hash = Data(SHA256.hash(data: hashedPart))
        return try identity.sign(hashedPart + hash)
    }

    func sign(payload: Data, destination: Data, source: Data, identity: Identity) throws -> Data {
        let signature = try signature(for: payload, destination: destination, source: source, identity: identity)
        return destination + source + signature + payload
    }
}
