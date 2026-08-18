import Foundation
import CoreGraphics

enum Diagnostics {
    static func selfTest() -> [String: Any] {
        let pid: pid_t = 4_242
        func fixture(id: UInt32, name: String, width: Double, height: Double) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowOwnerName as String: WindowFinder.ownerName,
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: id,
                kCGWindowName as String: name,
                kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": width, "Height": height],
            ]
        }
        let fixtures = [
            fixture(id: 1, name: "Welcome to iPhone Mirroring", width: 640, height: 658),
            fixture(id: 2, name: "", width: 1_920, height: 37),
            fixture(id: 3, name: "iPhone Mirroring", width: 313, height: 689),
        ]
        let selected = WindowFinder.selectPhoneWindow(from: fixtures, pid: pid, appName: "iPhone Mirroring")
        let sample = CGPoint(x: -1_100, y: 350)
        let roundTrip = WindowFinder.warpPoint(fromAppKit: WindowFinder.appKitPoint(fromWarp: sample))
        let selectionPassed = selected?.windowId == 3
        let coordinatesPassed = hypot(roundTrip.x - sample.x, roundTrip.y - sample.y) < 0.001
        let cliclickCoordinatesPassed = Input.cliclickCoordinate(-1_074) == "=-1074"
            && Input.cliclickCoordinate(846) == "846"
        let edgePoint = Input.cliclickPoint(
            CGPoint(x: -761, y: 1_806),
            in: MirrorWindow(
                pid: pid,
                windowId: 4,
                x: -1_074,
                y: 1_117,
                width: 313,
                height: 689,
                ownerName: WindowFinder.ownerName,
                windowName: WindowFinder.ownerName,
                layer: 0
            )
        )
        let cliclickEdgesPassed = edgePoint == (-762, 1_805)
        let tapArguments = Input.cliclickTapArguments(x: -762, y: 1_805)
        let explicitTapTargetPassed = tapArguments == ["c:=-762,1805"]
        let pointerGuardPassed = Input.pointerRemainsAtTarget(
            CGPoint(x: 100, y: 100),
            target: CGPoint(x: 104, y: 104)
        ) && !Input.pointerRemainsAtTarget(
            CGPoint(x: 120, y: 100),
            target: CGPoint(x: 100, y: 100)
        )
        let midScrollAbortPassed = Input.globalInputBlockReason(
            frontmost: true,
            currentPointer: CGPoint(x: 100, y: 100),
            target: CGPoint(x: 100, y: 100)
        ) == nil && Input.globalInputBlockReason(
            frontmost: true,
            currentPointer: CGPoint(x: 140, y: 100),
            target: CGPoint(x: 100, y: 100)
        ) == "user pointer movement detected" && Input.globalInputBlockReason(
            frontmost: false,
            currentPointer: CGPoint(x: 100, y: 100),
            target: CGPoint(x: 100, y: 100)
        ) == "iPhone Mirroring is no longer frontmost"
        var rejectedNativeCalls = 0
        var rejectedFallbackCalls = 0
        let activationRejected = !Input.confirmFrontmostActivation(
            pid: pid,
            nativeGraceAttempts: 2,
            fallbackAttempts: 2,
            nativeActivate: {
                rejectedNativeCalls += 1
                return false
            },
            fallbackActivate: {
                rejectedFallbackCalls += 1
                return false
            },
            frontmostPID: { pid + 1 },
            pause: {}
        )
        let activationGatePassed = activationRejected
            && rejectedNativeCalls == 1 && rejectedFallbackCalls == 1
        var nativePhase = 0
        var nativeFallbackCalls = 0
        let nativeActivationAccepted = Input.confirmFrontmostActivation(
            pid: pid,
            nativeGraceAttempts: 2,
            fallbackAttempts: 2,
            nativeActivate: {
                nativePhase = 1
                return true
            },
            fallbackActivate: {
                nativeFallbackCalls += 1
                return true
            },
            frontmostPID: { nativePhase == 1 ? pid : pid + 1 },
            pause: {}
        )
        let nativeActivationGracePassed = nativeActivationAccepted && nativeFallbackCalls == 0
        var fallbackPhase = 0
        var fallbackCalls = 0
        let fallbackActivationAccepted = Input.confirmFrontmostActivation(
            pid: pid,
            nativeGraceAttempts: 2,
            fallbackAttempts: 2,
            nativeActivate: { false },
            fallbackActivate: {
                fallbackCalls += 1
                fallbackPhase = 1
                return true
            },
            frontmostPID: { fallbackPhase == 1 ? pid : pid + 1 },
            pause: {}
        )
        let activationRetryPassed = fallbackActivationAccepted && fallbackCalls == 1
        let activationScriptScopePassed = Input.activationScriptArguments() == [
            "-e",
            "tell application id \"com.apple.ScreenContinuity\" to activate",
        ]
        let typingFixture = String(repeating: "a", count: 260) + "🙂"
        let typingChunks = Input.textChunks(typingFixture, maximumCharacters: 128)
        let typingChunkingPassed = typingChunks.count == 3
            && typingChunks.allSatisfy { $0.count <= 128 }
            && typingChunks.joined() == typingFixture
        let dependencyPreflightPassed = MirrorCtl.requiresCliclick("open-app")
            && MirrorCtl.requiresCliclick("tap-label-and-capture")
            && !MirrorCtl.requiresCliclick("menu")
        let reusableOCRMatches: [[String: Any]] = [
            ["text": "Continue", "cx": 0.5, "cy": 0.72, "confidence": 0.98],
            ["text": "Cancel", "cx": 0.5, "cy": 0.88, "confidence": 0.99],
        ]
        let reusedOCR = OCR.search(
            matches: reusableOCRMatches,
            query: "continue",
            x0: 0.2,
            y0: 0.6,
            x1: 0.8,
            y1: 0.8,
            limit: 8
        )
        let ocrObservationReusePassed = reusedOCR["found"] as? Bool == true
            && reusedOCR["text"] as? String == "Continue"
            && reusedOCR["matches"] as? [[String: Any]] != nil
        func solidSignature(_ rgb: String) -> String {
            "rgb16:" + String(repeating: rgb, count: VisualComparison.sampleSize * VisualComparison.sampleSize)
        }
        let baselineObservation = VisualObservation(
            signature: solidSignature("000000"),
            structuralHash: "0000000000000000"
        )
        let transientObservation = VisualObservation(
            signature: solidSignature("ffffff"),
            structuralHash: "ffffffffffffffff"
        )
        let finalObservation = VisualObservation(
            signature: solidSignature("ff0000"),
            structuralHash: "aaaaaaaaaaaaaaaa"
        )
        let animatedObservation = VisualObservation(
            signature: solidSignature("0000ff"),
            structuralHash: "5555555555555555"
        )
        var transitionTracker = SettlementTracker(
            preflight: baselineObservation,
            maximumSettleMs: 1_000
        )
        let transientDecision = try? transitionTracker.observe(transientObservation, elapsedMs: 100)
        let movingDecision = try? transitionTracker.observe(finalObservation, elapsedMs: 260)
        let settledDecision = try? transitionTracker.observe(finalObservation, elapsedMs: 450)

        var delayedTracker = SettlementTracker(preflight: baselineObservation, maximumSettleMs: 1_200)
        let delayedInitial = try? delayedTracker.observe(baselineObservation, elapsedMs: 200)
        let delayedChange = try? delayedTracker.observe(finalObservation, elapsedMs: 700)
        let delayedSettled = try? delayedTracker.observe(finalObservation, elapsedMs: 900)

        var localizedBytes = [UInt8](repeating: 0, count: 16 * 16 * 3)
        localizedBytes[0] = 255
        localizedBytes[1] = 255
        localizedBytes[2] = 255
        let localizedObservation = VisualObservation(
            signature: "rgb16:" + localizedBytes.map { String(format: "%02x", $0) }.joined(),
            structuralHash: "000000000000ffff"
        )
        var localizedTracker = SettlementTracker(preflight: baselineObservation, maximumSettleMs: 1_000)
        let localizedDecision = try? localizedTracker.observe(localizedObservation, elapsedMs: 100)

        var unchangedTracker = SettlementTracker(preflight: baselineObservation, maximumSettleMs: 300)
        let unchangedDecision = try? unchangedTracker.observe(baselineObservation, elapsedMs: 300)

        var animatedTracker = SettlementTracker(preflight: baselineObservation, maximumSettleMs: 500)
        _ = try? animatedTracker.observe(transientObservation, elapsedMs: 100)
        _ = try? animatedTracker.observe(finalObservation, elapsedMs: 300)
        let animatedDecision = try? animatedTracker.observe(animatedObservation, elapsedMs: 500)

        let adaptiveSettlementPassed = transientDecision?.shouldFinish == false
            && movingDecision?.shouldFinish == false
            && settledDecision?.screenStable == true
            && settledDecision?.state == "settled"
            && delayedInitial?.transitionObserved == false
            && delayedChange?.screenStable == false
            && delayedSettled?.screenStable == true
            && localizedDecision?.transitionObserved == true
            && (localizedDecision?.visualDistanceFromPreflight ?? 10) < 2
            && localizedDecision?.structuralHashDistanceFromPreflight == 16
            && unchangedDecision?.state == "no-change-timeout"
            && unchangedDecision?.screenChanged == false
            && animatedDecision?.state == "changed-timeout"
            && animatedDecision?.screenStable == false
        let parserPassed: Bool
        do {
            let parsed = try MirrorCtl.parseFlags(
                ["--query", "--definitely-not-text", "--limit", "8"],
                allowed: ["query", "limit"]
            )
            parserPassed = parsed["query"] == "--definitely-not-text" && parsed["limit"] == "8"
        } catch {
            parserPassed = false
        }
        let parserRejectsInvalid: Bool
        do {
            _ = try MirrorCtl.parseFlags(["--query", "one", "--query", "two"], allowed: ["query"])
            parserRejectsInvalid = false
        } catch {
            parserRejectsInvalid = true
        }
        let blackSignature = solidSignature("000000")
        let whiteSignature = solidSignature("ffffff")
        let redSignature = solidSignature("ff0000")
        let blueSignature = solidSignature("0000ff")
        var noiseBytes = [UInt8](repeating: 0, count: 16 * 16 * 3)
        noiseBytes[0] = 1
        let noiseObservation = VisualObservation(
            signature: "rgb16:" + noiseBytes.map { String(format: "%02x", $0) }.joined(),
            structuralHash: "0000000000000001"
        )
        let visualComparisonPassed = (try? VisualComparison.distance(blackSignature, whiteSignature)) == 255
            && ((try? VisualComparison.distance(redSignature, blueSignature)) ?? 0)
                > VisualComparison.materialDifferenceThreshold
            && (try? VisualComparison.structuralDistance(
                baselineObservation.structuralHash,
                localizedObservation.structuralHash
            )) == 16
            && (try? VisualComparison.materiallyDifferent(baselineObservation, localizedObservation)) == true
            && (try? VisualComparison.materiallyDifferent(baselineObservation, noiseObservation)) == false
        let spotlightMatches: [[String: Any]] = [
            ["text": "Settings", "cx": 0.5, "cy": 0.06, "confidence": 0.99],
            ["text": "Settings", "cx": 0.25, "cy": 0.24, "confidence": 0.95],
        ]
        let spotlightSelectionPassed = (MirrorCtl.selectSpotlightResult(
            spotlightMatches,
            appName: "Settings"
        )?["cy"] as? Double) == 0.24
        let spotlightEntryPassed = MirrorCtl.isSpotlightEntryVisible([
            ["text": "Siri Suggestions"],
            ["text": "Show Less"],
            ["text": "Search"],
        ]) && !MirrorCtl.isSpotlightEntryVisible([["text": "Search"]])
        let initialWindow = MirrorWindow(
            pid: pid,
            windowId: 9,
            x: 100,
            y: 200,
            width: 300,
            height: 652,
            ownerName: WindowFinder.ownerName,
            windowName: WindowFinder.ownerName,
            layer: 0
        )
        var movedWindow = initialWindow
        movedWindow.x = -500
        movedWindow.y = 450
        let initialPoint = try? Input.normalizedPoint(x: 0.5, y: 0.5, in: initialWindow)
        let movedPoint = try? Input.normalizedPoint(x: 0.5, y: 0.5, in: movedWindow)
        let normalizedRemapPassed = initialPoint?.x == 250
            && movedPoint?.x == -350
            && movedPoint?.y == 802
        var replacementWindow = movedWindow
        replacementWindow.windowId = 10
        let preparedWindowIdentityPassed = Input.preparedWindowIsCurrent(
            initialWindow,
            current: movedWindow
        ) && !Input.preparedWindowIsCurrent(
            initialWindow,
            current: replacementWindow
        )
        let timeoutIsolationPassed = Capture.timeoutIsolationSelfTest()
        let windowCaptureArguments = Capture.screencaptureArguments(
            windowId: 77,
            output: URL(fileURLWithPath: "/tmp/iphone-mirror-self-test.png")
        )
        let windowCaptureFallbackPassed = windowCaptureArguments.contains("-l77")
            && windowCaptureArguments.contains("-o")
            && !windowCaptureArguments.contains("-R")
        let hostBlockerPassed = ScreenPrecondition.blockedReason(from: [
            ["text": "Connection Paused"],
            ["text": "Resume"],
        ]) == "connection_paused"
        let hostBlockerFallbackTriggerPassed = ScreenPrecondition.needsAccurateBlockerVerification(from: [
            ["text": "ConnectbJn"],
        ]) && !ScreenPrecondition.needsAccurateBlockerVerification(from: [
            ["text": "Settings"],
            ["text": "General"],
            ["text": "Clock"],
        ])
        return [
            "ok": selectionPassed && coordinatesPassed
                && cliclickCoordinatesPassed && cliclickEdgesPassed && explicitTapTargetPassed
                && pointerGuardPassed && midScrollAbortPassed && activationGatePassed
                && nativeActivationGracePassed && activationRetryPassed
                && activationScriptScopePassed
                && typingChunkingPassed && dependencyPreflightPassed && ocrObservationReusePassed
                && adaptiveSettlementPassed
                && parserPassed && parserRejectsInvalid && visualComparisonPassed
                && spotlightSelectionPassed && spotlightEntryPassed
                && normalizedRemapPassed && preparedWindowIdentityPassed
                && timeoutIsolationPassed && windowCaptureFallbackPassed
                && hostBlockerPassed && hostBlockerFallbackTriggerPassed,
            "windowSelection": selectionPassed,
            "coordinateRoundTrip": coordinatesPassed,
            "cliclickNegativeCoordinates": cliclickCoordinatesPassed,
            "cliclickHalfOpenEdges": cliclickEdgesPassed,
            "cliclickExplicitTarget": explicitTapTargetPassed,
            "midActionPointerGuard": pointerGuardPassed,
            "midScrollAbort": midScrollAbortPassed,
            "activationGate": activationGatePassed,
            "activationNativeGrace": nativeActivationGracePassed,
            "activationRetry": activationRetryPassed,
            "activationScriptScope": activationScriptScopePassed,
            "typingChunking": typingChunkingPassed,
            "dependencyPreflight": dependencyPreflightPassed,
            "ocrObservationReuse": ocrObservationReusePassed,
            "adaptiveSettlement": adaptiveSettlementPassed,
            "argumentParser": parserPassed,
            "argumentParserRejectsInvalid": parserRejectsInvalid,
            "visualComparison": visualComparisonPassed,
            "spotlightResultSelection": spotlightSelectionPassed,
            "spotlightEntryDetection": spotlightEntryPassed,
            "normalizedWindowRemap": normalizedRemapPassed,
            "preparedWindowIdentity": preparedWindowIdentityPassed,
            "captureTimeoutIsolation": timeoutIsolationPassed,
            "windowOnlyCaptureFallback": windowCaptureFallbackPassed,
            "hostBlockerDetection": hostBlockerPassed,
            "hostBlockerFallbackTrigger": hostBlockerFallbackTriggerPassed,
            "selectedWindowId": selected.map { Int($0.windowId) } ?? -1,
        ]
    }

    static func status() -> [String: Any] {
        let trusted = WindowFinder.accessibilityTrusted(prompt: false)
        guard WindowFinder.app() != nil else {
            return [
                "ok": true,
                "running": false,
                "windowVisible": false,
                "connected": false,
                "accessibilityTrusted": trusted,
                "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                "bundleId": WindowFinder.bundleId,
            ]
        }
        do {
            return windowStatus(try WindowFinder.find(), trusted: trusted)
        } catch {
            return [
                "ok": true,
                "running": true,
                "windowVisible": false,
                "connected": false,
                "accessibilityTrusted": trusted,
                "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                "bundleId": WindowFinder.bundleId,
                "warning": String(describing: error),
            ]
        }
    }

    static func doctor() -> [String: Any] {
        let status = status()
        let accessibility = status["accessibilityTrusted"] as? Bool ?? false
        let screenCapture = status["screenCaptureAllowed"] as? Bool ?? false
        let visible = status["windowVisible"] as? Bool ?? false
        var warnings: [String] = []
        var notes: [String] = []
        if !accessibility {
            warnings.append("Accessibility permission is not granted to the MCP client")
        }
        if !screenCapture {
            warnings.append("Screen Recording permission is not granted to the responsible client process")
        }
        if WindowFinder.app() == nil {
            warnings.append("iPhone Mirroring is not running")
        } else if !visible {
            warnings.append("The phone window is not visible on the current macOS Space")
        }
        if Dependencies.cliclickPath() == nil {
            warnings.append("cliclick is unavailable; reliable taps, scrolling, and typing are disabled")
        }
        if MirrorMetrics.configuredTitlebarPoints == nil {
            notes.append("Using the tested default 52-point title bar; set MIRROR_TITLEBAR_PT only if calibration is visibly wrong")
        }

        return [
            "ok": true,
            "healthy": warnings.isEmpty,
            "status": status,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "displays": WindowFinder.displays().map(\.json),
            "cliclickPath": Dependencies.cliclickPath() ?? NSNull(),
            "titlebarPoints": MirrorMetrics.titlebarPoints,
            "titlebarSource": MirrorMetrics.titlebarSource,
            "notes": notes,
            "warnings": warnings,
        ]
    }

    private static func windowStatus(_ window: MirrorWindow, trusted: Bool) -> [String: Any] {
        let content = WindowFinder.contentRect(window)
        let display = WindowFinder.display(for: window)
        let longSide = max(window.width, window.height)
        let shortSide = min(window.width, window.height)
        let phoneLike = longSide / max(1, shortSide) >= 1.25
        return [
            "ok": true,
            "running": true,
            "windowVisible": true,
            "connected": phoneLike,
            "connectedHeuristic": phoneLike,
            "connectionEvidence": "window-geometry-only",
            "pid": window.pid,
            "windowId": window.windowId,
            "x": window.x,
            "y": window.y,
            "width": window.width,
            "height": window.height,
            "contentX": content.origin.x,
            "contentY": content.origin.y,
            "contentWidth": content.width,
            "contentHeight": content.height,
            "ownerName": window.ownerName,
            "windowName": window.windowName,
            "displayId": display.map { Int($0.id) } ?? -1,
            "displayScale": display?.scale ?? -1,
            "titlebar": MirrorMetrics.titlebarPoints,
            "titlebarSource": MirrorMetrics.titlebarSource,
            "accessibilityTrusted": trusted,
            "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
            "bundleId": WindowFinder.bundleId,
        ]
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
