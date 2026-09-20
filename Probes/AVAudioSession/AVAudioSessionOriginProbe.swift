import AVFAudio

func probeSession() {
    let session = AVAudioSession.sharedInstance()
    _ = session.isOtherAudioPlaying
    _ = session.secondaryAudioShouldBeSilencedHint
    _ = session.currentRoute
    _ = session.outputVolume
}
