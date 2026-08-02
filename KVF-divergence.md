# KVF divergence from upstream LXMF-swift

Living record of every change this fork (`kishontivf/LXMF-swift`) carries on top of
upstream (`torlando-tech/LXMF-swift`). **Keep this file current: any commit that adds,
changes, or drops a divergence must update the matching section — and its commit list —
in the same commit.**

These are our own product requirements — there is no intent to upstream them. The point of
this file is to know exactly what to re-apply and what to watch for when pulling upstream
work *in*.

Scope note: this file tracks *fork vs. upstream*. `port-deviations.md` tracks
*Swift port vs. python LXMF* and is upstream's document — entries we add there are
themselves a divergence and are listed under [D3](#d3) below.

- **Upstream base:** `6018671` (`Merge pull request #11 … fix/issue-10-direct-early-close`)
- **Fork HEAD at last update:** `e719af4` (Version bump)
- **Upstream commits not in this fork:** none — the fork is strictly ahead.
- **Last reviewed:** 2026-08-02 — see [Status at generation](#status) for the measured
  upstream age, commit counts, and unmerged upstream branches.

## Summary

| ID | Area | Change | Commits | Depends on |
|----|------|--------|---------|------------|
| [D1](#d1) | Package.swift | Depend on the `kishontivf` reticulum-swift fork (≥ 0.4.1); pin SWCompression exactly to 4.8.7 | `ce27afc`, `7e4f0d8`, `9c28e09`, `8e0cd70`, `e26f9c6`, `e719af4` | — |
| [D2](#d2) | MessagePack | Depth cap + bounded `reserveCapacity` in the decoder | `1e740b1` | — |
| [D3](#d3) | Router (inbound) | Reject unverified-source messages by default (`acceptUnverifiedMessages`) | `69e48e3` | — |
| [D4](#d4) | Router (outbound) | `PATH_DEMOTE_ATTEMPTS` failover assist | `fbd8a74` | D1 |
| [D5](#d5) | Router (outbound) | Dual-dispatch carrier copy on opportunistic send | `e26f9c6` | D1 |
| [D6](#d6) | Storage | `exportDatabase` / `importDatabase` | `ce27afc` | — |
| [D7](#d7) | Repo hygiene | `.gitignore` additions | `facae56` | — |

### Commit ledger

Every fork commit since the upstream base, oldest first. Merge commits (`413640a`,
`cd2317c` — the PR merges for `feature/fable-security-fixes` and `feature/improvements`)
carry no changes of their own and are omitted.

| Commit | Date | Subject | Divergence |
|--------|------|---------|------------|
| `facae56` | 2026-05-20 | Updates | [D7](#d7) |
| `ce27afc` | 2026-05-30 | Import/Export support | [D6](#d6), [D1](#d1) (repoint + 0.1.1, SWCompression pin) |
| `69e48e3` | 2026-06-23 | Verify messages before storing (it can be optionally disable this) | [D3](#d3) |
| `7e4f0d8` | 2026-06-28 | Version bump | [D1](#d1) (0.1.2) |
| `fbd8a74` | 2026-06-29 | Demote attempts after having multiple failed delivery | [D4](#d4) |
| `9c28e09` | 2026-06-30 | Version bump | [D1](#d1) (0.2.0) |
| `1e740b1` | 2026-07-06 | Fable security fixes | [D2](#d2) |
| `8e0cd70` | 2026-07-09 | Version bump | [D1](#d1) (0.3.0) |
| `e26f9c6` | 2026-07-13 | Dual dispatch | [D5](#d5), [D1](#d1) (0.4.0) |
| `e719af4` | 2026-07-14 | Version bump | [D1](#d1) (0.4.1) |

The D-sections below cover **logic/behaviour** divergence. Anything that changes the
*shape* of the data — DB schema or domain model — is tracked separately in
[Schema & domain changes](#schema) and must be logged there too.

---

## Schema & domain changes {#schema}

Standing register for structural changes: new/renamed/dropped **tables**, **columns**,
**indexes**, and new/changed **persisted properties** on domain types. Logic-only changes
do not belong here — this chapter answers "did the stored data shape change, and can an
older or newer build still read it?"

**Current state: no divergence.** The schema is upstream's, at migration `v6_add_replies_reactions`:

| Migration | Origin |
|-----------|--------|
| `v1_initial` | upstream |
| `v2_add_favorite` | upstream |
| `v3_add_icon_appearance` | upstream |
| `v4_add_receiving_interface` | upstream |
| `v5_add_pinned` | upstream |
| `v6_add_replies_reactions` | upstream |

Fork-only changes so far are behavioural: `acceptUnverifiedMessages` ([D3](#d3)) is
in-memory router config, never persisted, and [D6](#d6) only moved the migrator into
`makeMigrator()` and added export/import — it registers no migration and touches no table.

### Ledger

Append one row per structural change. Keep it even after upstream adopts the same idea —
the point is to be able to reconstruct what our stored data looks like at any commit.

| ID | Commit | Date | Migration | Structure changed | Domain property | Reason |
|----|--------|------|-----------|-------------------|-----------------|--------|
| _(none yet)_ | | | | | | |

### Rules for adding one

1. **Append, never edit.** A registered migration has already run on user devices —
   changing its body is silently a no-op there. Add `vN_…` instead.
2. **Pick a fork-safe name.** Upstream will keep adding `v7`, `v8`… against the same
   counter. Name ours `vN_kvf_<what>` so a re-sync produces a visible conflict at the
   migration list instead of two different schemas sharing one identifier.
3. **Log the domain side too.** If the column backs a new property on `LXMessage`,
   `Conversation`, etc., name it in the ledger — that property is part of the public API
   surface consumers compile against.
4. **Check the read-only reader.** Only the writer migrates ([D6](#d6),
   `LXMFDatabase.init`). Under Model B the NE writes and the app reads read-only, and the
   two binaries can be at different versions: a column the app *reads* must be added by a
   migration that has already shipped in the NE. Adding a column and reading it in the same
   release is a crash waiting for whichever process updates second.
5. **Check restore.** `importDatabase(from:)` forward-migrates an older snapshot, so every
   migration must apply cleanly to a database taken before it existed (no assumptions about
   pre-existing rows). Restoring a *newer* snapshot into an older build is not handled —
   note it here if a change makes that scenario worse.
6. **Update the summary table** with a `S<n>` row and this chapter's entry in the same commit.

---

## D1 — Dependency repointing {#d1}

**Commits:** `ce27afc` (repoint to the fork at 0.1.1 + SWCompression exact pin), then the
reticulum floor bumps `7e4f0d8` (0.1.2), `9c28e09` (0.2.0), `8e0cd70` (0.3.0),
`e26f9c6` (0.4.0), `e719af4` (0.4.1)

**Files:** `Package.swift`

- `reticulum-swift` now resolves to `https://github.com/kishontivf/reticulum-swift.git`,
  `from: "0.4.1"` (upstream: `torlando-tech/reticulum-swift`, `from: "0.3.0"`).
- A commented-out `.package(path: "../reticulum-swift")` line is kept for local development.
- SWCompression moved from the range `"4.8.0" ..< "4.9.0"` to `exact: "4.8.7"`. Rationale
  is unchanged from upstream (4.9.0 raises the floor to macOS 14 / iOS 17, above this
  library's macOS 13 / iOS 16 floor); the fork just removes the resolver's freedom to pick
  another 4.8.x.

**Why it matters:** D4 and D5 call APIs that exist only in the forked reticulum-swift
(`PathTable.markPathUnresponsive`, `ReticulumTransport.sendFallbackCopy`), so the two forks
must be re-synced in lockstep — bumping LXMF-swift to a newer upstream base means checking
that our reticulum-swift fork still carries both APIs.

## D2 — MessagePack decoder hardening {#d2}

**Commits:** `1e740b1` (merged as `413640a`)

**Files:** `Sources/LXMFSwift/Protocol/LXMFMessagePack.swift`,
`Tests/LXMFSwiftTests/LXMFMessagePackHardeningTests.swift`

The decoder runs on raw inbound bytes before any signature or source check
(`LXMessage.unpackFromBytes`), so a crafted header is pre-auth attacker-controlled input.

- **Depth bomb:** `decodeValue` now threads a `depth` parameter and throws past
  `lxmfMessagePackMaxDepth = 64`. Unbounded recursion overflows the native stack, which is
  an uncatchable crash in Swift.
- **Width bomb:** `decodeArray`/`decodeMap` bound `reserveCapacity` by the bytes actually
  remaining (`min(count, remaining)` / `min(count, remaining / 2)`). `reserveCapacity` is
  eager, so a 5-byte `dd ff ff ff ff` would otherwise trap on a multi-billion-slot
  allocation before the loop's end-of-data guard fires.

Four tests cover both bombs plus a shallow-nesting acceptance case.

## D3 — Reject unverified-source inbound messages by default {#d3}

**Commits:** `69e48e3`

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift` (`lxmfDelivery`),
`Sources/LXMFSwift/Router/LXMRouterDelegate.swift`, `port-deviations.md`,
`Tests/LXMFSwiftTests/LXMRouterDeliveryTests.swift`

Upstream (and python LXMF) drops a present-but-invalid signature and *accepts* a message
whose source identity is not recalled, storing it with `signatureValidated == false`.
This fork additionally drops `.sourceUnknown` messages, because the 16-byte source hash on
the wire is unauthenticated and therefore spoofable.

- New `acceptUnverifiedMessages` (default `false`) + `setAcceptUnverifiedMessages(_:)`
  restores python behaviour.
- `.signatureInvalid` is always rejected regardless of the flag.
- The drop happens **before** `recordDelivered`, so the hash is not blacklisted in the
  dedup set.
- Full rationale is recorded in `port-deviations.md` (that entry is itself part of this
  divergence).

**Known gap:** the "transient, sender retries" argument holds for `.direct` and
`.opportunistic`, but **not** for `.propagated`. `LXMRouter+Sync.swift` ACKs *all*
transient IDs from the LIST regardless of `lxmfDelivery`'s return value, so the
propagation node deletes a message we rejected and nobody retries it — an unverified
source over propagation is a permanent loss. Not yet fixed; see the review notes.

## D4 — `PATH_DEMOTE_ATTEMPTS` failover assist {#d4}

**Commits:** `fbd8a74`

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift`

New constant `PATH_DEMOTE_ATTEMPTS = 3`. In the outbound processing loop, when a message's
`deliveryAttempts` hits exactly that threshold, the router calls
`pathTable.markPathUnresponsive(destinationHash)` once. `PathTable.record()`'s Path-5 rule
lets a same-emission announce over a *different* interface replace an unresponsive entry,
so a half-dead direct route (e.g. a stale MPC session) can fail over to TCP on the next
announce, with the remaining attempts (up to `MAX_DELIVERY_ATTEMPTS = 8`) using the new path.

**Known gap:** the demotion is method-agnostic. For a `.propagated` message the failure is
with the propagation node, but the *recipient's* path is what gets demoted —
mis-attribution of the same kind already documented for `pendingPropagationSends`.
Impact is limited to announce-acceptance policy.

## D5 — Dual dispatch (carrier copy) on opportunistic send {#d5}

**Commits:** `e26f9c6` (merged as `cd2317c`; same commit bumps reticulum to 0.4.0 for
`sendFallbackCopy`)

**Files:** `Sources/LXMFSwift/Router/LXMRouter+Delivery.swift` (`sendOpportunistic`)

After a successful `transport.send(packet:)`, the router also calls
`transport.sendFallbackCopy(packet:)`. The transport gates it: it fires only when the
destination was heard on a carrier (BLE) interface within 120s and the best path is not
already that carrier. The receiver dedups by packet hash, so the loser is a no-op.

Motivation: the normal route may be a multi-hop TCP path that cannot actually reach the
peer (e.g. it is on 5G behind carrier NAT); the carrier copy delivers directly without
waiting for delivery-failure demotion (D4) to reroute.

**Known gap:** the call sits on the success path only — if `transport.send` throws, the
carrier copy is never attempted, which is arguably when it is most useful. Applies to
`sendOpportunistic` only; `sendDirect` (link-based) has no equivalent.

## D6 — Database export / import {#d6}

**Commits:** `ce27afc`

**Files:** `Sources/LXMFSwift/Storage/LXMFDatabase.swift`

- The schema migrator was extracted from `init` into `private static func makeMigrator()`
  so it can be reused by the restore path. Behaviour in `init` is unchanged (still
  writer-only).
- `exportDatabase(to:)` — `VACUUM INTO ?` via `writeWithoutTransaction`, producing a single
  consistent file with no WAL/SHM sidecars, safe to take while live. The destination must
  not already exist.
- `importDatabase(from:)` — opens the snapshot as a `DatabaseQueue`, `backup(to: dbPool)`
  copies every page into the live pool (so the on-disk path and all existing connections
  stay valid), then re-runs the migrator to forward-migrate an older snapshot.

**Known gaps:** no `readonly` guard on either call; `backup` uses a plain
`writeWithoutTransaction` rather than a barrier write, so pool readers can observe a torn
intermediate state mid-restore; the exported file carries no explicit iOS file-protection
class; and the router's in-memory state (`pendingOutbound`, `deliveredTransientIDs`) is not
reset after a restore, so callers must reload the router.

## D7 — Repo hygiene {#d7}

**Commits:** `facae56`

**Files:** `.gitignore`

Adds `Derived/*`, `*.xcodeproj`, `*.xcworkspace`. Nothing previously tracked became
ignored — `LXMFSwift.xcodeproj`, `Derived/` and `Package.resolved` are untracked locally.

---

## Re-sync checklist

When pulling new upstream work:

1. `git fetch upstream && git log --oneline HEAD..upstream/main`
2. Re-sync `kishontivf/reticulum-swift` first if upstream moved its reticulum floor ([D1](#d1)).
3. Conflict-prone files, in order of likelihood:
   `Sources/LXMFSwift/Router/LXMRouter.swift` (D3, D4),
   `Sources/LXMFSwift/Router/LXMRouter+Delivery.swift` (D5),
   `Sources/LXMFSwift/Storage/LXMFDatabase.swift` (D6),
   `port-deviations.md` (D3), `Package.swift` (D1).
4. Diff the migration list in `LXMFDatabase.makeMigrator()` against
   [Schema & domain changes](#schema). Upstream numbering ours by collision (two different
   `v7`s) is the failure mode to look for — resolve by renaming ours to a later
   `vN_kvf_…`, never by editing an already-shipped migration.
5. `swift build && swift test`.
6. Update the base/HEAD/last-reviewed lines at the top of this file, append any new
   fork commits to the [commit ledger](#summary), and refresh
   [Status at generation](#status) + add a [Document changelog](#doc-changelog) row.

---

## Status at generation {#status}

**Generated:** 2026-08-02 (all figures below measured on that date, against
`upstream` = `git@github.com:torlando-tech/LXMF-swift.git` after `git fetch upstream`).

| Metric | Value |
|--------|-------|
| Fork HEAD | `e719af4` — 2026-07-14 (19 days old) |
| Upstream base we sit on | `6018671` — 2026-06-20 (**43 days old**) |
| Upstream `main` tip | `6018671` — identical to our base |
| Upstream commits we are missing | **0** — `upstream/main` has not moved since we branched |
| Our commits ahead of upstream | **12** (10 content commits + 2 PR merges) |

So the fork is strictly ahead: nothing to pull, 12 commits to carry. The "43 days old"
figure is the age of upstream's newest work, not a backlog — upstream `main` itself has
been idle since 2026-06-20.

**Unmerged upstream branches** (not on `main`, so not counted above, but they are where the
next re-sync conflict will come from):

| Branch | Ahead of `main` | Tip | Relevance |
|--------|-----------------|-----|-----------|
| `fix/reaction-nested-int-map` | 1 | `aeef5f3` — 2026-07-16 | Touches `LXMessage` pack/unpack of integer-keyed nested field maps; no overlap with our D-sections, but it is newer than our base |
| `chore/use-local-reticulum-swift-path` | 3 | `f953d40` — 2026-04-23 | Points reticulum at a local path + CI workflow — conflicts head-on with [D1](#d1) if ever merged |
| `chore/add-mpl-copyright-notice` | 2 | `c80b033` — 2026-03-23 | Licence headers; touches every source file, so expect broad textual conflicts |

**Ledger date note:** the commit ledger shows **author** dates. `facae56` and `ce27afc`
were authored 2026-05-20 / 2026-05-30 but rebased onto the current base on 2026-06-23
(their committer dates), which is why they read as older than the base they sit on.

## Document changelog {#doc-changelog}

Revisions to *this file*, newest first. One row per edit; the "Covers" column is the fork
HEAD the file described at that point.

| Date | Covers | Change |
|------|--------|--------|
| 2026-08-02 | `e719af4` | Added [Status at generation](#status) and this changelog. |
| 2026-08-02 | `e719af4` | Added commit IDs: `Commits` column in the summary table, the [commit ledger](#summary), per-section `**Commits:**` lines on D1–D7, and a `Commit` column in the schema ledger. |
| 2026-08-02 | `e719af4` | Initial version — D1–D7, [Schema & domain changes](#schema), re-sync checklist. |
