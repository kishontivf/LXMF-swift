// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouter+NetworkDiagnostics.swift
//  LXMFSwift
//
//  [TEMPORARY] field-test scaffolding: routes the outbound queue's behaviour into
//  ReticulumSwift's `NetworkLog` (the shared `<device>-network.log`).
//
//  Why this file exists at all: the rest of LXMFSwift logs through `os.log`, which never
//  reaches the on-device log files the automated tests collect — so the outbound queue,
//  the component most implicated in every "messaging is unreliable" report to date, has
//  been the one part of the send path nobody could see. Everything here is additive and
//  confined to this file (bar a handful of call sites and two stored properties on
//  LXMRouter) so it can be dropped wholesale, or re-applied after an upstream refresh,
//  without untangling it from real logic.
//

import Foundation
import ReticulumSwift

// MARK: - Queue diagnostics
extension LXMRouter {
    /// [TEMPORARY] Anything slower than this inside one queue entry's delivery attempt is reported
    /// individually. A `.direct` link establishment blocks for up to LINK_ESTABLISHMENT_TIMEOUT
    /// (30s), and because `processOutbound` is a serial self-rescheduling pass, everything
    /// queued behind it waits that long too — the starvation signature we're hunting.
    static var slowAttemptThreshold: Duration { .seconds(2) }

    /// [TEMPORARY] Emit the queue summary at least this often even when unchanged, so a queue that is
    /// stuck (rather than empty) still leaves a trail. Without it, "no output" would be
    /// ambiguous between healthy-and-idle and wedged.
    static var queueSummaryHeartbeat: Duration { .seconds(30) }

    /// [TEMPORARY] Mirror of `shouldAttemptDelivery`'s gate (a nil `nextDeliveryAttempt` means "now").
    /// Duplicated rather than reused because that method is private and this is scaffolding
    /// that must not widen the real type's surface to exist.
    static func isDue(_ message: LXMessage) -> Bool {
        guard let next = message.nextDeliveryAttempt else { return true }
        return Date() >= next
    }

    /// [TEMPORARY] Compact one-line census of the queue: total depth, split by delivery method and by
    /// state. Method split is the important half — a queue that is all `.direct` behind one
    /// unreachable contact looks identical, by depth alone, to a healthy busy queue.
    func queueCensus() -> String {
        guard !pendingOutbound.isEmpty else { return "depth=0" }

        var byMethod: [String: Int] = [:]
        var byState: [String: Int] = [:]
        var eligible = 0
        for message in pendingOutbound {
            byMethod[String(describing: message.method), default: 0] += 1
            byState[String(describing: message.state), default: 0] += 1
            if Self.isDue(message) { eligible += 1 }
        }
        let methods = byMethod.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let states = byState.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "depth=\(pendingOutbound.count) due=\(eligible) method[\(methods)] state[\(states)]"
    }

    /// [TEMPORARY] Log the census when it changed, or when the heartbeat window elapsed. Called once per
    /// `processOutbound` pass; the change-gate is what keeps a 1s loop from filling the file.
    func logQueueCensus() {
        guard NetworkLog.isEnabled else { return }
        let census = queueCensus()
        let heartbeatDue = ContinuousClock.now - lastQueueSummaryAt >= Self.queueSummaryHeartbeat
        guard census != lastQueueSummary || (heartbeatDue && pendingOutbound.count > 0) else { return }
        lastQueueSummary = census
        lastQueueSummaryAt = .now
        NetworkLog.debug("[QUEUE] \(census)")
    }

    /// [TEMPORARY] Report one delivery attempt that took long enough to hold up the pass.
    ///
    /// `blockedBehind` is the count of entries that were due for an attempt and sat behind
    /// this one — the actual cost of the stall. A slow attempt with nothing behind it is
    /// merely slow; a slow attempt with five due messages behind it is the bug.
    func logSlowAttempt(method: LXDeliveryMethod,
                        destination: Data,
                        elapsed: ContinuousClock.Instant,
                        blockedBehind: Int) {
        guard NetworkLog.isEnabled else { return }
        let behind = blockedBehind > 0 ? " BLOCKED \(blockedBehind) due message(s) behind it" : ""
        NetworkLog.debug("[QUEUE] SLOW \(method) dest=\(NetworkLog.hex8(destination)) "
            + "took \(NetworkLog.ms(since: elapsed))\(behind)")
    }

