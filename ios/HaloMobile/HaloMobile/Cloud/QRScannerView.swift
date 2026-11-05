import SwiftUI
import AVFoundation

/// Camera QR scanner. The Simulator has no camera, so `isAvailable` is false there and the manual code path is used.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController(); c.onCode = onCode; return c
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); view.layer.sublayers?.first?.frame = view.bounds }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in if !session.isRunning { session.startRunning() } }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in if session.isRunning { session.stopRunning() } }
        }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(s)
        }
    }
}
