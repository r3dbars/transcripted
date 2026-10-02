// ParakeetConfigChangeAdmission.swift
// Event-time ownership for AUHAL and default-input route callbacks.
//
// A route callback is stamped on the thread that posts it, before any async
// hop, and keeps the native setter token that owned the route at that moment.
// The mailbox drain carries that arrival through to admission, which waits
// only on the setter's remaining native budget and then asks the event-time
// self-induced policy whether the callback is our own echo.
//
// AirPods: nothing here builds an AVAudioEngine or touches `inputNode`. The
// setter wrapper only brackets the caller's existing `setDeviceID` write, so a
// Bluetooth headset as the macOS default input is handled exactly as before:
// the pinned device write either succeeds (its echo is ignored) or fails (the
// callback recovers like any external route change).

import Foundation

/// What an AVAudioEngine configuration callback knew at arrival. Built
/// synchronously in the notification closure (`queue: nil`), never after a
/// MainActor hop.
struct ParakeetConfigChangeArrival {
    let observedAt: CFAbsoluteTime
    let bindingToken: ParakeetAUHALBindingToken?

    static func stamp(
        engineID: ObjectIdentifier,
        bindingIntent: ParakeetAUHALBindingIntent,
        window: TimeInterval,
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) -> ParakeetConfigChangeArrival {
        let observedAt = now()
        let token = bindingIntent.tokenForNotification(engineID: engineID, at: observedAt, window: window)
        return ParakeetConfigChangeArrival(observedAt: observedAt, bindingToken: token)
    }
}

struct ParakeetConfigChangeAdmissionRequest {
    let source: ParakeetConfigChangeSource
    let observedAt: CFAbsoluteTime
    let bindingToken: ParakeetAUHALBindingToken?
    let forceForMicrophoneSharing: Bool
    let ignoreWindowUntil: CFAbsoluteTime
}

enum ParakeetConfigChangeAdmission {
    enum Decision: Equatable {
        case recover
        case ignoreSelfInduced
        /// Lifecycle ownership changed while waiting on the native setter.
        case superseded
    }

    typealias ShouldIgnore = (
        _ source: ParakeetConfigChangeSource,
        _ observedAt: CFAbsoluteTime,
        _ ignoreWindowUntil: CFAbsoluteTime,
        _ windowDuration: TimeInterval,
        _ stableRoute: ParakeetAudioRouteIdentity?,
        _ observedRoute: ParakeetAudioRouteIdentity?,
        _ bindingToken: ParakeetAUHALBindingToken?,
        _ currentEngine: AnyObject,
        _ forceForMicrophoneSharing: Bool
    ) -> Bool

    static func eventTimePolicy(
        source: ParakeetConfigChangeSource,
        observedAt: CFAbsoluteTime,
        ignoreWindowUntil: CFAbsoluteTime,
        windowDuration: TimeInterval,
        stableRoute: ParakeetAudioRouteIdentity?,
        observedRoute: ParakeetAudioRouteIdentity?,
        bindingToken: ParakeetAUHALBindingToken?,
        currentEngine: AnyObject,
        forceForMicrophoneSharing: Bool
    ) -> Bool {
        ParakeetSelfInducedConfigChangePolicy.shouldIgnore(
            source: source,
            observedAt: observedAt,
            ignoreWindowUntil: ignoreWindowUntil,
            windowDuration: windowDuration,
            stableRoute: stableRoute,
            observedRoute: observedRoute,
            bindingToken: bindingToken,
            currentEngine: currentEngine,
            forceForMicrophoneSharing: forceForMicrophoneSharing
        )
    }

    /// `waitForResolution` waits on the setter token's own remaining native
    /// budget. `stillAdmitted` rechecks lifecycle owners after that wait.
    /// The generic window and stable route are read before the wait: a
    /// captured audio-engine token classifies exclusively, so they are only
    /// consulted when no wait happens.
    @MainActor
    static func decide(
        _ request: ParakeetConfigChangeAdmissionRequest,
        observedRoute: ParakeetAudioRouteIdentity?,
        stableRoute: ParakeetAudioRouteIdentity?,
        windowDuration: TimeInterval,
        currentEngine: @MainActor () -> AnyObject,
        waitForResolution: @MainActor (ParakeetAUHALBindingToken) async -> Void,
        stillAdmitted: @MainActor () -> Bool,
        shouldIgnore: ShouldIgnore = eventTimePolicy
    ) async -> Decision {
        if let token = request.bindingToken, request.source == .audioEngine,
           token.engineID == ObjectIdentifier(currentEngine()) {
            await waitForResolution(token)
            guard stillAdmitted() else { return .superseded }
        }
        if shouldIgnore(
            request.source,
            request.observedAt,
            request.ignoreWindowUntil,
            windowDuration,
            stableRoute,
            observedRoute,
            request.bindingToken,
            currentEngine(),
            request.forceForMicrophoneSharing
        ) {
            return .ignoreSelfInduced
        }
        return .recover
    }
}

/// Brackets one native AUHAL `setDeviceID` write with its binding intent, so a
/// configuration callback that arrives mid-write is owned by this command and
/// only trusted once the write has returned successfully.
enum ParakeetInputBindingWrite {
    static func perform(
        intent: ParakeetAUHALBindingIntent,
        engine: AnyObject,
        route: ParakeetAudioRouteIdentity,
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
        write: () throws -> Void
    ) rethrows {
        let token = intent.begin(engine: engine, route: route, at: now())
        do {
            try write()
            token.finish(succeeded: true)
        } catch {
            token.finish(succeeded: false)
            throw error
        }
    }
}
