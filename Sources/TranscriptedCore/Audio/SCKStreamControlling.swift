import AVFoundation
import ScreenCaptureKit

@available(macOS 26.0, *)
protocol SCKStreamControlling: AnyObject {
    var captureIdentity: ObjectIdentifier { get }

    func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws
    func startCapture(completionHandler: (@Sendable (Error?) -> Void)?)
    func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?)
}

@available(macOS 26.0, *)
extension SCStream: SCKStreamControlling {
    var captureIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}
