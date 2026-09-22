// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMFDatabaseTests.swift
//  LXMFSwiftTests
//
//  Unit tests for LXMFDatabase persistence layer.
//  Tests verify message and conversation storage operations.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMFDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> LXMFDatabase {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-db-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        return try LXMFDatabase(path: dbPath)
    }

    // MARK: - Database Creation Tests

    /// Test database creation with WAL mode
    func testDatabaseCreation() async throws {
        let db = try makeDatabase()

        // Verify database was created (no error means success)
        _ = db  // Suppress unused warning
    }

    // MARK: - Message Tests

    /// Test save and retrieve message
    func testSaveRetrieveMessage() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test message content".data(using: .utf8)!,
            title: "Test Title".data(using: .utf8)!,
            fields: nil,
            desiredMethod: .direct
        )

        // Pack message (required before saving)
        _ = try message.pack()

        // Save message
        try await db.saveMessage(message)

        // Retrieve by ID
        let retrieved = try await db.getMessage(id: message.hash)

        // Verify retrieved message
        XCTAssertNotNil(retrieved, "Message should be retrieved")
        XCTAssertEqual(retrieved!.hash, message.hash, "Hash should match")
        XCTAssertEqual(retrieved!.timestamp, message.timestamp, "Timestamp should match")
        XCTAssertEqual(String(data: retrieved!.title, encoding: .utf8), "Test Title", "Title should match")
        XCTAssertEqual(String(data: retrieved!.content, encoding: .utf8), "Test message content", "Content should match")
    }

    /// Test hasMessage returns false for unknown ID
    func testMessageNotFound() async throws {
        let db = try makeDatabase()

        let nonExistentId = Data(repeating: 0xFF, count: 32)
        let hasMessage = try await db.hasMessage(id: nonExistentId)

        XCTAssertFalse(hasMessage, "hasMessage should return false for unknown ID")
    }

    /// Test update message state
    func testUpdateMessageState() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()
        try await db.saveMessage(message)

        // Update state to SENT
        try await db.updateMessageState(id: message.hash, state: .sent)

        // Retrieve and verify
        let retrieved = try await db.getMessage(id: message.hash)
        XCTAssertEqual(retrieved?.state, .sent, "State should be updated to SENT")
    }

    // MARK: - Conversation Tests

    /// Test conversation creation on message save
    func testConversationCreation() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "First message".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()

        // Save message
        try await db.saveMessage(message)

        // Get conversations
        let conversations = try await db.getConversations()

        XCTAssertEqual(conversations.count, 1, "Should have 1 conversation")
        XCTAssertEqual(conversations[0].destinationHash, destIdentity.hash, "Conversation hash should match destination")
        XCTAssertEqual(conversations[0].lastMessageTimestamp, message.timestamp, "Last timestamp should match")
    }

    /// Test conversation update with multiple messages
    func testConversationUpdate() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        // Send first message
        var message1 = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "First message".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message1.pack()
        try await db.saveMessage(message1)

        // Wait a moment to ensure different timestamp
        try await Task.sleep(nanoseconds: 10_000_000)

        // Send second message
        var message2 = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Second message".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message2.pack()
        try await db.saveMessage(message2)

        // Get conversations
        let conversations = try await db.getConversations()

        XCTAssertEqual(conversations.count, 1, "Should still have 1 conversation")
        XCTAssertEqual(conversations[0].lastMessageTimestamp, message2.timestamp, "Last timestamp should be updated")
        XCTAssertTrue(conversations[0].lastMessagePreview?.contains("Second message") ?? false, "Preview should be updated")
    }

    // MARK: - Outbound Queue Tests

    /// Test load pending outbound messages
    func testLoadPendingOutbound() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        // Create outbound message
        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Outbound".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()

        // Save (should be in OUTBOUND state)
        try await db.saveMessage(message)

        // Load pending
        let pending = try await db.loadPendingOutbound()

        XCTAssertEqual(pending.count, 1, "Should have 1 pending message")
        XCTAssertEqual(pending[0].hash, message.hash, "Pending message hash should match")
    }

    /// Test load failed outbound messages
    func testLoadFailedOutbound() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Failed".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()
        try await db.saveMessage(message)

        // Update state to FAILED
        try await db.updateMessageState(id: message.hash, state: .failed)

        // Load failed
        let failed = try await db.loadFailedOutbound()

        XCTAssertEqual(failed.count, 1, "Should have 1 failed message")
        XCTAssertEqual(failed[0].state, .failed, "Message should be in FAILED state")
    }

    // MARK: - Pagination Tests

    /// Test get messages with pagination
    func testGetMessagesPagination() async throws {
        let db = try makeDatabase()

        let sourceIdentity = Identity()
        let destIdentity = Identity()

        // Create multiple messages
        for i in 1...5 {
            var message = LXMessage(
                destinationHash: destIdentity.hash,
                sourceIdentity: sourceIdentity,
                content: "Message \(i)".data(using: .utf8)!,
                title: Data(),
                fields: nil,
                desiredMethod: .direct
            )
            _ = try message.pack()
            try await db.saveMessage(message)
            try await Task.sleep(nanoseconds: 10_000_000)  // Ensure different timestamps
        }

        // Get messages with limit
        let messages = try await db.getMessages(forConversation: destIdentity.hash, limit: 3, offset: 0)

        XCTAssertEqual(messages.count, 3, "Should return 3 messages with limit")
        // Messages should be ordered by timestamp descending (newest first)
        XCTAssertGreaterThan(messages[0].timestamp, messages[1].timestamp, "Messages should be ordered by timestamp DESC")
    }

    // MARK: - Unread Count Tests

    /// Test unread count for incoming messages
    func testUnreadCount() async throws {
        let db = try makeDatabase()

        // Create incoming message by unpacking
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Incoming message".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try message.pack()

        // Unpack to make it incoming
        var incomingMessage = try LXMessage.unpackFromBytes(packed)
        incomingMessage.state = .delivered

        // Save incoming message
        try await db.saveMessage(incomingMessage)

        // Get conversations
        let conversations = try await db.getConversations()

        XCTAssertEqual(conversations.count, 1, "Should have 1 conversation")
        XCTAssertEqual(conversations[0].unreadCount, 1, "Unread count should be 1 for incoming message")
        XCTAssertTrue(conversations[0].hasUnreadMessages, "hasUnreadMessages should be true")
    }

    // MARK: - Annotation Tests

    /// A router re-save (state change) must not wipe reactions applied to the row since.
    func testResaveKeepsReactions() async throws {
        let db = try makeDatabase()

        var message = LXMessage(
            destinationHash: Identity().hash,
            sourceIdentity: Identity(),
            content: "Reacted to".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()
        try await db.saveMessage(message)
        try await db.updateReactions(messageId: message.hash, reactionsJson: #"{"👍":["abcd"]}"#)

        message.state = .delivered
        try await db.saveMessage(message)

        let reactions = try await db.getReactionsJson(messageId: message.hash)
        XCTAssertEqual(reactions, #"{"👍":["abcd"]}"#)
        let record = try await db.getMessageRecord(id: message.hash)
        XCTAssertEqual(record?.state, LXMessageState.delivered.rawValue)
    }

    /// The standard FIELD_REPLY_TO (0x30) carries raw hash bytes; the record keeps them as hex.
    func testReplyToFromStandardField() async throws {
        let db = try makeDatabase()
        let target = Data((0..<32).map { UInt8($0) })

        var message = LXMessage(
            destinationHash: Identity().hash,
            sourceIdentity: Identity(),
            content: "Reply".data(using: .utf8)!,
            title: Data(),
            fields: [LXMessage.FIELD_REPLY_TO: target],
            desiredMethod: .direct
        )
        _ = try message.pack()
        try await db.saveMessage(message)

        let record = try await db.getMessageRecord(id: message.hash)
        XCTAssertEqual(record?.replyToId, target.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Deletion Tests

    private func savedMessage(_ db: LXMFDatabase, content: String, destination: Data,
                              state: LXMessageState = .delivered) async throws -> LXMessage {
        var message = LXMessage(destinationHash: destination, sourceIdentity: Identity(),
                                content: Data(content.utf8), title: Data(), fields: nil, desiredMethod: .direct)
        _ = try message.pack()
        message.state = state
        try await db.saveMessage(message)
        return message
    }

    /// Deleting erases the content but keeps the row, and a second delete changes nothing.
    func testMarkDeletedErasesOnceAndKeepsTheRow() async throws {
        let db = try makeDatabase()
        let message = try await savedMessage(db, content: "secret", destination: Identity().hash)

        let first = try await db.markDeleted(messageId: message.hash, at: 1_000)
        let second = try await db.markDeleted(messageId: message.hash, at: 2_000)

        XCTAssertEqual(first, .deleted)
        XCTAssertEqual(second, .alreadyDeleted)
        let stored = try await db.getMessageRecord(id: message.hash)
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.deletedAt, 1_000)
        XCTAssertTrue(record.content.isEmpty)
        XCTAssertTrue(record.packedLxmf.isEmpty)
        let fetched = try await db.getMessage(id: message.hash)
        XCTAssertNil(fetched, "an erased row has nothing to unpack")
    }

    func testMarkDeletedHonoursTheCallersCheck() async throws {
        let db = try makeDatabase()
        let message = try await savedMessage(db, content: "keep", destination: Identity().hash)

        let outcome = try await db.markDeleted(messageId: message.hash, at: 1_000, isAllowed: { _ in false })

        XCTAssertEqual(outcome, .notAllowed)
        let record = try await db.getMessageRecord(id: message.hash)
        XCTAssertNil(record?.deletedAt)
        let missing = try await db.markDeleted(messageId: Data(repeating: 1, count: 32), at: 1_000)
        XCTAssertEqual(missing, .notFound)
    }

    /// The router re-saves a message on state changes; that must not bring deleted content back.
    func testResaveOfADeletedMessageStaysErased() async throws {
        let db = try makeDatabase()
        var message = try await savedMessage(db, content: "secret", destination: Identity().hash, state: .sending)
        _ = try await db.markDeleted(messageId: message.hash, at: 1_000)

        message.state = .failed
        try await db.saveMessage(message)

        let stored = try await db.getMessageRecord(id: message.hash)
        let record = try XCTUnwrap(stored)
        XCTAssertTrue(record.content.isEmpty)
        XCTAssertEqual(record.deletedAt, 1_000)
        XCTAssertEqual(record.state, LXMessageState.failed.rawValue)
    }

    /// A deleted outbound message is cancelled, so the router never loads it for sending again.
    func testDeletedPendingMessageIsNotLoadedForSending() async throws {
        let db = try makeDatabase()
        let message = try await savedMessage(db, content: "unsent", destination: Identity().hash, state: .outbound)

        _ = try await db.markDeleted(messageId: message.hash, at: 1_000)

        let pending = try await db.loadPendingOutbound()
        XCTAssertFalse(pending.contains { $0.hash == message.hash })
        let record = try await db.getMessageRecord(id: message.hash)
        XCTAssertEqual(record?.state, LXMessageState.cancelled.rawValue)
    }

    /// The conversation list must not keep showing the deleted text.
    func testDeletingTheNewestMessageRebuildsThePreview() async throws {
        let db = try makeDatabase()
        let destination = Identity().hash
        _ = try await savedMessage(db, content: "older", destination: destination)
        try await Task.sleep(for: .milliseconds(20))
        let newest = try await savedMessage(db, content: "regret", destination: destination)

        _ = try await db.markDeleted(messageId: newest.hash, at: 1_000)

        let conversation = try await db.getConversation(hash: destination)
        XCTAssertEqual(conversation?.lastMessagePreview, "older")
    }
}
