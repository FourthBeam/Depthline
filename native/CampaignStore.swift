import Foundation

enum DepthlineIdentity {
    static var title: String { DLoc.text("纵深防线", "Depthline") }
    static let subtitle = "DEPTHLINE"
    static let trainingID = "training"
    static func sector(_ id: String) -> String {
        switch id {
        case "2000": return DLoc.text("海岸战区", "Coastal Sector")
        case "2002": return DLoc.text("丘陵战区", "Hill Sector")
        case trainingID: return DLoc.text("教学战区", "Training Sector")
        default: return id
        }
    }
}

/// Native collection data. A checkpoint describes the start of a level, not a live battlefield.
/// Level numbers are one-based; each game owns its player name, checkpoint and score table.
final class CampaignStore {
    enum GraphicsQuality: String, Codable, CaseIterable { case nostalgic, remastered }
    struct Settings: Codable, Equatable {
        var soundEnabled: Bool
        var musicEnabled: Bool
        var graphicsQuality: GraphicsQuality
        var sensitivityLevel: Int
        var invertY: Bool
        var mouseAccelerationEnabled: Bool
        var antialiasingSamples: Int = 4
        var language: DepthlineLanguage = .system

        init(soundEnabled: Bool = true, sensitivityLevel: Int = 4, invertY: Bool = false,
             mouseAccelerationEnabled: Bool = false, musicEnabled: Bool = true, graphicsQuality: GraphicsQuality = .remastered,
             language: DepthlineLanguage = .system) {
            self.soundEnabled = soundEnabled
            self.musicEnabled = musicEnabled
            self.graphicsQuality = .remastered
            self.sensitivityLevel = min(5, max(1, sensitivityLevel))
            self.invertY = invertY
            self.mouseAccelerationEnabled = mouseAccelerationEnabled
            self.language = language
        }
        private enum CodingKeys: String, CodingKey { case soundEnabled, musicEnabled, graphicsQuality, sensitivityLevel, invertY, mouseAccelerationEnabled, antialiasingSamples, language }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            soundEnabled = try values.decode(Bool.self, forKey: .soundEnabled)
            musicEnabled = try values.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? true
            _ = try values.decodeIfPresent(GraphicsQuality.self, forKey: .graphicsQuality)
            graphicsQuality = .remastered
            sensitivityLevel = try values.decode(Int.self, forKey: .sensitivityLevel)
            invertY = try values.decode(Bool.self, forKey: .invertY)
            mouseAccelerationEnabled = try values.decodeIfPresent(Bool.self, forKey: .mouseAccelerationEnabled) ?? false
            language = try values.decodeIfPresent(DepthlineLanguage.self, forKey: .language) ?? .system
            let samples = try values.decodeIfPresent(Int.self, forKey: .antialiasingSamples) ?? 4
            antialiasingSamples = [0, 2, 4].contains(samples) ? samples : 4
        }

