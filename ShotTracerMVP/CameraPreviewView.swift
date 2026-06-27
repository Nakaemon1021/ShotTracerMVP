//
//  CameraPreviewView.swift
//  ShotTracerMVP
//
//  Created by 中江 宏仁 on 2026/02/07.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onPreviewLayer: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override init() {
            super.init()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationChanged),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }

        @objc func orientationChanged() {
            guard let layer = previewLayer else { return }
            updateOrientation(for: layer)
        }
        
        func updateOrientation(for layer: AVCaptureVideoPreviewLayer) {
            guard let connection = layer.connection else { return }
            let deviceOrientation = UIDevice.current.orientation
            
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    switch deviceOrientation {
                    case .portrait: connection.videoRotationAngle = 90
                    case .portraitUpsideDown: connection.videoRotationAngle = 270
                    case .landscapeLeft: connection.videoRotationAngle = 0
                    case .landscapeRight: connection.videoRotationAngle = 180
                    default: break
                    }
                }
            } else {
                if connection.isVideoOrientationSupported {
                    switch deviceOrientation {
                    case .portrait: connection.videoOrientation = .portrait
                    case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                    case .landscapeLeft: connection.videoOrientation = .landscapeRight
                    case .landscapeRight: connection.videoOrientation = .landscapeLeft
                    default: break
                    }
                }
            }
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        context.coordinator.previewLayer = view.videoPreviewLayer
        context.coordinator.updateOrientation(for: view.videoPreviewLayer)

        DispatchQueue.main.async {
            onPreviewLayer?(view.videoPreviewLayer)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        let layer = uiView.videoPreviewLayer
        layer.frame = uiView.bounds
        context.coordinator.updateOrientation(for: layer)
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer.frame = self.bounds
        CATransaction.commit()
    }
}
