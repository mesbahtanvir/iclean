#if DEBUG
    import AVFoundation
    import CleanupKit
    import CoreVideo

    /// DEBUG only: lets the demo library play a video, so UI tests and screenshots can show the
    /// viewer's play control. Every demo video plays a one second clip drawn here, except `vid-sd`,
    /// which stands for a video that is only in iCloud: it has no file on the device, so the viewer
    /// shows its still frame with no play control.
    extension DemoPhotoLibrary {
        func playerItem(for assetID: String) async -> PlayableVideo? {
            guard assetID.hasPrefix("vid"), assetID != "vid-sd" else { return nil }
            guard let url = await DemoClip.url else { return nil }
            return PlayableVideo(item: AVPlayerItem(url: url))
        }
    }

    private enum DemoClip {
        /// Written once into the temporary folder.
        static var url: URL? {
            get async {
                let url = FileManager.default.temporaryDirectory.appending(path: "iclean-demo.mp4")
                if FileManager.default.fileExists(atPath: url.path) { return url }
                return await write(to: url) ? url : nil
            }
        }

        private static func write(to url: URL) async -> Bool {
            let width = 320
            let height = 240
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
                return false
            }
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { return false }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { return false }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let bytes = CVPixelBufferGetBytesPerRow(buffer) * height
                    // A band of colour that moves, so it is clear the clip is playing.
                    memset(base, 0x55, bytes)
                    let row = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<height {
                        let pixels = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                        for x in stride(from: 0, to: width, by: 1) where (x + frame * 8) % 80 < 40 {
                            pixels[x * 4] = 0xE0
                            pixels[x * 4 + 1] = 0x80
                            pixels[x * 4 + 2] = 0x30
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(
                    buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
            }
            input.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed
        }
    }
#endif
