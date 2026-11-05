import AppKit

extension NSFont {
    /// Keep short HUD labels on one line when a translation needs more room.
    func fitting(_ text: String, in width: CGFloat) -> NSFont {
        let available = max(1, width - 5)
        let measured = (text as NSString).size(withAttributes: [.font: self]).width
        guard measured > available else { return self }
        let reduced = (pointSize * available / measured * 2).rounded(.down) / 2
        return NSFontManager.shared.convert(self, toSize: max(10.5, reduced))
    }
}
