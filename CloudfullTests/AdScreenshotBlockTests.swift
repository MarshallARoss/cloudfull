//
//  AdScreenshotBlockTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// A stand-in for the vendor class: a Bool flag with a setter that records each call.
class FlagHolder: NSObject {
    var stored = false
    var setterCalls = 0
    @objc dynamic func setFlag(_ value: Bool) { stored = value; setterCalls += 1 }
    @objc dynamic func flag() -> Bool { stored }
}
final class FlagHolderForInstall: FlagHolder {}
final class FlagHolderForTwice: FlagHolder {}
final class FlagHolderNoGetter: NSObject {
    @objc dynamic func setFlag(_ value: Bool) {}
}
final class FlagHolderWrongType: NSObject {
    @objc dynamic func setFlag(_ value: Int) {}
    @objc dynamic func flag() -> Bool { false }
}

/// The guard that keeps TikTok's server from turning its screenshot switch on, and the rule that
/// TikTok does not start without it.
@Suite("AdScreenshotBlockTests")
@MainActor
struct AdScreenshotBlockTests {
    private let setter = NSSelectorFromString("setFlag:")
    private let getter = NSSelectorFromString("flag")
    private let keys = AdKeys(metaAppID: nil, metaClientToken: nil, tiktokAppID: "2", tiktokAccessToken: "a",
                              hasFirebaseConfig: false, tiktokAppleAppID: "3")

    @Test("After install, setting true leaves false; other classes are not changed")
    func installForcesFalse() {
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderForInstall.self, setter: setter, getter: getter))
        let guarded = FlagHolderForInstall()
        guarded.setValue(true, forKey: "flag")
        #expect(guarded.flag() == false)
        #expect(guarded.setterCalls == 1)
        // The base class, which the guard did not touch, still stores true.
        let plain = FlagHolder()
        plain.setValue(true, forKey: "flag")
        #expect(plain.flag() == true)
    }

    @Test("A second install does not stack: the original setter runs once per call")
    func secondInstallDoesNotStack() {
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderForTwice.self, setter: setter, getter: getter))
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderForTwice.self, setter: setter, getter: getter))
        let guarded = FlagHolderForTwice()
        guarded.setValue(true, forKey: "flag")
        #expect(guarded.flag() == false)
        #expect(guarded.setterCalls == 1)
    }

    @Test("A missing selector, or a setter that is not void set(BOOL), is not installed")
    func notInstalled() {
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderNoGetter.self, setter: setter, getter: getter) == false)
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderForInstall.self, setter: NSSelectorFromString("setNothing:"),
                                                    getter: getter) == false)
        #expect(BoolSetterGuard.installForcingFalse(on: FlagHolderWrongType.self, setter: setter, getter: getter) == false)
    }

    @Test("TikTok does not start when the screenshot block is not installed")
    func sinkFailsClosed() {
        let log = AdEventsTests.TikTokHookLog()
        var hooks = log.hooks
        hooks.blockScreenshots = { false }
        let sink = TikTokAdSink(hooks: hooks)
        sink.start(keys: keys)
        sink.send(.paywallShown)
        #expect(log.calls.isEmpty)
        #expect(log.tracked.isEmpty)
    }

    @Test("TikTok starts when the screenshot block is installed")
    func sinkStartsWhenBlocked() {
        let log = AdEventsTests.TikTokHookLog()
        var hooks = log.hooks
        hooks.blockScreenshots = { true }
        let sink = TikTokAdSink(hooks: hooks)
        sink.start(keys: keys)
        sink.send(.paywallShown)
        #expect(log.calls == ["initialize"])
        #expect(log.tracked.map(\.0) == ["ViewContent"])
    }
}
