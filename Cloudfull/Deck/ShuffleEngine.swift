//
//  ShuffleEngine.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// SplitMix64 pseudo-random number generator. The same seed always produces
/// the same output sequence, so this type can produce a repeatable shuffle
/// order.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum ShuffleEngine {
    /// Returns a deterministic permutation of `ids` for the given seed.
    /// Uses a Fisher-Yates shuffle driven by SplitMix64.
    static func permutation(of ids: [String], seed: UInt64) -> [String] {
        var result = ids
        guard result.count > 1 else { return result }

        var rng = SplitMix64(seed: seed)
        // Fisher-Yates shuffle: start at the last index and go down to 1.
        // Swap each element with a random element at or before its own
        // position.
        var index = result.count - 1
        while index > 0 {
            let j = Int(rng.next() % UInt64(index + 1))
            if j != index {
                result.swapAt(index, j)
            }
            index -= 1
        }
        return result
    }

    /// FNV-1a 64 hash of the ids joined by newlines, as 16 lowercase hex
    /// characters. The hash is stable across launches and device
    /// architectures.
    ///
    /// The hash does not need to be cryptographic. It detects a changed
    /// id list before a stored order is reused, and a collision costs a
    /// deck rebuild, never a wrong deletion.
    static func digest(of ids: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var isFirst = true
        for id in ids {
            if !isFirst {
                hash = (hash ^ 0x0A) &* prime
            }
            isFirst = false
            for byte in id.utf8 {
                hash = (hash ^ UInt64(byte)) &* prime
            }
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Moves recently watched videos out of the first `gap` slots of a
    /// new cycle. This avoids repeating a video the user just watched at
    /// the end of the previous cycle.
    ///
    /// The engine shuffles each cycle separately. Without this
    /// adjustment, the point where two cycles meet can place the same
    /// video two slots apart. The user reads that placement as a repeat,
    /// but each cycle is still complete on its own.
    ///
    /// A gap of a whole library is not achievable. Forcing every window of
    /// N consecutive slots to hold N distinct videos would require every
    /// cycle to use the same permutation. A gap of half a library is
    /// achievable, and it stops the repeat from being noticeable.
    ///
    /// Returns the swaps it made. The caller can persist and replay the
    /// rearrangement at launch, instead of deriving it again from a cycle
    /// that no longer exists in memory.
    static func openingWithoutRecentRepeat(
        _ cycle: [String],
        avoiding recent: Set<String>,
        gap: Int
    ) -> (cycle: [String], swaps: [(Int, Int)]) {
        var result = cycle
        // `gap` is 0 only for a library of one video. Every page then shows
        // that one video, so no spacing exists to arrange.
        // Returning the cycle untouched is correct in that case, not a
        // disabled guard.
        // The clamp is defensive only. Every caller passes
        // `min(deck.count, count / 2)`.
        let bound = min(gap, result.count)
        guard bound > 0 else { return (result, []) }

        var swaps: [(Int, Int)] = []
        for slot in 0..<bound where recent.contains(result[slot]) {
            // Swap in the first later video that was not shown recently.
            // The cycle holds at least `gap` such videos. Each swap moves a
            // recently shown video past `gap`, so a free candidate always
            // remains.
            guard let donor = (bound..<result.count).first(where: { !recent.contains(result[$0]) }) else { break }
            result.swapAt(slot, donor)
            swaps.append((slot, donor))
        }
        return (result, swaps)
    }

    /// Replays a recorded rearrangement onto a freshly permuted array.
    ///
    /// The method skips a swap with an index outside the array. The swap
    /// list comes from storage, so a corrupt list must cause a deck
    /// rebuild, not a crash.
    static func applySwaps(_ swaps: [(Int, Int)], to cycle: inout [String]) {
        for (a, b) in swaps where cycle.indices.contains(a) && cycle.indices.contains(b) {
            cycle.swapAt(a, b)
        }
    }
}
