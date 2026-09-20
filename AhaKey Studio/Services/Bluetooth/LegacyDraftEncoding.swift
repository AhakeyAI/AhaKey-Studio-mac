import Foundation

// Only the legacy device owner compiles these firmware encoders.
extension LightEffectStyle {
    var firmwareIndex: UInt8 {
        switch self {
        case .off: 0
        case .singleMove: 1
        case .rainbowMove: 2
        case .rainbowWave: 3
        case .rainbowWaveSlow: 4
        case .breathing: 5
        case .middleLight: 6
        case .typingRipple: 7
        case .comet: 8
        case .scanBar: 9
        case .pulseCenter: 10
        case .warningBlink: 11
        case .successSweep: 12
        case .blueThinking: 13
        case .lowBattery: 14
        case .chargingFlow: 15
        case .approvalWait: 16
        }
    }
    init?(firmwareIndex: UInt8) {
        guard let match = Self.allCases.first(where: { $0.firmwareIndex == firmwareIndex }) else {
            return nil
        }
        self = match
    }
}

extension Array where Element == MacroStep {
    var flattenedBytes: [UInt8] {
        flatMap { [$0.action.rawValue, $0.param] }
    }
}
