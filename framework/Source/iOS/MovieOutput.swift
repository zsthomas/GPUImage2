import AVFoundation

public protocol AudioEncodingTarget {
    func activateAudioTrack()
    func processAudioBuffer(_ sampleBuffer:CMSampleBuffer)
}

public class MovieOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    
    let assetWriter:AVAssetWriter
    let assetWriterVideoInput:AVAssetWriterInput
    var assetWriterAudioInput:AVAssetWriterInput?
    let assetWriterPixelBufferInput:AVAssetWriterInputPixelBufferAdaptor
    let size:Size
    private var isRecording = false
    private var videoEncodingIsFinished = false
    private var audioEncodingIsFinished = false
    private var startTime:CMTime?
    private var previousFrameTime = kCMTimeNegativeInfinity
    private var previousAudioTime = kCMTimeNegativeInfinity
    private var encodingLiveVideo:Bool
    
    public init(URL:Foundation.URL, size:Size, fileType:String = AVFileTypeQuickTimeMovie, liveVideo:Bool = false, settings:[String:AnyObject]? = nil) throws {
        self.size = size
        assetWriter = try AVAssetWriter(url:URL, fileType:fileType)
        
        // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
        assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000)
        
        var localSettings:[String:AnyObject]
        if let settings = settings {
            localSettings = settings
        } else {
            localSettings = [String:AnyObject]()
        }
        
        localSettings[AVVideoWidthKey] = localSettings[AVVideoWidthKey] ?? NSNumber(value:size.width)
        localSettings[AVVideoHeightKey] = localSettings[AVVideoHeightKey] ?? NSNumber(value:size.height)
        localSettings[AVVideoCodecKey] =  localSettings[AVVideoCodecKey] ?? AVVideoCodecH264 as NSString
        
        assetWriterVideoInput = AVAssetWriterInput(mediaType:AVMediaTypeVideo, outputSettings:localSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = liveVideo
        encodingLiveVideo = liveVideo
        
        // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
        let sourcePixelBufferAttributesDictionary:[String:AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_32BGRA)),
                                                                        kCVPixelBufferWidthKey as String:NSNumber(value:size.width),
                                                                        kCVPixelBufferHeightKey as String:NSNumber(value:size.height)]
        
        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:assetWriterVideoInput, sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary)
        assetWriter.add(assetWriterVideoInput)
    }
    
    public func startRecording() {
        startTime = nil
        isRecording = true
        sharedImageProcessingContext.runOperationSynchronously{
            // starting the recording before assets are ready will cause issues, better to let the isRecording boolean let the assets start the recording.
            // self.isRecording = self.assetWriter.startWriting()
        }
    }
    
    public func finishRecording(_ completionCallback:(() -> Void)? = nil) {
        sharedImageProcessingContext.runOperationSynchronously{
            self.isRecording = false
            
            if (self.assetWriter.status == .completed || self.assetWriter.status == .cancelled || self.assetWriter.status == .unknown) {
                sharedImageProcessingContext.runOperationAsynchronously{
                    completionCallback?()
                }
                return
            }
            if ((self.assetWriter.status == .writing) && (!self.videoEncodingIsFinished)) {
                self.videoEncodingIsFinished = true
                self.assetWriterVideoInput.markAsFinished()
            }
            if ((self.assetWriter.status == .writing) && (!self.audioEncodingIsFinished)) {
                self.audioEncodingIsFinished = true
                self.assetWriterAudioInput?.markAsFinished()
            }
            
            // Why can't I use ?? here for the callback?
            if let callback = completionCallback {
                self.assetWriter.finishWriting(completionHandler: callback)
            } else {
                self.assetWriter.finishWriting{}
                
            }
        }
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        defer {
            framebuffer.unlock()
        }
        
        guard isRecording else { return }
        // Ignore still images and other non-video updates (do I still need this?)
        guard let frameTime = framebuffer.timingStyle.timestamp?.asCMTime else { return }
        //print("Video frame time = \(frameTime)")
        // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
        guard (frameTime != previousFrameTime) else { return }
        
        
        if (startTime == nil) {
            if (assetWriter.status != .writing) {
                assetWriter.startWriting()
                print("Video starting writing")
            }
            print("Video starting session")
            assetWriter.startSession(atSourceTime: frameTime)
            startTime = frameTime
        }
        
        // TODO: Run the following on an internal movie recording dispatch queue, context
//        guard (assetWriterVideoInput.isReadyForMoreMediaData || (!encodingLiveVideo)) else {
        guard assetWriterVideoInput.isReadyForMoreMediaData else {
            debugPrint("Had to drop a frame at time \(frameTime)")
            return
        }
        
        var pixelBufferFromPool:CVPixelBuffer? = nil
        //if assetWriterPixelBufferInput.pixelBufferPool != nil {
        if assetWriterPixelBufferInput.pixelBufferPool == nil {
            return
        }
        let pixelBufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, assetWriterPixelBufferInput.pixelBufferPool!, &pixelBufferFromPool)
        //}
        guard let pixelBuffer = pixelBufferFromPool, (pixelBufferStatus == kCVReturnSuccess) else { return }
        
        
        
        renderIntoPixelBuffer(pixelBuffer, framebuffer:framebuffer)
        
        if (!assetWriterPixelBufferInput.append(pixelBuffer, withPresentationTime:frameTime)) {
            print("Problem appending pixel buffer at time: \(frameTime)")
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
    }
    
    func renderIntoPixelBuffer(_ pixelBuffer:CVPixelBuffer, framebuffer:Framebuffer) {
        let renderFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:framebuffer.orientation, size:GLSize(self.size))
        renderFramebuffer.lock()
        
        renderFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        
        renderQuadWithShader(sharedImageProcessingContext.passthroughShader, uniformSettings:ShaderUniformSettings(), vertices:standardImageVertices, inputTextures:[framebuffer.texturePropertiesForOutputRotation(.noRotation)])
        
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        glReadPixels(0, 0, renderFramebuffer.size.width, renderFramebuffer.size.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(pixelBuffer))
        renderFramebuffer.unlock()
    }
    
    // MARK: -
    // MARK: Audio support
    
    public func activateAudioTrack() {
        // TODO: Add ability to set custom output settings
        
        // Without output settings it was difficult to get the audio to record, this is duplicated from GPUImage 1 in Objective C.
        let outputSettings: [String : Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,AVEncoderBitRateKey: 96000]
        
        
        assetWriterAudioInput = AVAssetWriterInput(mediaType:AVMediaTypeAudio, outputSettings: outputSettings)
        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
        
        if assetWriter.canAdd(assetWriterAudioInput!) {
            assetWriter.add(assetWriterAudioInput!)
        }
        else {
            print("Cannot add audio")
        }
        
    }
    
    public func processAudioBuffer(_ sampleBuffer:CMSampleBuffer) {
        guard let assetWriterAudioInput = assetWriterAudioInput else { return }
        guard isRecording else {return}
        
        sharedImageProcessingContext.runOperationSynchronously{
//            let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            
            // If you let audio start before the video you will have audio recorded on blank video frames at the beginning of a video.
            /*if (self.startTime == nil) {
             if (self.assetWriter.status != .writing) {
             
             self.assetWriter.startWriting()
             }
             
             self.assetWriter.startSession(atSourceTime: currentSampleTime)
             self.startTime = currentSampleTime
             }*/
            
//            guard (assetWriterAudioInput.isReadyForMoreMediaData || (!self.encodingLiveVideo)) else {
            guard assetWriterAudioInput.isReadyForMoreMediaData else {
                return
            }
            
            if (!assetWriterAudioInput.append(sampleBuffer)) {
                print("Trouble appending audio sample buffer")
                if (self.assetWriter.status == .failed) {
                    print("\(self.assetWriter.error)")
                }
            }
        }
    }
}
    
    public extension Timestamp {
        public init(_ time:CMTime) {
            self.value = time.value
            self.timescale = time.timescale
            self.flags = TimestampFlags(rawValue:time.flags.rawValue)
            self.epoch = time.epoch
        }
        
        public var asCMTime:CMTime {
            get {
                return CMTimeMakeWithEpoch(value, timescale, epoch)
            }
        }
}
