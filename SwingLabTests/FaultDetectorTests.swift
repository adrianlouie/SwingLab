import XCTest
@testable import SwingLab

/// Faults are the app's diagnoses, so the important properties are that a clean
/// swing produces none, each fault fires on the pattern it names, and the
/// golfer's shot tag re-ranks findings without inventing them.
final class FaultDetectorTests: XCTestCase {

    private func joint(_ x: Double, _ y: Double, _ c: Double = 0.9) -> JointPoint {
        JointPoint(x: x, y: y, confidence: c)
    }

    /// A neutral pose; the modifiers below shift individual parts of it.
    private func pose(hipX: Double = 0.5,
                      neckX: Double = 0.5,
                      neckY: Double = 0.80,
                      handsX: Double = 0.5,
                      handsY: Double = 0.46,
                      headX: Double = 0.52,
                      time: Double = 0) -> PoseFrame {
        PoseFrame(time: time, joints: [
            .nose: joint(headX, 0.88),
            .leftEar: joint(headX - 0.02, 0.885),
            .rightEar: joint(headX + 0.02, 0.885),
            .neck: joint(neckX, neckY),
            .leftShoulder: joint(neckX - 0.07, neckY - 0.02),
            .rightShoulder: joint(neckX + 0.07, neckY - 0.02),
            .leftElbow: joint(neckX - 0.06, 0.62),
            .rightElbow: joint(neckX + 0.06, 0.62),
            .leftWrist: joint(handsX - 0.015, handsY),
            .rightWrist: joint(handsX + 0.015, handsY),
            .root: joint(hipX, 0.50),
            .leftHip: joint(hipX - 0.05, 0.50),
            .rightHip: joint(hipX + 0.05, 0.50),
            .leftKnee: joint(hipX - 0.05, 0.27),
            .rightKnee: joint(hipX + 0.05, 0.27),
            .leftAnkle: joint(hipX - 0.05, 0.04),
            .rightAnkle: joint(hipX + 0.05, 0.04),
        ])
    }

    private func context(address: PoseFrame, top: PoseFrame, impact: PoseFrame,
                         frameRate: Double = 120, view: CameraViewType = .faceOn) -> FaultDetector.Context {
        let frames = [address, top, impact]
        return FaultDetector.Context(
            frames: frames,
            positions: [
                DetectedPosition(position: .address, frameIndex: 0, time: 0),
                DetectedPosition(position: .top, frameIndex: 1, time: 1),
                DetectedPosition(position: .impact, frameIndex: 2, time: 1.4),
            ],
            space: .square,
            handedness: .right,
            view: view,
            frameRate: frameRate,
            ballOverride: nil)
    }

    // MARK: - A clean swing

    func testACleanSwingProducesNoFaults() {
        let neutral = pose()
        let faults = FaultDetector.detect(context: context(address: neutral, top: neutral, impact: neutral))
        XCTAssertTrue(faults.isEmpty, "Found \(faults.map(\.kind.rawValue)) on a swing with nothing wrong")
    }

    // MARK: - Individual patterns

    /// Right-handed, face-on: the target is to the viewer's right, so hips
    /// moving left during the backswing is a sway away from it.
    func testSwayFiresWhenHipsMoveAwayFromTargetGoingBack() {
        let address = pose(hipX: 0.50)
        let top = pose(hipX: 0.44)          // ~4.8" away from target
        let faults = FaultDetector.detect(context: context(address: address, top: top, impact: address))
        XCTAssertTrue(faults.contains { $0.kind == .sway })
    }

    func testSwayDoesNotFireForNormalRotation() {
        let address = pose(hipX: 0.50)
        let top = pose(hipX: 0.492)         // under an inch
        let faults = FaultDetector.detect(context: context(address: address, top: top, impact: address))
        XCTAssertFalse(faults.contains { $0.kind == .sway })
    }

