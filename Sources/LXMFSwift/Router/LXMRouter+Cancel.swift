// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouter+Cancel.swift
//  LXMFSwift
//

import Foundation

// MARK: - Cancelling outbound messages
extension LXMRouter {
    /// **FORK ADDITION** — cancels a message still waiting in the outbound queue, as Python's
    /// `LXMRouter.cancel_outbound`. The next `processOutbound` pass drops it and reports it failed.
    ///
    /// - Returns: `false` when the message isn't queued (already sent, delivered, or unknown).
    @discardableResult
    public func cancelOutbound(_ messageHash: Data) -> Bool {
        guard let index = pendingOutbound.firstIndex(where: { $0.hash == messageHash }) else { return false }
        pendingOutbound[index].state = .cancelled
        return true
    }
}
