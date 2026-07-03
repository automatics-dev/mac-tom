import SwiftUI
import AVKit

// MARK: - Player Video View

struct PlayerVideoView: NSViewRepresentable {
    @ObservedObject var playerManager: PlayerManager

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = playerManager.player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = playerManager.player
    }
}

final class PlayerLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}