    func testEarlyExtensionFiresWhenTheSpineStandsUp() {
        // Address is bent over (neck forward of the hips); impact is upright.
        let address = pose(neckX: 0.62)
        let impact = pose(neckX: 0.52)
        let faults = FaultDetector.detect(context: context(address: address, top: address, impact: impact))
        XCTAssertTrue(faults.contains { $0.kind == .earlyExtension })
    }

    func testBodyRiseAndBodyDropAreDistinguished() {
        let address = pose(neckY: 0.80)
        let higher = pose(neckY: 0.845)
        let lower = pose(neckY: 0.755)

        let rising = FaultDetector.detect(context: context(address: address, top: address, impact: higher))
        XCTAssertTrue(rising.contains { $0.kind == .bodyRise })
        XCTAssertFalse(rising.contains { $0.kind == .bodyDrop })

        let dropping = FaultDetector.detect(context: context(address: address, top: address, impact: lower))
        XCTAssertTrue(dropping.contains { $0.kind == .bodyDrop })
        XCTAssertFalse(dropping.contains { $0.kind == .bodyRise })
    }

    func testHangBackFiresWhenHipsAreStillBehindAtImpact() {
        let address = pose(hipX: 0.50)
        let impact = pose(hipX: 0.46)
        let faults = FaultDetector.detect(context: context(address: address, top: address, impact: impact))
        XCTAssertTrue(faults.contains { $0.kind == .hangBack })
    }

    func testSeverityRisesWithTheAmountOfMovement() {
        func severity(hipX: Double) -> FaultSeverity? {
            let faults = FaultDetector.detect(
                context: context(address: pose(hipX: 0.50), top: pose(hipX: hipX), impact: pose(hipX: 0.50)))
            return faults.first { $0.kind == .sway }?.severity
        }
        XCTAssertEqual(severity(hipX: 0.475), .slight)
        XCTAssertEqual(severity(hipX: 0.42), .clear)
    }

    // MARK: - Contact tendencies

    func testFatTendencyEmergesFromHangingBackAndDropping() {
        let address = pose(hipX: 0.50, neckY: 0.80)
        let impact = pose(hipX: 0.45, neckY: 0.745)   // behind the ball and dipping
        let faults = FaultDetector.detect(context: context(address: address, top: address, impact: impact))
        XCTAssertTrue(faults.contains { $0.kind == .fatTendency })
        XCTAssertFalse(faults.contains { $0.kind == .thinTendency })
    }

    func testThinTendencyEmergesFromStandingUp() {
        let address = pose(neckX: 0.62, neckY: 0.80)
        let impact = pose(neckX: 0.50, neckY: 0.85)   // extended and taller
        let faults = FaultDetector.detect(context: context(address: address, top: address, impact: impact))
        XCTAssertTrue(faults.contains { $0.kind == .thinTendency })
    }

    /// Contact patterns are inferences, and must never be presented with the
    /// confidence of a direct measurement.
    func testContactTendenciesAreMarkedAndLowConfidence() {
        let address = pose(hipX: 0.50, neckY: 0.80)
        let impact = pose(hipX: 0.45, neckY: 0.745)
        let faults = FaultDetector.detect(context: context(address: address, top: address, impact: impact))
        guard let fat = faults.first(where: { $0.kind == .fatTendency }) else {
            return XCTFail("expected a fat tendency")
        }
        XCTAssertTrue(fat.kind.isTendency)
        XCTAssertLessThanOrEqual(fat.confidence, 0.6)
    }

    /// Direct regression test for the bug that motivated renormalizing the
    /// tendency scores: down-the-line + 30fps disables two of fat's three
    /// contributors (hang-back needs a target direction the DTL camera can't
    /// see; casting needs 60fps). With the OLD fixed weights, body-drop's
    /// 0.35 share could never reach the 0.5 firing threshold on its own —
    /// fat tendency was arithmetically incapable of firing in this
    /// combination no matter how severe the drop. Renormalizing over just
    /// the evaluable contributor fixes that.
    func testFatTendencyCanFireDownTheLineAt30fpsFromBodyDropAlone() {
        let address = pose(neckY: 0.80)
        let severelyDropping = pose(neckY: 0.72)   // well past the -0.10 severe cutoff
        let faults = FaultDetector.detect(context: context(address: address, top: address,
                                                            impact: severelyDropping,
                                                            frameRate: 30, view: .downTheLine))
        XCTAssertTrue(faults.contains { $0.kind == .fatTendency },
                      "A severe, honestly-measured body drop should be enough evidence on its own")
    }

