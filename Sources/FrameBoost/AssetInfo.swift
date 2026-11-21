import AVFoundation
import CoreGraphics

/// Video file properties, read with the asynchronous AVFoundation API
/// (the synchronous getters such as `tracks(withMediaType:)` are deprecated since macOS 13).
struct AssetInfo {
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let fps: Double
    /// size as shown (rotation applied)
    let displaySize: CGSize
    /// size of the decoded frames
    let naturalSize: CGSize
    let duration: Double

    private final class Box: @unchecked Sendable { var info: AssetInfo? }

    /// Blocks until the properties are loaded (a few milliseconds for a local file).
    /// Must not be called from inside Swift concurrency; plain threads and the main thread are fine.
    static func load(_ asset: AVURLAsset) -> AssetInfo? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let props = try? await video.load(.nominalFrameRate, .naturalSize, .preferredTransform) else { return }
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let shown = CGRect(origin: .zero, size: props.1).applying(props.2)
            box.info = AssetInfo(video: video, audio: audio,
                                 fps: props.0 > 0 ? Double(props.0) : 30,
                                 displaySize: CGSize(width: abs(shown.width), height: abs(shown.height)),
                                 naturalSize: props.1,
                                 duration: seconds.isFinite ? seconds : 0)
        }
        done.wait()
        return box.info
    }
}
