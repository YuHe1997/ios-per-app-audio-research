import CoreAudio

func probeProcessTap(_ description: CATapDescription) {
    var objectID: AudioObjectID = 0
    _ = AudioHardwareCreateProcessTap(description, &objectID)
    _ = kAudioHardwarePropertyProcessObjectList
    _ = kAudioHardwarePropertyTranslatePIDToProcessObject
    _ = kAudioProcessPropertyPID
    _ = kAudioProcessPropertyBundleID
    _ = kAudioProcessPropertyIsRunningOutput
}
