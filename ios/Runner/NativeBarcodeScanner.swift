import Foundation
import AVFoundation
import Vision
import UIKit

@objc class NativeBarcodeScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @objc static let shared = NativeBarcodeScanner()
    
    private var completionHandler: ((String) -> Void)?
    private var isProcessing = false
    
    // 1. 初始化 Vision 条码识别请求
    private lazy var barcodeRequest: VNRecognizeBarcodesRequest = {
        let request = VNRecognizeBarcodesRequest { [weak self] request, error in
            self?.isProcessing = false
            guard error == nil, let results = request.results as? [VNBarcodeObservation] else {
                return
            }
            
            for barcode in results {
                if let payload = barcode.payloadStringValue, !payload.isEmpty {
                    DispatchQueue.main.async {
                        self?.completionHandler?(payload)
                    }
                    break
                }
            }
        }
        
        // 关键点：只开启国内快递面单常用码制，绝对不加 .codabar，完全避开 iOS 15.3 缺少的系统符号
        request.symbologies = [
            .code128,
            .code39,
            .code93,
            .qr
        ]
        
        return request
    }()
    
    // 2. 供 MethodChannel / 相机帧回调调用的入口方法
    @objc func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, completion: @escaping (String) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        self.completionHandler = completion
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessing = false
            return
        }
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try imageRequestHandler.perform([self.barcodeRequest])
            } catch {
                self.isProcessing = false
            }
        }
    }
}
