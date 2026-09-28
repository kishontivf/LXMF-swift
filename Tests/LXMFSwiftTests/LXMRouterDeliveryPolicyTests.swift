import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterDeliveryPolicyTests: XCTestCase {

    // MARK: - Helpers (copied from LXMRouterDeliveryTests; private there)

    private func makeRouter(identity: Identity) async throws -> (LXMRouter, String) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-router-policy-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        let router = try await LXMRouter(identity: identity, databasePath: dbPath)
        return (router, dbPath)
    }

    private func makePackedMessage(from source: Identity, to recipient: Identity,
                                   content: String, fields: [UInt8: Any]? = nil) throws -> (packed: Data, hash: Data) {
        let recipientDeliveryHash = Destination.hash(identity: recipient, appName: "lxmf", aspects: ["delivery"])
        var message = LXMessage(destinationHash: recipientDeliveryHash, sourceIdentity: source,
                                content: content.data(using: .utf8)!, title: Data(), fields: fields,
                                desiredMethod: .direct)
        let packed = try message.pack()
        return (packed, message.hash)
    }

    private func deliveryHash(of identity: Identity) -> Data {
        Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
    }

    // MARK: - Policy

    func testNoPolicyAdmitsVerifiedMessage() async throws {
        let me = Identity(), peer = Identity()
        let (router, _) = try await makeRouter(identity: me)
        await router.registerIdentity(peer)
        let (packed, _) = try makePackedMessage(from: peer, to: me, content: "no policy")

        let outcome = await router.deliver(packed, method: .direct)

        XCTAssertEqual(outcome, .accepted)
    }

    func testPolicyRejectsBeforeStorageAndDedup() async throws {
        let me = Identity(), peer = Identity()
        let (router, dbPath) = try await makeRouter(identity: me)
        let database = try LXMFDatabase(path: dbPath)
        await router.registerIdentity(peer)
        await router.setDeliveryPolicy { _, _ in false }
        let (packed, hash) = try makePackedMessage(from: peer, to: me, content: "rejected")

        let first = await router.deliver(packed, method: .direct)
        XCTAssertEqual(first, .rejectedByPolicy)
        let stored = try await database.getMessage(id: hash)
        XCTAssertNil(stored, "A policy-rejected message must never reach the database")

        // Not recorded as delivered: the same bytes are accepted once the policy allows them.
        await router.setDeliveryPolicy { _, _ in true }
        let second = await router.deliver(packed, method: .direct)
        XCTAssertEqual(second, .accepted)
    }

    func testPolicySeesSourceHashAndFields() async throws {
        let me = Identity(), peer = Identity()
        let (router, _) = try await makeRouter(identity: me)
        await router.registerIdentity(peer)
        let expectedSource = deliveryHash(of: peer)
        let seen = SeenArguments()
        await router.setDeliveryPolicy { source, fields in
            await seen.record(source: source, commandName: (fields?[0xC0] as? [Any])?[1] as? String)
            return true
        }
        let (packed, _) = try makePackedMessage(from: peer, to: me, content: "fields",
                                                fields: [0xC0: ["id1", "analog.test"] as [Any]])

        _ = await router.deliver(packed, method: .direct)

        let recorded = await seen.value
        XCTAssertEqual(recorded?.source, expectedSource)
        XCTAssertEqual(recorded?.commandName, "analog.test")
    }

    func testDuplicateIsReportedAsDuplicate() async throws {
        let me = Identity(), peer = Identity()
        let (router, _) = try await makeRouter(identity: me)
        await router.registerIdentity(peer)
        let (packed, _) = try makePackedMessage(from: peer, to: me, content: "twice")

        let first = await router.deliver(packed, method: .direct)
        let second = await router.deliver(packed, method: .direct)

        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(second, .duplicate)
    }

    func testUnverifiedSourceIsRejectedNotRejectedByPolicy() async throws {
        let me = Identity(), stranger = Identity()
        let (router, _) = try await makeRouter(identity: me)
        await router.setDeliveryPolicy { _, _ in true }
        let (packed, _) = try makePackedMessage(from: stranger, to: me, content: "unknown")

        let outcome = await router.deliver(packed, method: .direct)

        XCTAssertEqual(outcome, .rejected)
    }

    func testLxmfDeliveryBoolMirrorsOutcome() async throws {
        let me = Identity(), peer = Identity()
        let (router, _) = try await makeRouter(identity: me)
        await router.registerIdentity(peer)
        await router.setDeliveryPolicy { _, _ in false }
        let (packed, _) = try makePackedMessage(from: peer, to: me, content: "bool")

        let accepted = await router.lxmfDelivery(packed, method: .direct)

        XCTAssertFalse(accepted)
    }

    // MARK: - Proof decision

    func testProofIsWithheldOnlyForPolicyRejection() {
        XCTAssertTrue(LXMRouter.shouldProve(.accepted))
        XCTAssertTrue(LXMRouter.shouldProve(.duplicate))
        XCTAssertTrue(LXMRouter.shouldProve(.rejected))
        XCTAssertFalse(LXMRouter.shouldProve(.rejectedByPolicy))
    }
}

private actor SeenArguments {
    struct Value { let source: Data; let commandName: String? }
    private(set) var value: Value?
    func record(source: Data, commandName: String?) { value = Value(source: source, commandName: commandName) }
}
