@preconcurrency import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.configurePreviewConnection()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        guard uiView.videoPreviewLayer.session !== session else { return }
        uiView.videoPreviewLayer.session = session
        uiView.configurePreviewConnection()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configurePreviewConnection()
    }

    func configurePreviewConnection() {
        guard let connection = videoPreviewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        videoPreviewLayer.videoGravity = .resizeAspectFill
    }
}
