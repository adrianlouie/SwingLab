import Foundation

/// Pure-Swift angle and line math over pose keypoints.
/// No Vision or UIKit imports — fully unit-testable.
///
/// Every function takes a `PoseSpace`. Vision's 0–1 coordinates are fractions
/// of width and height separately, so on a 9:16 clip an x-unit is a much
/// shorter real distance than a y-unit; measuring angles without correcting for
/// that inflates them badly. `space` defaults to square so hand-authored
/// unit-square poses and the existing tests keep their meaning.
enum SwingGeometry {

    /// Average adult shoulder width, used to convert normalized image
    /// distances into approximate real-world inches.
    static let assumedShoulderWidthInches = 16.0

    // MARK: - Primitives

    /// Angle in degrees of the line a→b measured from vertical (0° = straight
    /// up). Always positive, 0...180.
    static func angleFromVertical(from a: JointPoint, to b: JointPoint,
                                  space: PoseSpace = .square) -> Double {
        let dx = space.isoX(b.x - a.x)
        let dy = b.y - a.y
        let magnitude = (dx * dx + dy * dy).squareRoot()
        guard magnitude > 0 else { return 0 }
        // Vertical unit vector is (0, 1) in bottom-left-origin coords.
        let cosine = max(-1, min(1, dy / magnitude))
        return acos(cosine) * 180 / .pi
    }

