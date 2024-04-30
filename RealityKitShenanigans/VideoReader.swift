import AVFoundation

final class VideoReader {
    var sampleRead: ((CMSampleBuffer) -> Void)?
    
    private var assetReader: AVAssetReader? = nil
    private var output: AVAssetReaderTrackOutput? = nil
    private var nominalFrameRate: Float
    private var timer: Timer?

    init?() {
        guard
            let url = Bundle.main.url(forResource: "badapple", withExtension: "mp4")
        else { return nil }
        let urlAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        nominalFrameRate = 24.0
        
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            var trackTry = try! await urlAsset.loadTracks(withMediaType: .video).first
            
            if let track = trackTry {

                nominalFrameRate = (1 / track.nominalFrameRate)

                do {
                    if let asset = track.asset {
                        assetReader = try AVAssetReader(asset: asset)
                    }
                } catch {
                    print(error)
                    //return nil
                }
                
                if let assetReader = assetReader {
                    let settings: [String: Any] = [
                        String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
                        String(kCVPixelBufferMetalCompatibilityKey): true
                    ]

                    output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    output!.alwaysCopiesSampleData = false
                    output!.supportsRandomAccess = false
                }
            }

            semaphore.signal()
        }
        semaphore.wait()
        
        if assetReader == nil {
            return nil
        }

        guard assetReader!.canAdd(output!) else { return nil }
        assetReader!.add(output!)
    }
    
    var lastSampleTime: Double = 0.0

    func readSamples() {
        timer = Timer.scheduledTimer(withTimeInterval: Double(nominalFrameRate), repeats: true, block: { [weak self] currentTimer in
            guard let self = self else {
                currentTimer.invalidate()
                return
            }

            guard self.assetReader!.status == .reading else { return }

            guard let sample = self.output!.copyNextSampleBuffer() else {
                print("output.copyNextSampleBuffer() is nil")
                currentTimer.invalidate()
                self.timer?.invalidate()
                self.timer = nil
                return
            }

            self.sampleRead?(sample)
            //print("sample?", CACurrentMediaTime(), CACurrentMediaTime() - lastSampleTime)
            lastSampleTime = CACurrentMediaTime()
        })

        if !assetReader!.startReading() {
            timer?.invalidate()
            timer = nil
        }
    }
    
    func readSamplesManually() {
        if self.assetReader!.status != .reading {
            assetReader!.startReading()
        }
        guard self.assetReader!.status == .reading else { return }

        guard let sample = self.output!.copyNextSampleBuffer() else {
            print("output.copyNextSampleBuffer() is nil")
            return
        }

        self.sampleRead?(sample)
        //print("sample?", CACurrentMediaTime(), CACurrentMediaTime() - lastSampleTime)
        lastSampleTime = CACurrentMediaTime()
    }

    private func printAssetReaderStatus() {
        switch self.assetReader!.status {
        case .reading: print("reading")
        case .cancelled: print("canceled")
        case .completed: print("completed")
        case .failed: print("failed")
        case .unknown: print("unknown")
        @unknown default:
            print("@unknown default")
        }
    }
}