    /// A genuinely clean hang-back reading (measured, nothing wrong) must
    /// still count in the denominator — it's real evidence diluting the
    /// case for fat contact, unlike a not-applicable contributor, which
    /// drops out entirely. This is the other half of the tri-state design:
    /// "clean" and "not applicable" have to pull the score in different
    /// directions, or there'd be no reason to distinguish them at all.
    func testACleanReadingDilutesTheScoreDifferentlyThanANotApplicableOne() {
        // Face-on: hang-back is measurable and reads clean (hips didn't
        // move), so its zero contributes at full weight alongside a severe
        // body-drop — a mixed, weaker case than body-drop alone.
        let faceOn = context(address: pose(hipX: 0.50, neckY: 0.80), top: pose(hipX: 0.50, neckY: 0.80),
                             impact: pose(hipX: 0.50, neckY: 0.72), frameRate: 30, view: .faceOn)
        // Down-the-line: hang-back can't be measured at all, so it drops out
        // of the average entirely rather than counting as "clean."
        let downTheLine = FaultDetector.Context(
            frames: faceOn.frames, positions: faceOn.positions, space: .square,
            handedness: .right, view: .downTheLine, frameRate: 30, ballOverride: nil)

        let faceOnFires = FaultDetector.detect(context: faceOn).contains { $0.kind == .fatTendency }
        let dtlFires = FaultDetector.detect(context: downTheLine).contains { $0.kind == .fatTendency }
        XCTAssertFalse(faceOnFires, "A clean hang-back reading should genuinely weigh against firing")
        XCTAssertTrue(dtlFires, "The same body-drop, with hang-back excluded rather than counted as clean, should fire")
    }

    /// At 30fps the downswing is 7-9 frames, so anything read at a single
    /// instant during it has to be reported less confidently.
    func testLowFrameRateReducesConfidence() {
        let address = pose(hipX: 0.50)
        let impact = pose(hipX: 0.45)
        let fast = FaultDetector.detect(context: context(address: address, top: address, impact: impact, frameRate: 240))
        let slow = FaultDetector.detect(context: context(address: address, top: address, impact: impact, frameRate: 30))
        let fastConfidence = fast.first { $0.kind == .hangBack }?.confidence ?? 0
        let slowConfidence = slow.first { $0.kind == .hangBack }?.confidence ?? 0
        XCTAssertGreaterThan(fastConfidence, slowConfidence)
    }

    // MARK: - insideOut (retired — must never fire, even on the exact swing shape that used to trigger it)

    private func planeContext(address: PoseFrame, delivery: PoseFrame, impact: PoseFrame,
                              view: CameraViewType = .downTheLine,
                              handedness: Handedness = .right) -> FaultDetector.Context {
        FaultDetector.Context(
            frames: [address, delivery, impact],
            positions: [
                DetectedPosition(position: .address, frameIndex: 0, time: 0),
                DetectedPosition(position: .delivery, frameIndex: 1, time: 1.0),
                DetectedPosition(position: .impact, frameIndex: 2, time: 1.2),
            ],
            space: .square,
            handedness: handedness,
            view: view,
            frameRate: 120,
            ballOverride: nil)
    }

    /// This exact swing shape (hands sweeping well to the target side
    /// between delivery and impact) used to trigger insideOut. It must not
    /// anymore, regardless of view — per-user feedback the detector was
    /// penalizing swings that weren't actually wrong.
    func testInsideOutNeverFiresRegardlessOfPathShape() {
        let address = pose(hipX: 0.5)
        let delivery = pose(hipX: 0.5, handsX: 0.50, handsY: 0.46)
        let stronglyInToOut = pose(hipX: 0.5, handsX: 0.65, handsY: 0.50)
        let faults = FaultDetector.detect(context: planeContext(address: address, delivery: delivery, impact: stronglyInToOut))
        XCTAssertFalse(faults.contains { $0.kind == .insideOut })
    }

