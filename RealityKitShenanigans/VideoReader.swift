import AVFoundation

final class VideoReader {
    var sampleRead: ((CMSampleBuffer) -> Void)?
    
    private var assetReader: AVAssetReader? = nil
    private var assetReaderAudio: AVAssetReader? = nil
    private var output: AVAssetReaderTrackOutput? = nil
    private var outputAudio: AVAssetReaderTrackOutput? = nil
    private var nominalFrameRate: Float
    private var timer: Timer?
    private var lastSample: CMSampleBuffer? = nil
    let audioEngine = AVAudioEngine()
    let audioPlayer = AVAudioPlayerNode()
    private var mixer: AVAudioMixerNode = AVAudioMixerNode()
    private var downAudioFormat: AVAudioFormat? = nil

    init?() {
        guard
            let url = Bundle.main.url(forResource: "badapple", withExtension: "mp4")
        else { return nil }
        let urlAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        nominalFrameRate = 24.0
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true)
            try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setMode(.voiceChat)
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("Failed to set the audio session configuration?")
        }
        
        self.audioEngine.attach(self.mixer)
        self.audioEngine.connect(self.mixer, to: self.audioEngine.outputNode, format: nil)
        // !important - start the engine *before* setting up the player nodes
        try! self.audioEngine.start()
        
        self.audioEngine.attach(self.audioPlayer)
        // Notice the output is the mixer in this case
        self.audioEngine.connect(self.audioPlayer, to: self.mixer, format: nil)
        
        downAudioFormat = self.audioPlayer.outputFormat(forBus: AVAudioNodeBus())
        
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            var trackTry = try! await urlAsset.loadTracks(withMediaType: .video).first
            var trackTryAudio = try! await urlAsset.loadTracks(withMediaType: .audio).first
            
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
                        String(kCVPixelBufferMetalCompatibilityKey): true,
                        //String(kCVPixelBufferPoolMinimumBufferCountKey): 3,
                    ]

                    output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    output!.alwaysCopiesSampleData = false
                    output!.supportsRandomAccess = false
                }
            }
            
            if let track = trackTryAudio {
                if let assetReader = assetReader {
                    let settings: [String: Any] = [
                        String(AVFormatIDKey): kAudioFormatLinearPCM,
                    ]

                    outputAudio = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    outputAudio!.alwaysCopiesSampleData = false
                    outputAudio!.supportsRandomAccess = false
                    outputAudio!.audioTimePitchAlgorithm = .spectral
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
        guard assetReader!.canAdd(outputAudio!) else { return nil }
        assetReader!.add(outputAudio!)
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
    
    func sampleToPCM(_ sampleBuffer: CMSampleBuffer?) -> AVAudioPCMBuffer? {
        var sDescr: CMFormatDescription? = nil
        if let sampleBuffer = sampleBuffer {
            sDescr = CMSampleBufferGetFormatDescription(sampleBuffer)
        }

        var numSamples: CMItemCount? = nil
        if let sampleBuffer = sampleBuffer {
            numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        }

        var avFmt: AVAudioFormat? = nil
        avFmt = AVAudioFormat(cmAudioFormatDescription: sDescr!)

        var pcmBuffer: AVAudioPCMBuffer? = nil
        if let avFmt = avFmt {
            //let fmt = self.audioPlayer.outputFormat(forBus: AVAudioNodeBus())
            pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFmt, frameCapacity: AVAudioFrameCount(UInt(numSamples ?? 0)))
        }

        pcmBuffer?.frameLength = AVAudioFrameCount(UInt(numSamples ?? 0))
        if let sampleBuffer = sampleBuffer, let mutableAudioBufferList = pcmBuffer?.mutableAudioBufferList {
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples ?? 0), into: mutableAudioBufferList)
        }

        return pcmBuffer
    }
    
    private func playConvertedAudio(_ buffer: AVAudioPCMBuffer) {
        let originalAudioFormat: AVAudioFormat = buffer.format
        let downSampleRate: Double = downAudioFormat!.sampleRate
        let ratio: Float = Float(
            originalAudioFormat.sampleRate
        )/Float(
            downSampleRate
        )
        let converter: AVAudioConverter = AVAudioConverter(from: buffer.format, to: self.downAudioFormat!)!
        let capacity = UInt32(Float(buffer.frameCapacity)/ratio)
    
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: self.downAudioFormat!,
            frameCapacity: capacity) else {
          print("Failed to create new buffer")
          return
        }

        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
          outStatus.pointee = AVAudioConverterInputStatus.haveData
          return buffer
        }

        var error: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(
            to: outputBuffer,
            error: &error,
            withInputFrom: inputBlock)

        switch status {
        case .error:
          if let unwrappedError: NSError = error {
            print("Error \(unwrappedError)")
          }
          return
        default: break
        }

        self.audioPlayer.scheduleBuffer(outputBuffer, completionHandler: nil)
    }
    
    func readSamplesManually() {
        if self.assetReader!.status != .reading {
            assetReader!.startReading()
        }
        guard self.assetReader!.status == .reading else { return }

        if lastSample != nil {
            self.sampleRead?(lastSample!)
        }
        
        guard let audioSample = self.outputAudio!.copyNextSampleBuffer() else {
            //print("output.copyNextSampleBuffer() is nil for audio")
            return
        }
        let pcm = sampleToPCM(audioSample)
        if let pcm = pcm {
            DispatchQueue.global(qos: .background).async {
                self.playConvertedAudio(pcm)
                if !self.audioPlayer.isPlaying { self.audioPlayer.play() }
            }
        }
    }
    
    func readSamplesNext() {
        if self.assetReader!.status != .reading {
            assetReader!.startReading()
        }
        guard self.assetReader!.status == .reading else { return }

        guard let sample = self.output!.copyNextSampleBuffer() else {
            print("output.copyNextSampleBuffer() is nil")
            return
        }
        lastSample = sample
        lastSampleTime = CACurrentMediaTime()

        //self.sampleRead?(sample)
        //print("sample?", CACurrentMediaTime(), CACurrentMediaTime() - lastSampleTime)
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
