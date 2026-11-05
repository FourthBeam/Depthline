import AppKit

enum DepthlineQuit {
    static func request(in window: NSWindow?, onConfirm: @escaping () -> Void = { NSApp.terminate(nil) }) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = DLoc.text("确定退出《纵深防线》？", "Quit Depthline?")
        let cancel = alert.addButton(withTitle: DLoc.text("取消", "Cancel"))
        cancel.setAccessibilityIdentifier("quit-cancel")
        cancel.keyEquivalent = "\u{1b}"
        let quit = alert.addButton(withTitle: DLoc.text("退出", "Quit"))
        quit.setAccessibilityIdentifier("quit-confirm")
        quit.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { onConfirm() }
        }
    }
}
