import SwiftUI
#if !UI_PREVIEW
import AVFoundation
import ThingSmartActivatorCoreKit

private final class QRBindingModel: NSObject, ObservableObject, ThingSmartActivatorDelegate {
    @Published var busy = false
    @Published var message = "请保持树莓派程序运行，并确保设备已联网、处于待绑定状态。"
    @Published var completed = false
    private var activator: ThingSmartActivator?
    private var timer: Timer?
    var onBound: (() -> Void)?

    func bind(_ code: DevicePairingCode, homeID: Int64) {
        guard !busy, !completed, homeID > 0 else { return }
        let operation = ThingSmartActivator()
        activator = operation; operation.delegate = self
        let config = ThingSmartPairConfiguration()
        config.uuid = code.uuid; config.gid = String(homeID)
        busy = true; message = "正在加入当前家庭，请稍候（最多 120 秒）…"
        timer = Timer.scheduledTimer(withTimeInterval: 125, repeats: false) { [weak self] _ in
            self?.cancel()
            self?.message = "等待超时，绑定结果未知。请返回刷新设备列表，确认后再重试。"
        }
        operation.startActiveDevice(withConfigurations: config, mode: .mqttDirectly, timeout: 120)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        activator?.delegate = nil; activator?.stopConfigWiFi(); activator = nil
        if busy { message = "已停止等待。设备仍可能完成绑定，请返回刷新设备列表。" }
        busy = false
    }

    func activator(_ activator: ThingSmartActivator, didReceiveDevice deviceModel: ThingSmartDeviceModel?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.busy, self.activator === activator else { return }
            self.cancel()
            if let error = error {
                let code = (error as NSError).code
                self.message = "绑定失败（\(code)）：\(error.localizedDescription)。请确认设备待绑定且网络正常，再刷新设备列表。"
            } else if deviceModel != nil {
                self.completed = true; self.message = "绑定成功，正在刷新设备列表。返回后选择树莓派即可使用。"
                self.onBound?()
            } else { self.message = "未收到设备信息，结果未知。请返回刷新设备列表。" }
        }
    }
    deinit { timer?.invalidate(); activator?.stopConfigWiFi() }
}

struct DeviceQRPairing: View {
    let homeID: Int64
    let homeName: String
    let canBind: () -> Bool
    let onBound: () -> Void
    @StateObject private var model = QRBindingModel()
    @State private var text = ""
    @State private var scanner = false
    @State private var scannedText: String?
    @State private var candidate: DevicePairingCode?
    @State private var confirm = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("扫码绑定树莓派").font(.title2.bold())
                Label("加入家庭：\(homeName)", systemImage: "house")
                Note(text: "扫描树莓派终端显示的设备二维码。已联网设备无需再次填写 Wi-Fi 密码。")
                Button("扫描设备二维码") { scanner = true }.buttonStyle(PrimaryStyle()).disabled(model.busy || model.completed)
                Text("也可以粘贴终端中的完整二维码链接").font(.subheadline)
                TextField("https://smartapp.tuya.com/s/p?…", text: $text)
                    .autocapitalization(.none).disableAutocorrection(true).inputStyle().disabled(model.busy || model.completed)
                Button("识别链接") { recognize(text) }.disabled(model.busy || model.completed || text.isEmpty)
                if model.busy {
                    ProgressView()
                    Button("停止等待") { model.cancel() }
                }
                Note(text: model.message)
            }.padding(22)
        }.background(Palette.background.ignoresSafeArea())
            .navigationTitle("二维码绑定").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanner, onDismiss: {
                if let value = scannedText { scannedText = nil; recognize(value) }
            }) {
                QRScannerScreen { value in
                    scannedText = value
                    scanner = false
                }
            }
            .alert("确认绑定设备", isPresented: $confirm) {
                Button("取消", role: .cancel) { candidate = nil }
                Button("加入当前家庭") {
                    if !canBind() { model.message = "账号或家庭已变更，请返回设备页重新选择家庭。" }
                    else if let candidate = candidate { model.bind(candidate, homeID: homeID) }
                    candidate = nil; text = ""
                }
            } message: {
                Text("将设备 …\(candidate?.uuid.suffix(6) ?? "") 加入「\(homeName)」。请确认这是你的树莓派。")
            }
            .onAppear { model.onBound = onBound }
            .onDisappear { model.cancel(); model.onBound = nil }
            .onChange(of: scenePhase) { if $0 == .background { model.cancel() } }
    }

    private func recognize(_ value: String) {
        guard !model.busy, !model.completed else { return }
        guard let code = DevicePairingCode.parse(value) else {
            model.message = "这不是支持的 TuyaOpen 设备绑定链接。请扫描终端的设备二维码，或粘贴完整链接。"
            return
        }
        candidate = code; confirm = true
    }
}

private struct QRScannerScreen: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: QRScannerController(onScan: onScan))
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "shuttleref.qr.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var received = false
    private var visible = false
    private let onScan: (String) -> Void
    private let note = UILabel()
    init(onScan: @escaping (String) -> Void) { self.onScan = onScan; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; title = "扫描设备二维码"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        note.textColor = .white; note.numberOfLines = 0; note.textAlignment = .center
        note.text = "将树莓派终端上的二维码放入镜头中"
        note.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(note)
        NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), note.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { guard let self = self, self.visible else { return }; allowed ? self.configure() : self.denied() }
            }
        default: denied()
        }
    }
    private func denied() { note.text = "未获得相机权限。可在系统设置中允许相机，或返回粘贴设备二维码链接。" }
    private func configure() {
        guard capture.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else {
            note.text = "相机不可用，请返回粘贴设备二维码链接。"; return
        }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { note.text = "无法启动扫码，请返回粘贴链接。"; return }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds; view.layer.insertSublayer(layer, at: 0); preview = layer
        queue.async { [capture] in capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); visible = false
        queue.async { [capture] in capture.stopRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !received, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        received = true; onScan(code)
    }
    @objc private func close() { dismiss(animated: true) }
}
#else
struct DeviceQRPairing: View {
    let homeID: Int64
    let homeName: String
    let canBind: () -> Bool
    let onBound: () -> Void
    var body: some View { EmptyCard(icon: "qrcode.viewfinder", title: "二维码绑定", detail: "请使用真机版本扫描树莓派设备二维码。") }
}
#endif
