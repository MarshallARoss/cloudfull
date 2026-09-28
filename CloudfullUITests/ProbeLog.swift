//
//  ProbeLog.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Prints `## PROBE name=value` for an external test script to read
/// from the log.
///
/// Pass the same variable that the next assertion checks, read at the
/// same time. The log then records a real measurement, not only a pass
/// or fail result.
enum ProbeLog {
    static func emit(_ name: String, _ value: Any) { print("## PROBE \(name)=\(value)") }
}