        var sensitivityMultiplier: Double {
            [0.125, 0.25, 0.5, 1.0, 1.5][min(5, max(1, sensitivityLevel)) - 1]
        }
    }

    struct Checkpoint: Codable, Equatable {
        var level: Int
        let score: Int
        let playerName: String
        let savedAt: Date
        var usedCheats: Bool? = nil
    }

    /// A named, manually retained level start. The automatic Continue checkpoint remains separate.
    struct SavedGame: Codable, Equatable, Identifiable {
        let id: UUID
        let slot: Int
        let name: String
        var checkpoint: Checkpoint
        let savedAt: Date
    }

    struct ScoreEntry: Codable, Equatable, Identifiable {
        let id: UUID
        let playerName: String
        let score: Int
        let level: Int
        let recordedAt: Date
        var usedCheats: Bool? = nil
    }

    enum StoreError: LocalizedError {
        case invalidGame, invalidProgress, invalidSettings, noCheckpoint, invalidSavedGame, saveSlotsFull(Int)
        case unsupportedVersion(Int), unreadableFile(String)
        var errorDescription: String? {
            switch self {
            case .invalidGame: return DLoc.text("无法识别游戏版本。", "Unknown sector.")
            case .invalidProgress: return DLoc.text("关卡或成绩超出有效范围。", "Invalid mission or score.")
            case .invalidSettings: return DLoc.text("请选择有效的鼠标灵敏度和抗锯齿档位。", "Choose a supported sensitivity and antialiasing level.")
            case .noCheckpoint: return DLoc.text("本版本还没有可保存的关卡起点。请先开始游戏。", "Start a campaign to create a mission checkpoint.")
            case .invalidSavedGame: return DLoc.text("所选存档不存在或属于另一款游戏。", "This save is unavailable for this sector.")
            case .saveSlotsFull(let count): return DLoc.text("本版本的 \(count) 个存档槽已满，请选择一个存档后覆盖。", "All \(count) slots are full. Select a save to replace.")
            case .unsupportedVersion(let version): return DLoc.text("存档由更新版本创建（格式 \(version)），当前版本不会覆盖它。", "This save uses a newer format (\(version)). Open it in a newer version of the game.")
            case .unreadableFile(let message): return DLoc.text("无法读取存档，已停止写入以保留原文件：", "The save file could not be read. Saving is disabled to protect it. ") + message
            }
        }
    }

    private struct GameRecord: Codable {
        var playerName = ""
        var checkpoint: Checkpoint?
        var scores: [ScoreEntry] = []
        // A final score remains recoverable even below the top 30.
        var lastCompletion: ScoreEntry?
        var savedGames: [SavedGame] = []

        init() {}
        private enum CodingKeys: String, CodingKey { case playerName, checkpoint, scores, savedGames, lastCompletion }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            playerName = try values.decode(String.self, forKey: .playerName)
            checkpoint = try values.decodeIfPresent(Checkpoint.self, forKey: .checkpoint)
            scores = try values.decode([ScoreEntry].self, forKey: .scores)
            lastCompletion = try values.decodeIfPresent(ScoreEntry.self, forKey: .lastCompletion)
            savedGames = try values.decodeIfPresent([SavedGame].self, forKey: .savedGames) ?? []
        }
    }
    private struct Document: Codable {
        static let currentVersion = 5
        var version = currentVersion
        var settings = Settings()
        var games: [String: GameRecord] = ["2000": GameRecord(), "2002": GameRecord()]
        var completedSectors: Set<String> = []

        init() {}
        private enum CodingKeys: String, CodingKey { case version, settings, games, completedSectors }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            settings = try values.decode(Settings.self, forKey: .settings)
            games = try values.decode([String: GameRecord].self, forKey: .games)
            if version >= 3 { completedSectors = try values.decode(Set<String>.self, forKey: .completedSectors) }
        }
    }
    private struct Header: Decodable { let version: Int }
    private var document = Document()
    private var pendingCorruptBackup = false
    private var writeBlock: StoreError?
    private let fileManager = FileManager.default
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("campaigns.json") }
    private var noticeText: (() -> String)?
    var storageNotice: String? { noticeText?() }
    var settings: Settings { document.settings }
    private static let finalMissions = ["2000": 60, "2002": 99]
    static let supportedGames = finalMissions.keys.sorted()
    /// 2000's original GDI format string is "分数   %d0"; storage retains its internal units.
    static func displayScore(gameID: String, score: Int) -> String {
        gameID == "2000" ? "\(score)0" : String(score)
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Depthline", isDirectory: true)
        load()
    }

    func playerName(for gameID: String) -> String {
        Self.cleanName(document.games[gameID]?.playerName ?? "")
    }
    func checkpoint(for gameID: String) -> Checkpoint? { document.games[gameID]?.checkpoint }
    func highScores(for gameID: String) -> [ScoreEntry] {
        guard let record = document.games[gameID] else { return [] }
        if let result = record.lastCompletion, !record.scores.contains(where: { $0.id == result.id }) {
            return Array((record.scores + [result]).sorted { Self.precedes($0, $1, gameID: gameID) }.prefix(30))
        }
        return record.scores
    }

    func isSectorCompleted(_ id: String) -> Bool { document.completedSectors.contains(id) }

    func markSectorCompleted(_ id: String) throws {
        guard id == DepthlineIdentity.trainingID || Self.supportedGames.contains(id) else { throw StoreError.invalidGame }
        guard !isSectorCompleted(id) else { return }
        var next = document
        next.completedSectors.insert(id)
        try persist(next)
    }

    /// Original launcher path tables contain12 BH2000 slots and20 BH2002 slots.
    /// Bh.exe0x47eed4 and bh2.ews0x427710:30-byte filenames, selected-index writers0x40c180/0x4090e0.
    static func saveSlotCount(gameID: String) -> Int { gameID == "2000" ? 12 : gameID == "2002" ? 20 : 0 }
    func savedGames(for gameID: String) -> [SavedGame] {
        (document.games[gameID]?.savedGames ?? []).sorted { $0.slot < $1.slot }
    }

    @discardableResult
    func saveCurrentCheckpoint(gameID: String, name: String, replacingID: UUID? = nil) throws -> SavedGame {
        try validateGame(gameID)
        guard let checkpoint = document.games[gameID]?.checkpoint else { throw StoreError.noCheckpoint }
        var next = document
        var saved = next.games[gameID]!.savedGames
        let slot: Int
        let id: UUID
        if let replacingID {
            guard let previous = saved.first(where: { $0.id == replacingID }) else { throw StoreError.invalidSavedGame }
            id = previous.id; slot = previous.slot
            saved.removeAll { $0.id == replacingID }
        } else {
            let occupied = Set(saved.map(\.slot))
            guard let free = (1...Self.saveSlotCount(gameID: gameID)).first(where: { !occupied.contains($0) })
            else { throw StoreError.saveSlotsFull(Self.saveSlotCount(gameID: gameID)) }
            id = UUID(); slot = free
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? checkpoint.playerName + DLoc.text(" · 第 \(checkpoint.level) 关", " · Mission \(checkpoint.level)") : name
        let result = SavedGame(id: id, slot: slot, name: Self.cleanName(label), checkpoint: checkpoint, savedAt: Date())
        saved.append(result)
        next.games[gameID]!.savedGames = saved.sorted { $0.slot < $1.slot }
        try persist(next)
        return result
    }

    @discardableResult
    func loadSavedGame(gameID: String, id: UUID) throws -> Checkpoint {
        try validateGame(gameID)
        guard let saved = document.games[gameID]?.savedGames.first(where: { $0.id == id })
        else { throw StoreError.invalidSavedGame }
        var next = document
        next.games[gameID]!.checkpoint = saved.checkpoint
        next.games[gameID]!.playerName = saved.checkpoint.playerName
        try persist(next)
        return saved.checkpoint
    }

    func savePlayerName(_ playerName: String, for gameID: String) throws {
        try validateGame(gameID)
        var next = document
        next.games[gameID]!.playerName = Self.cleanName(playerName)
        try persist(next)
    }

    func saveCheckpoint(gameID: String, level: Int, score: Int, playerName: String, usedCheats: Bool = false) throws {
        try validateMission(gameID: gameID, level: level)
        var next = document
        let name = Self.cleanName(playerName)
        next.games[gameID]!.playerName = name
        next.games[gameID]!.checkpoint = Checkpoint(level: level, score: score, playerName: name, savedAt: Date(), usedCheats: usedCheats)
        try persist(next)
    }

    func clearCheckpoint(for gameID: String) throws {
        try validateGame(gameID)
        var next = document
        next.games[gameID]!.checkpoint = nil
        try persist(next)
    }

    /// Call once when a run ends. Supplying the same runID makes repeated completion callbacks idempotent.
    func recordScore(gameID: String, level: Int, score: Int, playerName: String, runID: UUID = UUID(),
                     usedCheats: Bool = false, completesSector: Bool = false) throws {
        try validateMission(gameID: gameID, level: level)
        if completesSector {
            guard level == Self.finalMissions[gameID] else { throw StoreError.invalidProgress }
            if let record = document.games[gameID],
               record.lastCompletion?.id == runID || record.scores.contains(where: { $0.id == runID }) {
                return
            }
        }
        var next = document
        let name = Self.cleanName(playerName)
        next.games[gameID]!.scores = highScores(for: gameID)
        let previous = next.games[gameID]!.scores.first { $0.id == runID }
        let entry = ScoreEntry(id: runID, playerName: name, score: score, level: level,
                               recordedAt: previous?.recordedAt ?? Date(), usedCheats: usedCheats)
        next.games[gameID]!.playerName = name
        next.games[gameID]!.scores.removeAll { $0.id == runID }
        next.games[gameID]!.scores.append(entry)
        next.games[gameID]!.scores.sort { Self.precedes($0, $1, gameID: gameID) }
        next.games[gameID]!.scores = Array(next.games[gameID]!.scores.prefix(30))
        if completesSector {
            next.games[gameID]!.lastCompletion = entry
            next.games[gameID]!.checkpoint = nil
            next.completedSectors.insert(gameID)
        }
        try persist(next)
    }

    func updateSettings(_ settings: Settings) throws {
        guard (1...5).contains(settings.sensitivityLevel), [0, 2, 4].contains(settings.antialiasingSamples) else { throw StoreError.invalidSettings }
        var next = document
        next.settings = settings
        next.settings.graphicsQuality = .remastered
        try persist(next)
    }

    private static func cleanName(_ value: String) -> String {
        let name = value.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? DLoc.text("玩家", "Player") : String(name.prefix(24))
    }
    private static func precedes(_ left: ScoreEntry, _ right: ScoreEntry, gameID: String) -> Bool {
        // BH2002 launcher 0x409980/0x4099a0 compares the returned level,
        // then 0x409a38 writes that level into SCORES. The core has no kill score.
        if gameID == "2000", left.score != right.score { return left.score > right.score }
        if left.level != right.level { return left.level > right.level }
        // Equal levels do not displace earlier entries in the 2002 insertion loop.
        return gameID == "2002" ? left.recordedAt < right.recordedAt : left.recordedAt > right.recordedAt
    }
    private func validateGame(_ id: String) throws {
        guard Self.supportedGames.contains(id) else { throw StoreError.invalidGame }
    }
    private func validateMission(gameID: String, level: Int) throws {
        guard let last = Self.finalMissions[gameID] else { throw StoreError.invalidGame }
        guard (1...last).contains(level) else { throw StoreError.invalidProgress }
    }

    /// Versions 1–4 let a run continue beyond its final mission. Reaching that
    /// next start proves victory. Retained manual slots can still replay the finale.
    private func migrateLoopedProgress(_ record: inout GameRecord, gameID: String, last: Int) -> Bool {
        var completed = record.scores.contains { $0.level > last }
        for i in record.savedGames.indices where record.savedGames[i].checkpoint.level > last {
            completed = true
            record.savedGames[i].checkpoint.level = last
        }
        if let checkpoint = record.checkpoint, checkpoint.level > last {
            // The old checkpoint has no run ID. Each sector has at most one such
            // automatic result, so use a stable migration ID across read-only loads.
            let recoveredID = UUID(uuidString: "578C69B7-AD47-4B59-A203-00000000" + gameID)!
            record.lastCompletion = record.scores.first {
                $0.level == last && $0.score == checkpoint.score && $0.playerName == checkpoint.playerName
                    && ($0.usedCheats ?? false) == (checkpoint.usedCheats ?? false)
            } ?? ScoreEntry(id: recoveredID, playerName: checkpoint.playerName, score: checkpoint.score, level: last,
                            recordedAt: checkpoint.savedAt, usedCheats: checkpoint.usedCheats)
            record.checkpoint = nil
            completed = true
        }
        return completed
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let bytes: Data
        do { bytes = try Data(contentsOf: fileURL) }
        catch {
            let reason = StoreError.unreadableFile(error.localizedDescription)
            writeBlock = reason; noticeText = { reason.localizedDescription }; return
        }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Header.self, from: bytes).version
            guard (1...Document.currentVersion).contains(version) else {
                let reason = StoreError.unsupportedVersion(version)
                writeBlock = reason; noticeText = { reason.localizedDescription }; return
            }
            var decoded = try decoder.decode(Document.self, from: bytes)
            guard (1...5).contains(decoded.settings.sensitivityLevel) else { throw StoreError.invalidSettings }
            for gameID in Self.supportedGames {
                var record = decoded.games[gameID] ?? GameRecord()
                if !record.playerName.isEmpty { record.playerName = Self.cleanName(record.playerName) }
                guard record.scores.allSatisfy({ $0.level >= 1 }) else { throw StoreError.invalidProgress }
                if version == 1, record.savedGames.isEmpty, let checkpoint = record.checkpoint {
                    // Preserve the only previous progress before a later new game can replace Continue.
                    // Loading is read-only; the migrated document is written by the next explicit mutation.
                    record.savedGames = [SavedGame(id: UUID(), slot: 1, name: DLoc.text("旧版进度 · 第 \(checkpoint.level) 关", "Previous checkpoint · Mission \(checkpoint.level)"),
                                                  checkpoint: checkpoint, savedAt: checkpoint.savedAt)]
                }
                guard record.savedGames.count <= Self.saveSlotCount(gameID: gameID),
                      Set(record.savedGames.map(\.slot)).count == record.savedGames.count,
                      Set(record.savedGames.map(\.id)).count == record.savedGames.count
                else { throw StoreError.invalidSavedGame }
                let finalMission = Self.finalMissions[gameID]!
                if version < 5, migrateLoopedProgress(&record, gameID: gameID, last: finalMission) {
                    decoded.completedSectors.insert(gameID)
                }
                if let checkpoint = record.checkpoint {
                    try validateMission(gameID: gameID, level: checkpoint.level)
                }
                for saved in record.savedGames {
                    guard (1...Self.saveSlotCount(gameID: gameID)).contains(saved.slot) else { throw StoreError.invalidSavedGame }
                    try validateMission(gameID: gameID, level: saved.checkpoint.level)
                }
                record.scores.sort { Self.precedes($0, $1, gameID: gameID) }
                record.scores = Array(record.scores.prefix(30))
                decoded.games[gameID] = record
            }
            if version == 3 {
                // The previous range awarded graduation without a missile kill.
                decoded.completedSectors.remove(DepthlineIdentity.trainingID)
            }
            decoded.version = Document.currentVersion
            document = decoded
        } catch {
            pendingCorruptBackup = true
            noticeText = { DLoc.text("本机存档损坏，已使用默认数据。下次保存前会保留原文件副本。", "The save file is damaged. Using default settings and progress. The original will be backed up on the next save.") }
        }
    }

    /// Commit to disk before publishing in-memory state so failed writes never look successful.
    private func persist(_ next: Document) throws {
        if let writeBlock { throw writeBlock }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if pendingCorruptBackup {
            let backup = directory.appendingPathComponent("campaigns.corrupt-\(UUID().uuidString).json")
            try fileManager.copyItem(at: fileURL, to: backup)
            pendingCorruptBackup = false
            noticeText = { DLoc.text("损坏的原存档已保留为 \(backup.lastPathComponent)。", "The damaged save was backed up as \(backup.lastPathComponent).") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        document = next
    }
}

/// Foundation-only regression checks; no app or window is created and real user data is untouched.
func campaignStoreSelfTest() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("BeachHeadStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw NSError(domain: "CampaignStoreTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let store = CampaignStore(directory: root)
    try require(CampaignStore.displayScore(gameID: "2000", score: -10) == "-100"
                && CampaignStore.displayScore(gameID: "2002", score: 10) == "10", "Original2000 displayed score units")
    try require(store.checkpoint(for: "2000") == nil && store.highScores(for: "2002").isEmpty, "Fresh data must be empty")
    try store.saveCheckpoint(gameID: "2000", level: 60, score: -10, playerName: "海防")
    try store.saveCheckpoint(gameID: "2002", level: 13, score: 700, playerName: "前线", usedCheats: true)
    let run = UUID()
    try store.recordScore(gameID: "2000", level: 8, score: 400, playerName: "海防", runID: run)
    try store.recordScore(gameID: "2000", level: 8, score: 400, playerName: "海防", runID: run)
    try store.recordScore(gameID: "2000", level: 9, score: 600, playerName: "测试", usedCheats: true)
    let settings = CampaignStore.Settings(soundEnabled: false, sensitivityLevel: 5, invertY: true, mouseAccelerationEnabled: true, musicEnabled: false, graphicsQuality: .remastered)
    try store.updateSettings(settings)
    let restored = CampaignStore(directory: root)
    try require(restored.checkpoint(for: "2000")?.level == 60 && restored.checkpoint(for: "2002")?.level == 13, "Game checkpoints must remain isolated, including the final mission")
    try require(restored.checkpoint(for: "2000")?.playerName == "海防" && restored.checkpoint(for: "2000")?.score == -10 && restored.checkpoint(for: "2002")?.score == 700, "Checkpoint values and score penalties must round-trip")
    try require(restored.settings == settings && restored.settings.sensitivityMultiplier == 1.5, "Settings must round-trip")
    try require(restored.checkpoint(for: "2002")?.usedCheats == true && restored.highScores(for: "2000").first?.usedCheats == true, "Local assisted-run markers must persist")
    try require(restored.highScores(for: "2000").map(\.score) == [600, 400] && restored.highScores(for: "2002").isEmpty, "Scores must sort, deduplicate and remain isolated")
    try restored.recordScore(gameID: "2002", level: 9, score: 9999, playerName: "旧版记录")
    try restored.recordScore(gameID: "2002", level: 20, score: 0, playerName: "原版关卡成绩")
    try require(CampaignStore(directory: root).highScores(for: "2002").map(\.level) == [20, 9], "2002 ranks by returned level even with legacy prototype scores")
    try restored.clearCheckpoint(for: "2000")
    try require(CampaignStore(directory: root).checkpoint(for: "2000") == nil && restored.checkpoint(for: "2002") != nil, "Clearing one checkpoint must preserve the other")
    let beforeInvalid = try Data(contentsOf: restored.fileURL)
    do {
        try restored.saveCheckpoint(gameID: "2000", level: 0, score: 0, playerName: "非法")
        throw NSError(domain: "CampaignStoreTest", code: 2)
    } catch is CampaignStore.StoreError { }
    try require(try Data(contentsOf: restored.fileURL) == beforeInvalid, "Invalid progress must not alter disk")

    var legacy = try JSONSerialization.jsonObject(with: beforeInvalid) as! [String: Any]
    var legacySettings = legacy["settings"] as! [String: Any]
    legacySettings.removeValue(forKey: "mouseAccelerationEnabled")
    legacySettings.removeValue(forKey: "graphicsQuality")
    legacySettings.removeValue(forKey: "antialiasingSamples")
    legacySettings.removeValue(forKey: "musicEnabled"); legacy["settings"] = legacySettings
    var legacyGames = legacy["games"] as! [String: [String: Any]]
    for key in legacyGames.keys {
        if var checkpoint = legacyGames[key]?["checkpoint"] as? [String: Any] { checkpoint.removeValue(forKey: "usedCheats"); legacyGames[key]?["checkpoint"] = checkpoint }
        if let scores = legacyGames[key]?["scores"] as? [[String: Any]] {
            legacyGames[key]?["scores"] = scores.map { entry -> [String: Any] in var value = entry; value.removeValue(forKey: "usedCheats"); return value }
        }
    }
    legacy["games"] = legacyGames
    try JSONSerialization.data(withJSONObject: legacy).write(to: restored.fileURL)
    let migrated = CampaignStore(directory: root)
    try require(migrated.settings.antialiasingSamples == 4, "Existing profiles retain the game's prior 4x antialiasing")
    try require(migrated.storageNotice == nil && !migrated.settings.mouseAccelerationEnabled && migrated.settings.musicEnabled && migrated.settings.graphicsQuality == .remastered && migrated.checkpoint(for: "2002")?.usedCheats == nil,
                "Older settings and scores decode without new fields")
    var oldQuality = legacy
    var oldQualitySettings = oldQuality["settings"] as! [String: Any]
    oldQualitySettings["graphicsQuality"] = "nostalgic"; oldQuality["settings"] = oldQualitySettings
    try JSONSerialization.data(withJSONObject: oldQuality).write(to: restored.fileURL)
    try require(CampaignStore(directory: root).settings.graphicsQuality == .remastered,
                "Previously stored nostalgia quality migrates to the requested single remastered presentation")

    let corrupt = Data("{broken checkpoint".utf8)
    try corrupt.write(to: restored.fileURL)
    let recovered = CampaignStore(directory: root)
    try require(recovered.storageNotice != nil && recovered.checkpoint(for: "2002") == nil, "Corrupt file must recover safely")
    try require(try Data(contentsOf: recovered.fileURL) == corrupt, "Load must leave corrupt bytes untouched")
    try recovered.updateSettings(CampaignStore.Settings())
    let backups = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("campaigns.corrupt-") }
    try require(backups.count == 1 && (try Data(contentsOf: backups[0])) == corrupt, "Corrupt source must be retained before writing")
    let future = Data("{\"version\":999}".utf8)
    try future.write(to: recovered.fileURL)
    let futureStore = CampaignStore(directory: root)
    do {
        try futureStore.updateSettings(settings)
        throw NSError(domain: "CampaignStoreTest", code: 3)
    } catch is CampaignStore.StoreError { }
    try require(try Data(contentsOf: futureStore.fileURL) == future, "Unsupported schema must not be overwritten")
    try campaignSaveSlotsSelfTest(directory: root.appendingPathComponent("named-slots"))
    try campaignCompletionSelfTest(directory: root.appendingPathComponent("completions"))
    print("PASS: campaign storage round-trip, game isolation, sorted real scores, idempotent results, invalid progress, corrupt backup and future-schema protection")
}

