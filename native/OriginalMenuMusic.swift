import AppKit

/// Plays the original tracker song rendered to PCM at asset-build time. Menu
/// music has its own setting in both launchers and never becomes battlefield SFX.
final class OriginalMenuMusic: NSObject, NSSoundDelegate {
    private let resourceRoot: URL
    private var sound: NSSound?
    private var loopSound: NSSound?
    private(set) var currentGameID: String?
    private(set) var loadFailure: String?

    init(resourceRoot: URL) { self.resourceRoot = resourceRoot; super.init() }

    func update(gameID: String, enabled: Bool, visible: Bool) {
        guard enabled, visible else { stop(); return }
        if currentGameID == gameID, sound?.isPlaying == true { return }
        stop()
        let url = resourceRoot.appendingPathComponent(gameID).appendingPathComponent("music.wav")
        guard let song = NSSound(contentsOf: url, byReference: false) else {
            loadFailure = url.path
            return
        }
        let loopURL = url.deletingLastPathComponent().appendingPathComponent("music-loop.wav")
        loopSound = NSSound(contentsOf: loopURL, byReference: false)
        loopSound?.loops = true
        loopSound?.volume = 1
        song.loops = loopSound == nil
        song.delegate = self
        song.volume = 1
        sound = song
        currentGameID = gameID
        loadFailure = nil
        song.play()
    }

    func stop() {
        sound?.delegate = nil
        sound?.stop()
        sound = nil
        loopSound = nil
        currentGameID = nil
    }

    func sound(_ completedSound: NSSound, didFinishPlaying finished: Bool) {
        guard finished, completedSound === sound, currentGameID != nil, let loop = loopSound else { return }
        completedSound.delegate = nil
        sound = loop
        loopSound = nil
        loop.play()
    }

    deinit { stop() }
}
