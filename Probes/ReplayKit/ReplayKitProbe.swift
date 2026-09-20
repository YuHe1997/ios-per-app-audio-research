import ReplayKit

final class Handler: RPBroadcastSampleHandler {
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp, .audioMic, .video:
            break
        @unknown default:
            break
        }
    }
}