private func campaignCompletionSelfTest(directory: URL) throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CampaignCompletionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let training = DepthlineIdentity.trainingID
    let store = CampaignStore(directory: directory)
    try store.saveCheckpoint(gameID: "2000", level: 60, score: -15, playerName: "海防", usedCheats: true)
    let slot = try store.saveCurrentCheckpoint(gameID: "2000", name: "海岸备份")
    try store.saveCheckpoint(gameID: "2002", level: 99, score: 100, playerName: "前线")
    try store.recordScore(gameID: "2002", level: 99, score: 75, playerName: "旧记录")
    try require(!store.isSectorCompleted("2000") && !store.isSectorCompleted("2002"), "Reaching the finale does not prove completion")
    let ordinaryHills = store.checkpoint(for: "2002")
    for (game, level) in [("2000", 61), ("2002", 100)] {
        do {
            try store.saveCheckpoint(gameID: game, level: level, score: 0, playerName: "Test")
            throw NSError(domain: "CampaignCompletionTest", code: 2)
        } catch CampaignStore.StoreError.invalidProgress { }
    }

    // Produce a real v4 layout with a looped Continue, manual slot and historical score.
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
    legacy["version"] = 4
    var games = legacy["games"] as! [String: [String: Any]]
    var checkpoint = games["2000"]!["checkpoint"] as! [String: Any]
    checkpoint["level"] = 107
    games["2000"]!["checkpoint"] = checkpoint
    var slots = games["2000"]!["savedGames"] as! [[String: Any]]
    slots[0]["checkpoint"] = checkpoint
    games["2000"]!["savedGames"] = slots
    var scores = games["2002"]!["scores"] as! [[String: Any]]
    scores[0]["level"] = 103
    games["2002"]!["scores"] = scores
    legacy["games"] = games
    let bytes = try JSONSerialization.data(withJSONObject: legacy)
    try bytes.write(to: store.fileURL)
    let migrated = CampaignStore(directory: directory)
    try require(try Data(contentsOf: store.fileURL) == bytes, "Migration must leave old disk bytes intact until a mutation")
    try require(migrated.checkpoint(for: "2000") == nil && migrated.isSectorCompleted("2000"),
                "Looped Continue becomes a finished campaign")
    let recovered = migrated.highScores(for: "2000")
    try require(recovered.count == 1 && recovered[0].level == 60 && recovered[0].score == -15
                && recovered[0].usedCheats == true && recovered[0].recordedAt == slot.checkpoint.savedAt
                && recovered == CampaignStore(directory: directory).highScores(for: "2000"),
                "Recover the signed result without duplicating it on repeated reads")
    try require(migrated.savedGames(for: "2000") == [slot], "Preserve slot ID, order, name, score, cheat flag and both dates")
    try require(migrated.checkpoint(for: "2002") == ordinaryHills && migrated.isSectorCompleted("2002")
                && migrated.highScores(for: "2002").first?.level == 103, "Keep ordinary Continue and old historical scores")
    try migrated.loadSavedGame(gameID: "2000", id: slot.id)
    let run = UUID()
    try migrated.recordScore(gameID: "2000", level: 60, score: 350, playerName: "海防", runID: run, usedCheats: true, completesSector: true)
    let ended = CampaignStore(directory: directory)
    try require(ended.checkpoint(for: "2000") == nil && ended.isSectorCompleted("2000")
                && ended.highScores(for: "2000").map(\.score) == [350, -15],
                "Final result, completion flag and cleared Continue persist together")
    try ended.saveCheckpoint(gameID: "2000", level: 1, score: 0, playerName: "海防")
    try ended.recordScore(gameID: "2000", level: 60, score: 350, playerName: "海防", runID: run, usedCheats: true, completesSector: true)
    try require(ended.checkpoint(for: "2000")?.level == 1 && ended.highScores(for: "2000").count == 2,
                "A repeated victory callback cannot clear a newer run")
    try ended.markSectorCompleted(training)
    let marked = try Data(contentsOf: ended.fileURL)
    try ended.markSectorCompleted(training)
    try require(try Data(contentsOf: ended.fileURL) == marked, "Completing training twice is idempotent")
    let reopened = CampaignStore(directory: directory)
    try require((CampaignStore.supportedGames + [training]).allSatisfy(reopened.isSectorCompleted), "Completion flags persist on restart")
    var previousCourse = try JSONSerialization.jsonObject(with: Data(contentsOf: reopened.fileURL)) as! [String: Any]
    previousCourse["version"] = 3
    let previousBytes = try JSONSerialization.data(withJSONObject: previousCourse)
    try previousBytes.write(to: reopened.fileURL)
    let revised = CampaignStore(directory: directory)
    try require(!revised.isSectorCompleted(training) && CampaignStore.supportedGames.allSatisfy(revised.isSectorCompleted)
                && revised.settings == reopened.settings, "Updating the curriculum resets only the old training flag")
    for id in CampaignStore.supportedGames {
        try require(revised.playerName(for: id) == reopened.playerName(for: id)
                    && revised.checkpoint(for: id) == reopened.checkpoint(for: id)
                    && revised.savedGames(for: id) == reopened.savedGames(for: id)
                    && revised.highScores(for: id) == reopened.highScores(for: id), "Keep existing records for " + id)
    }
    try require(try Data(contentsOf: revised.fileURL) == previousBytes, "Curriculum migration is read-only on launch")
    try revised.updateSettings(revised.settings)
    let awaitingGraduation = CampaignStore(directory: directory)
    try require(!awaitingGraduation.isSectorCompleted(training), "Old graduation must stay cleared on restart")
    try awaitingGraduation.markSectorCompleted(training)
    try require((CampaignStore.supportedGames + [training]).allSatisfy(CampaignStore(directory: directory).isSectorCompleted),
                "Graduation from the revised course survives future launches")
    print("PASS: sector completion flags, legacy progress, final-day boundary, replay and revised training graduation")
}