    func testInsideOutIsNeverVisibleFromEitherView() {
        XCTAssertFalse(SwingFaultKind.insideOut.isVisible(from: .downTheLine))
        XCTAssertFalse(SwingFaultKind.insideOut.isVisible(from: .faceOn))
    }

    // MARK: - Reconciling with the reported shot

    func testTaggingAMissBoostsTheFaultsThatExplainIt() {
        let base = [
            SwingFault(kind: .hangBack, severity: .slight, confidence: 0.5, evidence: [], position: .impact),
            SwingFault(kind: .overTheTop, severity: .slight, confidence: 0.5, evidence: [], position: .delivery),
        ]
        let reconciled = FaultDetector.reconcile(faults: base, with: .fat)
        let hangBack = reconciled.first { $0.kind == .hangBack }!
        let overTheTop = reconciled.first { $0.kind == .overTheTop }!
        XCTAssertGreaterThan(hangBack.confidence, 0.5)
        XCTAssertEqual(overTheTop.confidence, 0.5, accuracy: 0.001)
        XCTAssertEqual(reconciled.first?.kind, .hangBack, "The explaining fault should lead")
    }

    func testTaggingDemotesAContradictoryTendency() {
        let base = [
            SwingFault(kind: .thinTendency, severity: .clear, confidence: 0.6, evidence: [], position: .impact),
        ]
        let reconciled = FaultDetector.reconcile(faults: base, with: .fat)
        let thin = reconciled.first { $0.kind == .thinTendency }
        XCTAssertTrue(thin == nil || thin!.confidence < 0.6,
                      "A thin tendency should not survive a reported fat shot at full confidence")
    }

    /// The whole point of the tag is to re-rank evidence, not to agree with
    /// whatever the golfer typed.
    func testTaggingNeverInventsAFault() {
        let reconciled = FaultDetector.reconcile(faults: [], with: .fat)
        XCTAssertTrue(reconciled.isEmpty, "A tag must not conjure a fault the swing doesn't show")
    }

    func testFlushedAndUnknownLeaveRankingAlone() {
        let base = [
            SwingFault(kind: .sway, severity: .clear, confidence: 0.7, evidence: [], position: .top),
        ]
        XCTAssertEqual(FaultDetector.reconcile(faults: base, with: .flushed).first?.confidence, 0.7)
        XCTAssertEqual(FaultDetector.reconcile(faults: base, with: .unknown).first?.confidence, 0.7)
    }

    // MARK: - View visibility

    /// Direct regression test: sway/slide/reversePivot/hangBack read screen
    /// motion along the target line, which only face-on can see. A strong sway
    /// pattern analysed as down-the-line must produce nothing, not a
    /// misleading reading.
    func testSwayNeverFiresDownTheLine() {
        let address = pose(hipX: 0.50)
        let top = pose(hipX: 0.40)   // a strong sway, were this face-on
        let faults = FaultDetector.detect(context: context(address: address, top: top, impact: address,
                                                            view: .downTheLine))
        XCTAssertFalse(faults.contains { $0.kind == .sway })
        XCTAssertFalse(faults.contains { $0.kind == .slide })
        XCTAssertFalse(faults.contains { $0.kind == .reversePivot })
        XCTAssertFalse(faults.contains { $0.kind == .hangBack })
    }

    /// overTheTop needs the down-the-line plane line; face-on it must never
    /// appear even if the (meaningless, in that view) geometry would suggest it.
    func testOverTheTopNeverFiresFaceOn() {
        for kind in SwingFaultKind.allCases {
            if kind == .overTheTop {
                XCTAssertFalse(kind.isVisible(from: .faceOn))
            }
        }
    }

