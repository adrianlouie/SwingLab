import Foundation

/// Vision reports joints as 0–1 fractions of the image's width and height. On a
/// non-square image those two axes are *different physical distances*: on a
/// 1080×1920 clip one x-unit is 1080px but one y-unit is 1920px, so treating
/// them as interchangeable stretches every horizontal measurement by 1.78×.
///
/// That silently corrupted every angle in the app — a genuine 30° spine tilt
/// measured as roughly 46°, which is outside the "good posture" window no
/// matter how well someone is standing.
///
/// `PoseSpace` converts to an isotropic space where one unit means the same
/// distance on both axes (normalised to image *height*), so angles and
/// distances are real.
struct PoseSpace: Codable, Equatable {
    /// width / height of the oriented image. 1.0 means square, which is how the
    /// hand-authored ModelPro tables and the older tests are written.
    var aspect: Double

    init(aspect: Double = 1.0) {
        self.aspect = aspect > 0 ? aspect : 1.0
    }

    /// Square space — the default, so existing callers and unit tests written
    /// in unit-square coordinates keep their current meaning.
    static let square = PoseSpace(aspect: 1.0)

    /// Height-normalised isotropic coordinates.
    func iso(_ point: JointPoint) -> (x: Double, y: Double) {
        (point.x * aspect, point.y)
    }

    func isoX(_ x: Double) -> Double { x * aspect }

    /// Back to Vision's normalised space, for anything that needs to draw.
    func denormX(_ isoX: Double) -> Double { isoX / aspect }
}
