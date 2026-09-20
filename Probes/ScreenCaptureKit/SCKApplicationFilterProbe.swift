import ScreenCaptureKit

func probe(_ display: SCDisplay, _ applications: [SCRunningApplication]) {
    _ = SCContentFilter(display: display, including: applications, exceptingWindows: [])
    _ = applications.first?.bundleIdentifier
    _ = SCShareableContent.current
}
