import Foundation

// The supplied executables switch weapon visibility immediately. No raise/lower
// animation or deployment timer was found. The value previously called "ready"
// is the generic object field also used as aircraft HP: 2000 AI+0xa8, 2002+0x64.
// Every object initializes this field to1. Do not infer a deployment state machine
// from the presence of a field==1 fire check.
// Evidence: 2000 0x401165:130..163,522..557;0x404b24:28..35.
// 2002 0x40101d:119..164,187..197,300..373;0x429201:58..69.
struct OriginalWeaponDeployment {
    struct Pose: Equatable {
        let mountObjectID: Int
        let mountWorldPosition: SIMD3<Double>
        let modelRootObjectID: Int?
        let visibleObjectIDs: [Int]
        let readyFieldObjectID: Int
        let ready: Bool
        let transitionTicks: Int = 0
    }
    let version: OriginalGameVersion
    init(version: OriginalGameVersion) { self.version = version }

    // Readiness fields may be supplied from an exact original object-state
    // snapshot. The default is the recovered loader value. Input capture, pause,
    // ammo, campaign end and trigger phase are separate host/weapon-state gates.
    // Selection itself has no delayed tick or temporary !ready interval.
    func step(selected: OriginalWeapon, machineGunVariant: Int = 0, cannonVariant: Int = 0,
              readyFields: [Int: Int] = [:]) -> Pose {
        let mount: Int, root: Int?, visible: [Int], gate: Int
        if version == .beach2000 {
            switch selected {
            case .machineGun: mount = 8; root = 8; visible = [8, 9, 10]; gate = 8
            case .cannon: mount = 142; root = 143; visible = [142, 143]; gate = 142
            case .handgun: mount = 142; root = 214; visible = [142, 214, 215]; gate = 214
            case .flare: mount = 142; root = nil; visible = []; gate = 214
            }
        } else {
            mount = 19; gate = 19
            switch selected {
            case .machineGun:
                switch machineGunVariant {
                case 0: root = 20; visible = [19, 20, 21, 22]
                case 1: root = 23; visible = [19, 23]
                case 2: root = 25; visible = [19, 25]
                default: root = nil; visible = [19]
                }
            case .cannon:
                root = cannonVariant == 0 ? 24 : nil
                visible = cannonVariant == 0 ? [19, 24] : [19]
            case .handgun: root = 26; visible = [19, 26, 27]
            case .flare: root = 28; visible = [19, 28]
            }
        }
        return .init(mountObjectID: mount, mountWorldPosition: .init(0, 800, 0),
                     modelRootObjectID: root, visibleObjectIDs: visible, readyFieldObjectID: gate,
                     ready: root != nil && readyFields[gate, default: 1] == 1)
    }
}

func testOriginalWeaponDeployment() throws {
    func check(_ good: Bool, line: Int = #line) throws {
        if !good { throw NSError(domain: "OriginalWeaponDeployment", code: line,
                                 userInfo: [NSLocalizedDescriptionKey: "Recovered weapon invariant failed at line \(line)"]) }
    }
    let a = OriginalWeaponDeployment(version: .beach2000)
    try check(a.step(selected: .machineGun).visibleObjectIDs == [8, 9, 10])
    try check(a.step(selected: .cannon).ready && a.step(selected: .cannon).transitionTicks == 0)
    try check(a.step(selected: .handgun, readyFields: [214: 0]).ready == false)
    try check(a.step(selected: .handgun, readyFields: [142: 0]).ready)
    let b = OriginalWeaponDeployment(version: .beach2002)
    try check(b.step(selected: .machineGun, machineGunVariant: 2).modelRootObjectID == 25)
    try check(!b.step(selected: .cannon, readyFields: [19: 2]).ready)
    try check(b.step(selected: .handgun).mountWorldPosition == SIMD3(0, 800, 0))
    print("PASS original weapon deployment: immediate visibility and source field gates; no invented delay")
}
