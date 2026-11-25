import Foundation
import CoreGraphics
import Vision

typealias Joint = VNHumanHandPoseObservation.JointName

/// One detected hand in one camera frame.
/// Coordinates: normalized 0...1, origin TOP-LEFT, horizontally MIRRORED
/// (like a mirror: when the user moves the hand to their right, x grows).
struct HandFrame {
    let time: TimeInterval
    let points: [Joint: CGPoint]
    let confidences: [Joint: Float]

    func point(_ j: Joint, minConfidence: Float = 0.3) -> CGPoint? {
        guard let p = points[j], (confidences[j] ?? 0) >= minConfidence else { return nil }
        return p
    }

    /// Pairs of joints to draw as skeleton bones.
    static let bones: [(Joint, Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]
}

/// Engine mode, for display and coloring.
enum GestureMode: String {
    case idle      // hand watched, nothing active
    case scroll    // two fingers up: scrolling
    case picker    // window picker overlay is open
    case cooldown  // short pause after an action
    case paused    // user disabled gestures
}
