import Foundation

/// The originals rotate horizontally from cursor offset, but vertically from cursor movement.
/// The recovered stepTick is retained as source evidence. The remaster uses applyDirectLook:
/// relative movement changes angles once, with no held offset, acceleration or trailing motion.
/// Input deltaY is down-positive.
/// Output angles use the original game's basis, not SceneKit's camera Euler convention.
struct OriginalInputModel {
    struct Angles: Equatable {
        var yawDegrees: Double
        var pitchDegrees: Double
    }

    let gameID: String
    private(set) var angles: Angles
    private(set) var cursorOffsetX: Double = 0
    private(set) var cursorOffsetY: Double = 0
    private var previousY = 0

    init(gameID: String, yawDegrees: Double = 0, pitchDegrees: Double = 0) {
        precondition(gameID == "2000" || gameID == "2002")
        self.gameID = gameID
        self.angles = Angles(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    }

    /// The five coefficients occur in the 2000 + / - key handler; both EXEs default to .02.
    /// Selecting another level in 2002 is an explicit native extension to its fixed coefficient.
    static func sensitivityCoefficient(level: Int) -> Double {
        Double(Float([0.0025, 0.005, 0.01, 0.02, 0.03][min(5, max(1, level)) - 1]))
    }

    mutating func ingestRelative(deltaX: Double, deltaY: Double,
                                 viewportWidth: Double, viewportHeight: Double) {
        guard deltaX.isFinite, deltaY.isFinite, viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0 else { return }
        setCursorOffset(x: cursorOffsetX + deltaX * 640 / viewportWidth,
                        y: cursorOffsetY + deltaY * 480 / viewportHeight)
    }

    /// Allows replay of original cursor positions; x/y are offsets from original pixel (320,240).
    mutating func setCursorOffset(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        cursorOffsetX = min(319, max(-320, x))
        cursorOffsetY = min(239, max(-240, y))
    }

    /// Capture/focus/level transitions reset both cursor history and offset to avoid a stale jump.
    mutating func resetCursor() {
        cursorOffsetX = 0; cursorOffsetY = 0; previousY = 0
    }

    mutating func setAngles(yawDegrees: Double, pitchDegrees: Double) {
        guard yawDegrees.isFinite, pitchDegrees.isFinite else { return }
        angles = Angles(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    }

    /// Original I / R negates pitch immediately; the next input tick applies its normal clamp.
    mutating func invertCurrentPitch() { angles.pitchDegrees = -angles.pitchDegrees }

    /// Reference remake Input.consumeLook / Game.applyLook uses movement * sensitivity,
    /// without dt multiplication or interpolation. Keep that feel at native event frequency.
    /// Native event deltas are independent of window size and Retina backing pixels.
    static func directRadiansPerPoint(level: Int) -> Double {
        0.0021 * pow(1.22, Double(min(5, max(1, level)) - 4))
    }

    @discardableResult
    mutating func applyDirectLook(deltaX: Double, deltaY: Double,
                                  sensitivityLevel: Int = 4, invertY: Bool = false) -> Angles {
        guard deltaX.isFinite, deltaY.isFinite else { return angles }
        let degrees = Self.directRadiansPerPoint(level: sensitivityLevel) * 180 / .pi
        let yaw = angles.yawDegrees - deltaX * degrees
        let pitch = angles.pitchDegrees - deltaY * degrees * (invertY ? -1 : 1)
        guard yaw.isFinite, pitch.isFinite else { return angles }
        angles.yawDegrees = yaw.truncatingRemainder(dividingBy: 360)
        if angles.yawDegrees < 0 { angles.yawDegrees += 360 }
        angles.pitchDegrees = min(gameID == "2000" ? 88 : 80,
                                  max(gameID == "2000" ? -45 : -25, pitch))
        // No virtual-cursor saturation, integer quantization or residual velocity.
        resetCursor()
        return angles
    }

    @discardableResult
    mutating func stepTick(sensitivityLevel: Int = 4, invertY: Bool = false,
                           accelerationEnabled: Bool = false) -> Angles {
        // GetCursorPos returned integer pixels. Fractional native points remain in the virtual
        // cursor accumulator but are not treated as original integer cursor samples.
        let x = Int(cursorOffsetX)
        let y = Int(cursorOffsetY)
        let deltaY = y - previousY
        previousY = y
        let coefficient = Self.sensitivityCoefficient(level: sensitivityLevel)
        let horizontal = Double(x) * coefficient
        if gameID == "2002" && accelerationEnabled {
            angles.yawDegrees -= abs(Double(x) / 20) * horizontal * 0.1
        } else {
            angles.yawDegrees -= horizontal
        }
        angles.pitchDegrees += Double(deltaY) * 0.2 * (invertY ? 1 : -1)
        angles.pitchDegrees = min(gameID == "2000" ? 88 : 80,
                                  max(gameID == "2000" ? -45 : -25, angles.pitchDegrees))
        // Preserve the original inclusive 360 endpoint rather than a modulo operation.
        if angles.yawDegrees < 0 { angles.yawDegrees += 360 }
        if angles.yawDegrees > 360 { angles.yawDegrees -= 360 }
        return angles
    }
}

func originalInputModelSelfTest() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "OriginalInputModelTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }
    var linear = OriginalInputModel(gameID: "2000", yawDegrees: 180)
    linear.setCursorOffset(x: 100, y: 10)
    let first = linear.stepTick()
    let second = linear.stepTick()
    try require(near(first.yawDegrees, 178) && near(second.yawDegrees, 176),
                "Horizontal offset must keep rotating without new events")
    try require(near(first.pitchDegrees, -2) && near(second.pitchDegrees, -2),
                "Vertical input must use movement, not held cursor offset")
    var accelerated = OriginalInputModel(gameID: "2002", yawDegrees: 180)
    accelerated.setCursorOffset(x: 100, y: 10)
    try require(near(accelerated.stepTick(invertY: true, accelerationEnabled: true).yawDegrees, 179)
                && near(accelerated.angles.pitchDegrees, 2), "2002 acceleration and inverted Y")
    accelerated.setCursorOffset(x: -300, y: 10)
    try require(near(accelerated.stepTick(accelerationEnabled: true).yawDegrees, 188),
                "Acceleration must retain horizontal sign and quadratic magnitude")
    var boundary = OriginalInputModel(gameID: "2002", yawDegrees: 360, pitchDegrees: 0)
    boundary.setCursorOffset(x: 1000, y: 1000)
    _ = boundary.stepTick()
    try require(boundary.cursorOffsetX == 319 && boundary.cursorOffsetY == 239
                && boundary.angles.pitchDegrees == -25, "Original upper cursor and pitch clamps")
    boundary.setCursorOffset(x: -1000, y: -1000)
    _ = boundary.stepTick()
    try require(boundary.cursorOffsetX == -320 && boundary.cursorOffsetY == -240
                && near(boundary.angles.pitchDegrees, 70.8), "Original lower cursor clamp and delta")
    boundary.setAngles(yawDegrees: 360, pitchDegrees: 80)
    boundary.invertCurrentPitch()
    try require(boundary.angles.pitchDegrees == -80, "Inversion must negate before next-tick clamp")
    boundary.resetCursor()
    _ = boundary.stepTick()
    try require(boundary.angles.yawDegrees == 360 && boundary.angles.pitchDegrees == -25,
                "Reset must clear cursor history, keep angles and preserve inclusive 360")
    var resized = OriginalInputModel(gameID: "2000", yawDegrees: 180)
    resized.ingestRelative(deltaX: 200, deltaY: 20, viewportWidth: 1280, viewportHeight: 960)
    try require(resized.stepTick() == first, "Window scaling must map to virtual original pixels")
    for (index, expected) in [0.0025, 0.005, 0.01, 0.02, 0.03].enumerated() {
        try require(near(OriginalInputModel.sensitivityCoefficient(level: index + 1), expected),
                    "Original five-step coefficient")
    }
    for gameID in ["2000", "2002"] {
        var direct = OriginalInputModel(gameID: gameID, yawDegrees: 180)
        let moved = direct.applyDirectLook(deltaX: 100, deltaY: 20)
        try require(near(moved.yawDegrees, 180 - 0.21 * 180 / .pi)
                    && near(moved.pitchDegrees, -0.042 * 180 / .pi), "Reference remake angular sensitivity and matching axes")
        for _ in 0..<240 {
            try require(direct.applyDirectLook(deltaX: 0, deltaY: 0) == moved,
                        "Stopping physical movement stops aim immediately; no drift")
        }
        var split = OriginalInputModel(gameID: gameID, yawDegrees: 180)
        for _ in 0..<100 { _ = split.applyDirectLook(deltaX: 1, deltaY: 0.2) }
        try require(near(split.angles.yawDegrees, moved.yawDegrees) && near(split.angles.pitchDegrees, moved.pitchDegrees),
                    "Angular displacement must not depend on input event rate or frame count")
        _ = direct.applyDirectLook(deltaX: -100, deltaY: -20)
        try require(near(direct.angles.yawDegrees, 180) && near(direct.angles.pitchDegrees, 0), "Equal reverse movement returns to original aim")
        _ = direct.applyDirectLook(deltaX: 0, deltaY: -10000)
        let upper = direct.angles.pitchDegrees
        _ = direct.applyDirectLook(deltaX: 0, deltaY: 1)
        try require(direct.angles.pitchDegrees < upper, "Pitch limit has no accumulated dead travel when reversing")
        let beforeInvalid = direct.angles
        _ = direct.applyDirectLook(deltaX: .infinity, deltaY: 0)
        try require(direct.angles == beforeInvalid, "Invalid device delta leaves valid camera pose")
        direct.resetCursor()
        try require(direct.angles == beforeInvalid && direct.cursorOffsetX == 0, "Capture transition clears history without moving aim")
        var inverted = OriginalInputModel(gameID: gameID)
        try require(inverted.applyDirectLook(deltaX: 0, deltaY: 10, invertY: true).pitchDegrees > 0, "Direct inverted Y follows setting")
    }
    print("PASS direct aim: remake sensitivity, zero drift, event-rate independence, symmetric axes, immediate clamp reversal and capture reset")
}