    /// Angle in degrees of the line a→b measured from horizontal, signed
    /// (-90...90). Positive when b is above a.
    static func angleFromHorizontal(from a: JointPoint, to b: JointPoint,
                                    space: PoseSpace = .square) -> Double {
        let dx = space.isoX(b.x - a.x)
        let dy = b.y - a.y
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return 0 }
        return atan2(dy, abs(dx)) * 180 / .pi
    }

    static func distance(_ a: JointPoint, _ b: JointPoint,
                         space: PoseSpace = .square) -> Double {
        let dx = space.isoX(b.x - a.x)
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Interior angle at `b` formed by a→b→c, in degrees. Used for joint
    /// angles such as the trail elbow when checking for a cast.
    static func jointAngle(_ a: JointPoint, _ b: JointPoint, _ c: JointPoint,
                           space: PoseSpace = .square) -> Double {
        let v1 = (x: space.isoX(a.x - b.x), y: a.y - b.y)
        let v2 = (x: space.isoX(c.x - b.x), y: c.y - b.y)
        let m1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
        let m2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard m1 > 0.0001, m2 > 0.0001 else { return 0 }
        let cosine = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (m1 * m2)))
        return acos(cosine) * 180 / .pi
    }

    // MARK: - Swing metrics

    /// Forward/side spine tilt: angle of the hips→neck line off vertical.
    static func spineTilt(frame: PoseFrame, space: PoseSpace = .square) -> Double? {
        guard let neck = frame[.neck], let root = frame[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return nil }
        return angleFromVertical(from: root, to: neck, space: space)
    }

    /// Spine lean with a sign: positive means leaning toward +x. Unsigned tilt
    /// cannot tell a reverse pivot from a correct one, which is why the fault
    /// detectors need this variant.
    static func spineLeanSigned(frame: PoseFrame, space: PoseSpace = .square) -> Double? {
        guard let neck = frame[.neck], let root = frame[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return nil }
        let dx = space.isoX(neck.x - root.x)
        let dy = neck.y - root.y
        guard abs(dx) > 0.00001 || abs(dy) > 0.00001 else { return 0 }
        return atan2(dx, dy) * 180 / .pi
    }

    /// Estimated body-segment rotation from the apparent foreshortening of a
    /// joint pair (shoulders or hips) relative to address.
    ///
    /// A single 2D camera can't see rotation directly, but as the shoulders
    /// turn away the projected width shrinks by cos(turn angle) — so
    /// turn ≈ acos(currentWidth / addressWidth). It's an estimate; where 3D
    /// pose is available `SwingAnalyzer` prefers the measured value.
    ///
    /// Returns `nil`, not 0, when `currentWidth >= addressWidth` — the model
    /// only holds while width is shrinking; a camera angle, stance
    /// imperfection, or plain measurement noise can easily make width grow
    /// instead, and forcing an angle out of that regime used to silently
    /// return 0°, which reads as "confirmed zero rotation" and gets scored
    /// as a real, severe fault. Confirmed against real footage where this
    /// fired at Top — the single most heavily-weighted position — and
    /// zeroed both `shoulderTurn` and `xFactor` for a swing that plainly
    /// wasn't flat. See `CLAUDE.md` "rotationEstimate nil-not-zero".
    static func rotationEstimate(addressWidth: Double, currentWidth: Double) -> Double? {
        guard addressWidth > 0.001, currentWidth < addressWidth else { return nil }
        let ratio = currentWidth / addressWidth
        return acos(ratio) * 180 / .pi
    }

    static func shoulderWidth(frame: PoseFrame, space: PoseSpace = .square) -> Double? {
        guard let l = frame[.leftShoulder], let r = frame[.rightShoulder],
              l.confidence > 0.2, r.confidence > 0.2 else { return nil }
        return distance(l, r, space: space)
    }

    static func hipWidth(frame: PoseFrame, space: PoseSpace = .square) -> Double? {
        guard let l = frame[.leftHip], let r = frame[.rightHip],
              l.confidence > 0.2, r.confidence > 0.2 else { return nil }
        return distance(l, r, space: space)
    }

    /// Torso length — the natural body-relative unit for scale-invariant
    /// measurements, and much steadier than shoulder width, which foreshortens
    /// as the body turns.
    static func torsoLength(frame: PoseFrame, space: PoseSpace = .square) -> Double? {
        guard let neck = frame[.neck], let root = frame[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return nil }
        return distance(neck, root, space: space)
    }

    /// Horizontal drift of a joint vs its address location, in approximate
    /// inches (scaled by the address shoulder width).
    static func horizontalDriftInches(joint: Joint, address: PoseFrame, current: PoseFrame,
                                      space: PoseSpace = .square) -> Double? {
        horizontalDriftSignedInches(joint: joint, address: address, current: current,
                                    space: space).map(abs)
    }

    /// Signed version: positive means drift toward +x. Direction is what
    /// separates a sway from a slide, so the fault layer needs the sign.
    static func horizontalDriftSignedInches(joint: Joint, address: PoseFrame, current: PoseFrame,
                                            space: PoseSpace = .square) -> Double? {
        guard let a = address[joint], let c = current[joint],
              a.confidence > 0.2, c.confidence > 0.2,
              let shoulderW = shoulderWidth(frame: address, space: space),
              shoulderW > 0.0001 else { return nil }
        let drift = space.isoX(c.x - a.x)
        return drift / shoulderW * assumedShoulderWidthInches
    }

    /// Head position proxy: nose if visible, else neck.
    static func headJoint(in frame: PoseFrame) -> Joint? {
        if let nose = frame[.nose], nose.confidence > 0.2 { return .nose }
        if let neck = frame[.neck], neck.confidence > 0.2 { return .neck }
        return nil
    }

    // MARK: - Swing plane (down-the-line)

    /// The classic DTL swing-plane line: from the ball up through the trail
    /// shoulder at address.
    ///
    /// The ball's horizontal position genuinely isn't recoverable from body
    /// keypoints — it depends on club length and lie angle — so this is only a
    /// starting estimate. `ballOverride` carries the user's own calibrated
    /// marker when they've set one.
    static func planeLine(address: PoseFrame, handedness: Handedness,
                          space: PoseSpace = .square,
                          ballOverride: JointPoint? = nil,
                          groundY: Double? = nil) -> (ball: JointPoint, shoulder: JointPoint)? {
        let trailShoulder: Joint = handedness == .right ? .rightShoulder : .leftShoulder
        guard let shoulder = address[trailShoulder], shoulder.confidence > 0.2 else { return nil }

        if let ball = ballOverride {
            return (ball, shoulder)
        }

        guard let hands = address.handsCenter,
              let ankleL = address[.leftAnkle], let ankleR = address[.rightAnkle],
              ankleL.confidence > 0.2, ankleR.confidence > 0.2 else { return nil }

        // The ankle joint sits above the sole, so drop a little further to
        // reach the turf.
        let torso = torsoLength(frame: address, space: space) ?? 0.1
        let ground = groundY ?? (min(ankleL.y, ankleR.y) - torso * 0.10)

        // The ball sits farther from the body than the hands, because the shaft
        // leans out and down.
        let ankleMidX = (ankleL.x + ankleR.x) / 2
        let awaySign: Double = hands.x >= ankleMidX ? 1 : -1
        let ballX = hands.x + awaySign * abs(hands.x - ankleMidX) * 0.30

        return (JointPoint(x: ballX, y: ground, confidence: 1), shoulder)
    }

    /// Perpendicular distance of a point from the plane line, as a percentage
    /// of the line's length. Unsigned.
    static func planeDeviationPercent(point: JointPoint, ball: JointPoint, shoulder: JointPoint,
                                      space: PoseSpace = .square) -> Double {
        abs(planeDeviationSigned(point: point, ball: ball, shoulder: shoulder, space: space))
    }

    /// Signed distance from the plane line, as a percentage of its length.
    ///
    /// Positive means the point lies to the left of the ball→shoulder
    /// direction. Callers multiply by an orientation sign so that positive
    /// consistently means "above/outside the plane", i.e. over the top.
    /// The unsigned version cannot distinguish over-the-top from under-plane
    /// at all, which is why this exists.
    static func planeDeviationSigned(point: JointPoint, ball: JointPoint, shoulder: JointPoint,
                                     space: PoseSpace = .square) -> Double {
        let dx = space.isoX(shoulder.x - ball.x)
        let dy = shoulder.y - ball.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return 0 }
        let px = space.isoX(point.x - ball.x)
        let py = point.y - ball.y
        let cross = dx * py - dy * px
        return cross / length / length * 100
    }

}
