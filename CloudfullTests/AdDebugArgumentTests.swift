//
//  AdDebugArgumentTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// Which launch arguments put TikTok in test mode (Debug builds only).
@Suite("AdDebugArgumentTests")
struct AdDebugArgumentTests {
    private let debug = AdEvents.debugArgument
    private let real = AdEvents.realPipelineArgument

    @Test("TikTok test mode: no arguments off; debug on; debug with real pipeline off; real pipeline alone off")
    func decisionTable() {
        #expect(AdEvents.tiktokTestModeRequested(arguments: []) == false)
        #expect(AdEvents.tiktokTestModeRequested(arguments: [debug]) == true)
        #expect(AdEvents.tiktokTestModeRequested(arguments: [debug, real]) == false)
        #expect(AdEvents.tiktokTestModeRequested(arguments: [real, debug]) == false)
        #expect(AdEvents.tiktokTestModeRequested(arguments: [real]) == false)
    }
}
