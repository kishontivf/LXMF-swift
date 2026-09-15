// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMFDatabaseExportImportTests.swift
//  LXMFSwiftTests
//
//  Pins the fork's backup/restore path (KVF-divergence D6): `exportDatabase(to:)` writes a
//  self-contained snapshot, and `importDatabase(from:)` replaces the live contents in place and
//  forward-migrates the snapshot. Untested until the GRDB 7 bump (D11) made it worth proving
//  that `VACUUM INTO`, `backup(to:)` and the migrator still behave.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMFDatabaseExportImportTests: XCTestCase {
    /// A path in a fresh temporary directory, removed with its WAL/SHM sidecars after the test.
    private func temporaryPath(_ name: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-export-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(name).path
    }

    private func makeDatabase() throws -> LXMFDatabase {
        try LXMFDatabase(path: temporaryPath("live.db"))
    }

    private func savedMessage(_ text: String, to destination: Identity, in db: LXMFDatabase) async throws -> LXMessage {
        var message = LXMessage(
            destinationHash: destination.hash,
            sourceIdentity: Identity(),
            content: Data(text.utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()
        try await db.saveMessage(message)
        return message
    }

    // MARK: - Export

    /// `VACUUM INTO` folds the WAL into one file — a snapshot that is complete on its own.
    func testExportWritesASingleFileWithoutSidecars() async throws {
        let db = try makeDatabase()
        _ = try await savedMessage("Stay frosty.", to: Identity(), in: db)
        let snapshot = try temporaryPath("snapshot.db")

        try await db.exportDatabase(to: snapshot)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: snapshot))
        XCTAssertFalse(fileManager.fileExists(atPath: snapshot + "-wal"))
        XCTAssertFalse(fileManager.fileExists(atPath: snapshot + "-shm"))
    }

    /// SQLite refuses to `VACUUM INTO` an existing file; the documented contract relies on that.
    func testExportFailsWhenTheDestinationExists() async throws {
        let db = try makeDatabase()
        let snapshot = try temporaryPath("snapshot.db")
        FileManager.default.createFile(atPath: snapshot, contents: Data("occupied".utf8))

        do {
            try await db.exportDatabase(to: snapshot)
            XCTFail("export must not overwrite an existing file")
        } catch {
            // Expected.
        }
    }

    // MARK: - Import

    /// The live database takes the snapshot's contents, and what it held before is gone.
    func testImportReplacesTheLiveContents() async throws {
        let source = try makeDatabase()
        let sourceContact = Identity()
        let kept = try await savedMessage("From the snapshot", to: sourceContact, in: source)
        let snapshot = try temporaryPath("snapshot.db")
        try await source.exportDatabase(to: snapshot)

        let live = try makeDatabase()
        let discarded = try await savedMessage("Replaced by the restore", to: Identity(), in: live)

        try await live.importDatabase(from: snapshot)

        let restored = try await live.getMessage(id: kept.hash)
        XCTAssertEqual(restored.map { String(decoding: $0.content, as: UTF8.self) }, "From the snapshot")
        let hasDiscarded = try await live.hasMessage(id: discarded.hash)
        XCTAssertFalse(hasDiscarded)
        let conversations = try await live.getConversations()
        XCTAssertEqual(conversations.map(\.destinationHash), [sourceContact.hash])
        let count = try await live.countMessages(forConversation: sourceContact.hash)
        XCTAssertEqual(count, 1)
    }

    /// Restored in place: the same instance keeps working, reads and writes alike.
    func testTheLiveDatabaseStaysWritableAfterImport() async throws {
        let source = try makeDatabase()
        let contact = Identity()
        _ = try await savedMessage("Before", to: contact, in: source)
        let snapshot = try temporaryPath("snapshot.db")
        try await source.exportDatabase(to: snapshot)

        let live = try makeDatabase()
        try await live.importDatabase(from: snapshot)
        _ = try await savedMessage("After", to: contact, in: live)

        let count = try await live.countMessages(forConversation: contact.hash)
        XCTAssertEqual(count, 2)
    }

    /// A snapshot from before any migration ran is brought up to the current schema — the oldest
    /// possible "older snapshot" the forward-migration promise covers.
    func testImportForwardMigratesAnUnmigratedSnapshot() async throws {
        let empty = try temporaryPath("empty.db")
        FileManager.default.createFile(atPath: empty, contents: nil)

        let live = try makeDatabase()
        try await live.importDatabase(from: empty)

        let contact = Identity()
        let message = try await savedMessage("Schema is back", to: contact, in: live)
        let hasMessage = try await live.hasMessage(id: message.hash)
        XCTAssertTrue(hasMessage)
    }
}