    func testViewIndependentFaultsAreVisibleFromBoth() {
        for kind: SwingFaultKind in [.earlyExtension, .bodyDrop, .bodyRise, .casting, .fatTendency, .thinTendency] {
            XCTAssertTrue(kind.isVisible(from: .faceOn), "\(kind.rawValue) should be visible face-on")
            XCTAssertTrue(kind.isVisible(from: .downTheLine), "\(kind.rawValue) should be visible down-the-line")
        }
    }

    // MARK: - FaultDisplay (the one home for the confidence cutoff)

    func testDisplayThresholdIsLowerBelowSixtyFps() {
        XCTAssertLessThan(FaultDisplay.threshold(frameRate: 30), FaultDisplay.threshold(frameRate: 60),
                          "30fps halves detector confidence, so it needs a lower bar to show anything at all")
        XCTAssertEqual(FaultDisplay.threshold(frameRate: 60), FaultDisplay.threshold(frameRate: 240),
                       "60fps and above should share one threshold")
    }

    func testDisplayThresholdVisibilityMatchesTheThreshold() {
        let borderline = SwingFault(kind: .hangBack, severity: .slight, confidence: 0.30,
                                    evidence: [], position: .impact)
        XCTAssertFalse(FaultDisplay.isVisible(borderline, frameRate: 60),
                       "0.30 confidence should be hidden at 60fps")
        XCTAssertTrue(FaultDisplay.isVisible(borderline, frameRate: 30),
                      "The same 0.30 confidence should be visible at 30fps, where it's a real result")
    }

    /// The Settings toggle: off means a lower-confidence reading is hidden
    /// from `isVisible` (and so from the UI's "Lower-Confidence Reads"
    /// section) — coaching is a separate story, see `testCoachingNever...`
    /// below, since it never shows lower-confidence reads regardless of
    /// this preference.
    func testIncludeLowerConfidencePreferenceGatesVisibilityEntirely() {
        let defaults = UserDefaults.standard
        let key = FaultDisplay.includeLowerConfidenceKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let lowerConfidence = SwingFault(kind: .hangBack, severity: .slight, confidence: 0.42,
                                         evidence: [], position: .impact)
        XCTAssertTrue(FaultDisplay.isVisible(lowerConfidence, frameRate: 60),
                      "Sanity check: this fault clears the display threshold but not the firm one")
        XCTAssertFalse(FaultDisplay.isFirm(lowerConfidence))

        defaults.set(true, forKey: key)
        XCTAssertTrue(FaultDisplay.isVisible(lowerConfidence, frameRate: 60))

        defaults.set(false, forKey: key)
        XCTAssertFalse(FaultDisplay.isVisible(lowerConfidence, frameRate: 60),
                       "Opting out should hide it, not just move it to a different section")
    }

    func testIncludeLowerConfidenceDefaultsToTrueWhenUnset() {
        let defaults = UserDefaults.standard
        let key = FaultDisplay.includeLowerConfidenceKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        XCTAssertTrue(FaultDisplay.includeLowerConfidence,
                      "A user who has never touched this setting should keep today's behavior")
    }

    func testFirmFaultsRemainVisibleRegardlessOfThePreference() {
        let defaults = UserDefaults.standard
        let key = FaultDisplay.includeLowerConfidenceKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(false, forKey: key)

        let firm = SwingFault(kind: .earlyExtension, severity: .clear, confidence: 0.85,
                              evidence: [], position: .impact)
        XCTAssertTrue(FaultDisplay.isVisible(firm, frameRate: 60),
                      "Opting out of lower-confidence reads must never hide a firm finding")
    }

