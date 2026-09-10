//
//  WebcamManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import AVFoundation
import SwiftUI

class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            objectWillChange.send()
        }
    }
    
    private var captureSession: AVCaptureSession?
    @Published var isSessionRunning: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var cameraAvailable: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }

    private let sessionQueue = DispatchQueue(label: "BoringNotch.WebcamManager.SessionQueue", qos: .userInitiated)
    // Serial-queue owned: stopping invalidates setup/start work that was already enqueued.
    private var sessionIntent = CameraSessionIntent()
    
    private var isCleaningUp: Bool = false
    
    // MARK: - Constants
    
    enum WebcamError: Error, LocalizedError {
        case deviceUnavailable
        case accessDenied
        case configurationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return L("No camera devices available")
            case .accessDenied:
                return L("Camera access denied")
            case .configurationFailed(let message):
                return String(format: L("Camera configuration failed: %@"), message)
            }
        }
    }
    
    // MARK: - Properties
    
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        checkCameraAvailability()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        captureSession = nil
            
        previewLayer = nil
    }

    // MARK: - Camera Management
    
    /// Checks current authorization status and requests access if needed
    func checkAndRequestVideoAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
        
        switch status {
        case .authorized:
            checkCameraAvailability() // Check availability if authorized
        case .notDetermined:
            requestVideoAccess()
        case .denied, .restricted:
            NSLog("Camera access denied or restricted")
        @unknown default:
            NSLog("Unknown authorization status")
        }
    }
    
    /// Requests access to the camera
    private func requestVideoAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self?.checkCameraAvailability() // Check availability if access granted
                }
            }
        }
    }
    
    /// Checks if any camera devices are available and sets up capture session if needed
    func checkCameraAvailability() {
        let availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        
        let hasAvailableDevices = !availableDevices.isEmpty
        
        DispatchQueue.main.async {
            self.cameraAvailable = hasAvailableDevices
        }
    }
    
    /// Sets up the capture session with a completion handler
    private func setupCaptureSession(generation: UInt64, completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.sessionIntent.accepts(generation) else {
                completion(false)
                return 
            }
            
            // Clean up any existing session before creating a new one
            self.cleanupExistingSession()
            
            let session = AVCaptureSession()
            
            do {
                // Get available devices and prefer external camera if available
                let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                
                guard let videoDevice = discoverySession.devices.first else {
                    NSLog("No video devices available")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                        self.cameraAvailable = false
                    }
                    completion(false)
                    return
                }
                
                NSLog("Using camera: \(videoDevice.localizedName)")
                
                // Lock device for configuration
                try videoDevice.lockForConfiguration()
                defer { videoDevice.unlockForConfiguration() }
                
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(videoInput) else {
                    throw NSError(domain: "BoringNotch.WebcamManager", code: -1, userInfo: [NSLocalizedDescriptionKey: L("Cannot add video input")])
                }
                
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(videoInput)
                
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                }
                session.commitConfiguration()
                
                self.captureSession = session
                
                // Create and set up preview layer on main thread
                DispatchQueue.main.async {
                    self.cameraAvailable = true
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                    
                }
                // Keep lifecycle work on its serial queue. A main-queue UI callback must
                // not revive a camera request after hiding has stopped the session.
                completion(true)
                
                NSLog("Capture session setup completed successfully")
            } catch {
                NSLog("Failed to setup capture session: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                    self.cameraAvailable = false
                    self.previewLayer = nil
                }
                completion(false)
            }
        }
    }
    
    /// Cleans up an existing capture session, removing all inputs and outputs
    private func cleanupExistingSession() {
        if let existingSession = self.captureSession {
            // First stop the session if running
            if existingSession.isRunning {
                existingSession.stopRunning()
            }
            
            // Then perform configuration cleanup
            existingSession.beginConfiguration()
            
            // Remove all inputs and outputs
            for input in existingSession.inputs {
                existingSession.removeInput(input)
            }
            for output in existingSession.outputs {
                existingSession.removeOutput(output)
            }
            
            existingSession.commitConfiguration()
            self.captureSession = nil
            
            // Clear preview layer on main thread
            DispatchQueue.main.async {
                self.previewLayer = nil
            }
        }
    }

    @objc private func deviceWasDisconnected(notification: Notification) {
        NSLog("Camera device was disconnected")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopSession()
            DispatchQueue.main.async {
                self.cameraAvailable = false
            }
        }
    }

    @objc private func deviceWasConnected(notification: Notification) {
        NSLog("Camera device was connected")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.checkCameraAvailability()
        }
    }

    private func updateSessionState() {
        let isRunning = self.captureSession?.isRunning ?? false
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let generation = self.sessionIntent.requestStart()
            
            // If no session exists, create new session
            if self.captureSession == nil {
                self.setupCaptureSession(generation: generation) { success in
                    if success {
                        // Only start the session if setup was successful
                        self.startRunningCaptureSession(generation: generation)
                    }
                }
            } else {
                // Session already exists, just start it
                self.startRunningCaptureSession(generation: generation)
            }
        }
    }
    
    private func startRunningCaptureSession(generation: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.sessionIntent.accepts(generation),
                  let session = self.captureSession, !session.isRunning else {
                return
            }
            
            session.startRunning()
            
            // Update state on main thread
            self.updateSessionState()
            
            NSLog("Capture session started successfully")
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sessionIntent.requestStop()
            
            // Update state to indicate we're stopping
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            
            self.cleanupExistingSession()
            
            NSLog("Capture session stopped and cleaned up")
        }
    }
}
