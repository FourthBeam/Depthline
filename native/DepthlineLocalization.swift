import Foundation

enum DepthlineLanguage: String, Codable, CaseIterable {
    case system, simplifiedChinese, traditionalChinese, english
    case korean, japanese, french, spanish, portuguese, russian, indonesian, vietnamese, thai

    static let menuOrder: [Self] = [.english, .system, .simplifiedChinese, .traditionalChinese, .korean,
                                    .japanese, .french, .spanish, .portuguese, .russian, .indonesian, .vietnamese, .thai]
    var menuTitle: String {
        switch self {
        case .system: return DLoc.text("跟随系统", "System default")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .indonesian: return "Bahasa Indonesia"
        case .vietnamese: return "Tiếng Việt"
        case .thai: return "ภาษาไทย"
        }
    }

    var tag: String {
        switch self {
        case .system, .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .korean: return "ko"
        case .japanese: return "ja"
        case .french: return "fr"
        case .spanish: return "es"
        case .portuguese: return "pt"
        case .russian: return "ru"
        case .indonesian: return "id"
        case .vietnamese: return "vi"
        case .thai: return "th"
        }
    }

    func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        guard let primary = preferredLanguages.first else { return .english }
        let tags = primary.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        guard let base = tags.first else { return .english }
        if base != "zh" {
            return Self.menuOrder.first { $0 != .system && $0.tag == base } ?? .english
        }
        if let script = tags.dropFirst().first(where: { $0.count == 4 && $0.allSatisfy(\.isLetter) }) {
            if script == "hant" { return .traditionalChinese }
            return script == "hans" ? .simplifiedChinese : .english
        }
        // macOS can return region-only tags such as zh_CN and zh_TW.
        return tags.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
    }
}

// Convert only authored copy. Interpolated player names, save titles and
// key labels are appended verbatim, whichever script the player selected.
struct DepthlineChineseCopy: ExpressibleByStringInterpolation {
    let value: String
    init(stringLiteral value: String) { self.value = DLoc.chineseLiteral(value) }
    init(stringInterpolation: StringInterpolation) { value = stringInterpolation.value }
    struct StringInterpolation: StringInterpolationProtocol {
        var value = ""
        init(literalCapacity: Int, interpolationCount: Int) { value.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { value += DLoc.chineseLiteral(literal) }
        mutating func appendInterpolation<T>(_ item: T) { value += String(describing: item) }
    }
}

struct DepthlineEnglishCopy: ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral: String) { key = stringLiteral; arguments = [] }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ item: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: item))
        }
    }

    func render(_ template: String) -> String {
        guard !arguments.isEmpty else { return template }
        // Read slots only from the translation. Braces in a player's own
        // text must never be read back as formatting instructions.
        var output = "", remaining = template[...]
        while let start = remaining.firstIndex(of: "{"), let end = remaining[start...].firstIndex(of: "}") {
            output += remaining[..<start]
            if let index = Int(remaining[remaining.index(after: start)..<end]), arguments.indices.contains(index) {
                output += arguments[index]
            } else {
                output += remaining[start...end]
            }
            remaining = remaining[remaining.index(after: end)...]
        }
        return output + remaining
    }
}

enum DLoc {
    static var language = DepthlineLanguage.system {
        didSet { refreshSystemPreference() }
    }
    private(set) static var resolvedLanguage = DepthlineLanguage.system.resolved(preferredLanguages: Locale.preferredLanguages)
    private static var catalog = loadCatalog(for: resolvedLanguage)

    static func refreshSystemPreference() {
        let next = language.resolved(preferredLanguages: Locale.preferredLanguages)
        guard resolvedLanguage != next else { return }
        resolvedLanguage = next
        catalog = loadCatalog(for: next)
    }

    private static func loadCatalog(for language: DepthlineLanguage) -> [String: String] {
        guard let url = Bundle.main.url(forResource: language.tag, withExtension: "json", subdirectory: "locales"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func text(_ zh: @autoclosure () -> DepthlineChineseCopy, _ en: @autoclosure () -> DepthlineEnglishCopy) -> String {
        if resolvedLanguage == .simplifiedChinese || resolvedLanguage == .traditionalChinese { return zh().value }
        let phrase = en()
        return phrase.render(catalog[phrase.key] ?? phrase.key)
    }

    private static let traditionalCache = NSCache<NSString, NSString>()
    fileprivate static func chineseLiteral(_ simplified: String) -> String {
        guard resolvedLanguage == .traditionalChinese, !simplified.isEmpty else { return simplified }
        let key = simplified as NSString
        if let cached = traditionalCache.object(forKey: key) { return cached as String }
        var regional = simplified
        for (source, target) in [("鼠标", "滑鼠"), ("设置", "設定"), ("画质", "畫質"),
                                 ("导弹", "飛彈"), ("机枪", "機槍"), ("准星", "準星"),
                                 ("默认", "預設"), ("关卡", "關卡"), ("退出", "離開"),
                                 ("抗锯齿", "反鋸齒"), ("按键", "按鍵"), ("快捷键", "快速鍵"),
                                 ("加载", "載入"), ("点击", "點選"), ("提交", "送出"), ("秘籍", "密技")] {
            regional = regional.replacingOccurrences(of: source, with: target)
        }
        let result = regional.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? regional
        traditionalCache.setObject(result as NSString, forKey: key)
        return result
    }

    static var locale: Locale { Locale(identifier: resolvedLanguage.tag) }
}