    /// `isVisible`'s explicit parameter is what a SwiftUI view passes (via
    /// its own `@AppStorage`-observed value) instead of relying on the
    /// default UserDefaults read — reading UserDefaults directly inside a
    /// view's body isn't a tracked dependency, so the "Lower-Confidence
    /// Reads" section wouldn't redraw when the Settings toggle changed
    /// until something else happened to re-render the screen. This pins
    /// that the explicit override actually takes effect.
    func testIsVisibleExplicitOverrideTakesPrecedenceOverStoredPreference() {
        let defaults = UserDefaults.standard
        let key = FaultDisplay.includeLowerConfidenceKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let lowerConfidence = SwingFault(kind: .hangBack, severity: .slight, confidence: 0.42,
                                         evidence: [], position: .impact)

        defaults.set(true, forKey: key)
        XCTAssertFalse(FaultDisplay.isVisible(lowerConfidence, frameRate: 60, includeLowerConfidence: false),
                       "An explicit false must win even though the stored preference is true")

        defaults.set(false, forKey: key)
        XCTAssertTrue(FaultDisplay.isVisible(lowerConfidence, frameRate: 60, includeLowerConfidence: true),
                      "An explicit true must win even though the stored preference is false")
    }

    // MARK: - Coaching

    func testCoachingLeadsWithFaultsRatherThanMetrics() {
        let metrics = [
            MetricResult(kind: .headDrift, position: .top, measured: 6, idealLow: 0, idealHigh: 3, weight: 1),
        ]
        let faults = [
            SwingFault(kind: .earlyExtension, severity: .clear, confidence: 0.85, evidence: [], position: .impact),
        ]
        let text = RulesCoach.coaching(for: metrics, faults: faults, shotResult: .unknown,
                                       shotType: .fullSwing, overallScore: 60)
        XCTAssertTrue(text.contains("Early extension"))
    }

    func testCoachingTiesTheFaultToTheReportedMiss() {
        let faults = [
            SwingFault(kind: .hangBack, severity: .clear, confidence: 0.8, evidence: [], position: .impact),
        ]
        let text = RulesCoach.coaching(for: [], faults: faults, shotResult: .fat,
                                       shotType: .fullSwing, overallScore: 60)
        XCTAssertTrue(text.lowercased().contains("fat"),
                      "Coaching should connect the fault to the miss the golfer logged")
    }

    func testCoachingFlagsTendenciesAsInferred() {
        let faults = [
            SwingFault(kind: .fatTendency, severity: .clear, confidence: 0.6, evidence: [], position: .impact),
        ]
        let text = RulesCoach.coaching(for: [], faults: faults, shotResult: .unknown,
                                       shotType: .fullSwing, overallScore: 60)
        XCTAssertTrue(text.lowercased().contains("inferred"),
                      "A body-pattern inference must not read as a measured fact")
    }

    /// A low-confidence read isn't reliable enough to state as advice — this
    /// must hold regardless of the "Show Lower-Confidence Reads" Settings
    /// toggle, which only controls what's listed on screen, never what
    /// reaches coaching.
    func testCoachingNeverMentionsALowerConfidenceFault() {
        let defaults = UserDefaults.standard
        let key = FaultDisplay.includeLowerConfidenceKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let lowerConfidence = SwingFault(kind: .hangBack, severity: .slight, confidence: 0.42,
                                         evidence: [], position: .impact)
        XCTAssertTrue(FaultDisplay.isVisible(lowerConfidence, frameRate: 60),
                     "Sanity check: this fault clears the display threshold but not the firm one")

        for includeLowerConfidence in [true, false] {
            defaults.set(includeLowerConfidence, forKey: key)
            let text = RulesCoach.coaching(for: [], faults: [lowerConfidence], shotResult: .unknown,
                                           shotType: .fullSwing, overallScore: 60)
            XCTAssertFalse(text.lowercased().contains("hanging back"),
                          "Coaching must never mention a lower-confidence fault, toggle=\(includeLowerConfidence)")
        }
    }

    func testCoachingStillWorksWithNoFaults() {
        let metrics = [
            MetricResult(kind: .xFactor, position: .top, measured: 45, idealLow: 35, idealHigh: 55, weight: 1),
        ]
        let text = RulesCoach.coaching(for: metrics, faults: [], shotResult: .unknown,
                                       shotType: .fullSwing, overallScore: 95)
        XCTAssertFalse(text.isEmpty)
    }
}