    /// [TEMPORARY] Number of queue entries at or after `index` that are due for a delivery attempt.
    /// Used to price a stall — see `logSlowAttempt`.
    func dueMessagesAfter(index: Int) -> Int {
        guard index + 1 < pendingOutbound.count else { return 0 }
        return pendingOutbound[(index + 1)...].filter { Self.isDue($0) }.count
    }

    /// [TEMPORARY] A message entering the queue. Size matters here: it decides packet-vs-Resource, and
    /// therefore whether this entry can block the pass for seconds.
    func logEnqueue(_ message: LXMessage) {
        guard NetworkLog.isEnabled else { return }
        NetworkLog.debug("[QUEUE] ENQUEUE hash=\(NetworkLog.hex8(message.hash)) "
            + "dest=\(NetworkLog.hex8(message.destinationHash)) method=\(message.method) "
            + "\(NetworkLog.bytes(message.packed?.count ?? 0)) → depth=\(pendingOutbound.count)")
    }

    /// [TEMPORARY] A message leaving the queue for a terminal reason. The reason string is the whole
    /// value: "delivered" and "maxAttemptsExceeded" both empty the queue, and only this
    /// distinguishes a working network from one that gave up.
    func logDequeue(_ message: LXMessage, reason: String) {
        guard NetworkLog.isEnabled else { return }
        let age = Int(Date().timeIntervalSince1970 - message.timestamp)
        NetworkLog.debug("[QUEUE] DEQUEUE hash=\(NetworkLog.hex8(message.hash)) "
            + "dest=\(NetworkLog.hex8(message.destinationHash)) method=\(message.method) "
            + "reason=\(reason) attempts=\(message.deliveryAttempts) age=\(age)s")
    }
}

// MARK: - Link, resource and proof diagnostics
extension LXMRouter {
    /// [TEMPORARY] Link establishment outcome. The duration is the point — a `.direct` send's cost is
    /// almost entirely this, and a 30s entry here explains a stalled pass on its own.
    func logLinkEstablishment(destination: Data, started: ContinuousClock.Instant, outcome: String) {
        guard NetworkLog.isEnabled else { return }
        NetworkLog.debug("[LINK] dest=\(NetworkLog.hex8(destination)) \(outcome) "
            + "after \(NetworkLog.ms(since: started))")
    }

    /// [TEMPORARY] Resource transfer lifecycle — the image path. Throughput is reported on conclusion so a
    /// transfer that technically succeeded over a slow carrier is distinguishable from one that
    /// went over a fast one; both otherwise look like a single "delivered".
    func logResource(destination: Data,
                     hash: Data?,
                     parts: Int,
                     size: Int,
                     phase: String,
                     started: ContinuousClock.Instant? = nil) {
        guard NetworkLog.isEnabled else { return }
        let resourceHash = hash.map { NetworkLog.hex8($0) } ?? "pending"
        let throughput = started.map { " \(NetworkLog.rate(size, since: $0)) in \(NetworkLog.ms(since: $0))" } ?? ""
        NetworkLog.debug("[RES] \(phase) res=\(resourceHash) dest=\(NetworkLog.hex8(destination)) "
            + "\(NetworkLog.bytes(size)) parts=\(parts)\(throughput)")
    }

    /// [TEMPORARY] Delivery proof received. Everything upstream of this is hope; this line is the only
    /// evidence a message actually landed.
    func logProof(messageHash: Data, method: String) {
        guard NetworkLog.isEnabled else { return }
        NetworkLog.debug("[PROOF] hash=\(NetworkLog.hex8(messageHash)) method=\(method) → delivered")
    }
}
