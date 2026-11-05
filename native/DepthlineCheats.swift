enum DepthlineCheat: String, CaseIterable {
    case invulnerability = "whosyourdaddy"
    case fullAmmo = "fullammo"
    case fullHealth = "fullhealth"
}

extension Game {
    /// The hills HUD uses fixed magazine capacities. The coast uses its
    /// mission loadout, with a reserve for weapons supplied empty at entry.
    var ammunitionCapacity: OriginalAmmo {
        if training != nil {
            return OriginalAmmo(machineGun: 240, cannon: 32, missile: 2, handgun: 15, flare: 0)
        }
        if version == .beach2002 {
            return OriginalAmmo(machineGun: 500, cannon: 20, missile: 20, handgun: 15, flare: night ? 20 : 0)
        }
        let loadout = levelDefinition?["ammo"] as? [Int] ?? []
        func allotted(_ index: Int, reserve: Int) -> Int {
            guard loadout.indices.contains(index), loadout[index] > 0 else { return reserve }
            return loadout[index]
        }
        return OriginalAmmo(machineGun: allotted(0, reserve: 300), cannon: allotted(1, reserve: 8),
                            missile: allotted(2, reserve: 3), handgun: 15, flare: 0)
    }

    func markCurrentRunAssisted() {
        guard !usedCheats else { return }
        usedCheats = true
        if training == nil { onCheckpoint?(level + 1, levelStartScore) }
    }

    @discardableResult
    func applyDepthlineCheat(_ cheat: DepthlineCheat) -> String {
        guard !finished, !isShowingVictoryChoice, combat.health > 0 else {
            return DLoc.text("本关已结束", "This mission has ended.")
        }
        markCurrentRunAssisted()
        let message: String
        switch cheat {
        case .invulnerability:
            isInvulnerable.toggle()
            if isInvulnerable { hud.damageFlash = 0 }
            message = isInvulnerable ? DLoc.text("本关无敌已开启", "Invulnerability enabled for this mission.")
                                     : DLoc.text("本关无敌已关闭", "Invulnerability disabled.")
        case .fullAmmo:
            let full = ammunitionCapacity
            // Supplies can award more than the normal capacity.
            weapons.ammo.machineGun = max(weapons.ammo.machineGun, full.machineGun)
            weapons.ammo.cannon = max(weapons.ammo.cannon, full.cannon)
            weapons.ammo.handgun = max(weapons.ammo.handgun, full.handgun)
            weapons.ammo.missile = max(weapons.ammo.missile, full.missile)
            weapons.ammo.flare = max(weapons.ammo.flare, full.flare)
            weapons.prepareMissileSlots()
            message = DLoc.text("本关弹药已补满", "Ammunition refilled.")
        case .fullHealth:
            combat.health = 100
            hud.damageFlash = 0
            message = DLoc.text("阵地防御已恢复至 100%", "Defenses restored to 100%.")
        }
        updateHUD()
        return message
    }
}
