import AVFAudio
import AudioToolbox

func probeAudioUnit() throws {
    let engine = AVAudioEngine()
    _ = engine.mainMixerNode
    _ = engine.outputNode
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_RemoteIO,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    _ = AudioComponentFindNext(nil, &description)
}