private func campaignSaveSlotsSelfTest(directory: URL) throws {
    func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: "CampaignSaveSlotsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let store = CampaignStore(directory: directory)
    do {
        try store.saveCurrentCheckpoint(gameID: "2000", name: "没有进度")
        throw NSError(domain: "CampaignSaveSlotsTest", code: 2)
    } catch CampaignStore.StoreError.noCheckpoint { }
    try require(!FileManager.default.fileExists(atPath: store.fileURL.path), "Rejected save without checkpoint must not create data")
    try store.saveCheckpoint(gameID: "2000", level: 24, score: -15, playerName: "海防", usedCheats: true)
    let oldStart = store.checkpoint(for: "2000")!
    let first = try store.saveCurrentCheckpoint(gameID: "2000", name: "第一次防守")
    try store.saveCheckpoint(gameID: "2000", level: 60, score: 912, playerName: "下一次", usedCheats: false)
    let second = try store.saveCurrentCheckpoint(gameID: "2000", name: "海滩末关")
    try store.saveCheckpoint(gameID: "2002", level: 96, score: 0, playerName: "前线")
    let other = try store.saveCurrentCheckpoint(gameID: "2002", name: "夜战")
    let loaded = try store.loadSavedGame(gameID: "2000", id: first.id)
    try require(loaded == oldStart && store.playerName(for: "2000") == "海防", "Loading must preserve exact level-start score, name, cheat marker and timestamp")
    let disk = try Data(contentsOf: store.fileURL)
    do {
        try store.loadSavedGame(gameID: "2000", id: other.id)
        throw NSError(domain: "CampaignSaveSlotsTest", code: 3)
    } catch CampaignStore.StoreError.invalidSavedGame { }
    do {
        try store.saveCurrentCheckpoint(gameID: "2000", name: "误覆盖", replacingID: other.id)
        throw NSError(domain: "CampaignSaveSlotsTest", code: 4)
    } catch CampaignStore.StoreError.invalidSavedGame { }
    try require(try Data(contentsOf: store.fileURL) == disk, "Cross-game load or overwrite must leave data unchanged")
    let replacement = try store.saveCurrentCheckpoint(gameID: "2000", name: "明确覆盖", replacingID: second.id)
    try require(replacement.id == second.id && replacement.slot == 2 && replacement.checkpoint == oldStart,
                "Explicit overwrite must retain the selected identity and slot")
    for _ in 2..<CampaignStore.saveSlotCount(gameID: "2000") { try store.saveCurrentCheckpoint(gameID: "2000", name: "保留") }
    for _ in 1..<CampaignStore.saveSlotCount(gameID: "2002") { try store.saveCurrentCheckpoint(gameID: "2002", name: "保留") }
    let full = try Data(contentsOf: store.fileURL)
    for gameID in CampaignStore.supportedGames {
        do {
            try store.saveCurrentCheckpoint(gameID: gameID, name: "满槽")
            throw NSError(domain: "CampaignSaveSlotsTest", code: 5)
        } catch CampaignStore.StoreError.saveSlotsFull(let count) {
            try require(count == CampaignStore.saveSlotCount(gameID: gameID), "Original per-version save capacities")
        }
    }
    try require(try Data(contentsOf: store.fileURL) == full, "A full list must not evict or overwrite saved progress")
    try store.clearCheckpoint(for: "2000")
    let restored = CampaignStore(directory: directory)
    try require(restored.savedGames(for: "2000").map(\.slot) == Array(1...12)
                && restored.savedGames(for: "2002").map(\.slot) == Array(1...20)
                && restored.checkpoint(for: "2000") == nil, "Manual saves persist independently from Continue and preserve original capacities")
    try require(try restored.loadSavedGame(gameID: "2000", id: first.id) == oldStart, "Saved game survives restart/new-run checkpoint removal")

    var legacy = try JSONSerialization.jsonObject(with: full) as! [String: Any]
    legacy["version"] = 1
    var games = legacy["games"] as! [String: [String: Any]]
    for gameID in CampaignStore.supportedGames { games[gameID]?.removeValue(forKey: "savedGames") }
    legacy["games"] = games
    let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
    try legacyBytes.write(to: store.fileURL)
    let migrated = CampaignStore(directory: directory)
    try require(migrated.savedGames(for: "2000").first?.checkpoint == oldStart
                && migrated.savedGames(for: "2002").first?.checkpoint.level == 96,
                "Version1 single checkpoint must become a retained slot without losing Continue")
    try require(try Data(contentsOf: store.fileURL) == legacyBytes, "Migration must not write on read")
    try migrated.savePlayerName("新名字", for: "2000")
    let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
    try require(upgraded["version"] as? Int == 5 && CampaignStore(directory: directory).savedGames(for: "2000").count == 1,
                "Next explicit write commits the current schema; repeated reload must not duplicate migrated slots")
    print("PASS original named saves:12/20 slots, explicit overwrite, game isolation, level-start integrity, legacy migration and no silent eviction")
}
