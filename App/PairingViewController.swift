import UIKit
import ThingSmartBLEKit
import ThingSmartDeviceCoreKit

final class PairingViewController: UIViewController, ThingSmartBLEManagerDelegate, ThingSmartBLEWifiActivatorDelegate {
 let homeID: Int64
 private let status = UILabel()
 private let ssid = UITextField()
 private let password = UITextField()
 private let results = UIStackView()
 private var seen = Set<String>()
 private var scanning = false
 private var pairing = false
 private var timer: Timer?
 private var run = 0
 init(homeID: Int64) { self.homeID = homeID; super.init(nibName:nil,bundle:nil) }
 required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
 override func viewDidLoad() {
  super.viewDidLoad(); title = "添加设备"
  view.backgroundColor = UIColor(red:246/255,green:247/255,blue:242/255,alpha:1)
  view.tintColor = UIColor(red:37/255,green:78/255,blue:65/255,alpha:1)
  let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
  let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
  NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-20),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40)])
  let note = UILabel(); note.numberOfLines = 0; note.font = .systemFont(ofSize:15);note.textColor = UIColor(red:98/255,green:115/255,blue:107/255,alpha:1)
  note.text = "蓝牙辅助 Wi-Fi 配网\n请使用 2.4GHz Wi-Fi。扫描只发现待配网设备；已绑定的 T5 不一定出现。本页不会重置设备或解除原绑定。转绑会影响原 App 的访问，请准备好后再操作。"
  stack.addArrangedSubview(note)
  for (f,p) in [(ssid,"Wi-Fi 名称（区分空格和大小写）"),(password,"Wi-Fi 密码")] {
   f.placeholder = p; f.borderStyle = .roundedRect; f.autocorrectionType = .no; f.autocapitalizationType = .none; f.backgroundColor = .white; f.heightAnchor.constraint(equalToConstant:52).isActive = true; stack.addArrangedSubview(f)
  }
  password.isSecureTextEntry = true
  let scan = UIButton(type:.system); scan.setTitle("扫描待配网设备",for:.normal);scan.backgroundColor = view.tintColor;scan.setTitleColor(.white,for:.normal);scan.layer.cornerRadius = 16;scan.heightAnchor.constraint(equalToConstant:54).isActive = true; scan.addTarget(self,action:#selector(startScan),for:.touchUpInside); stack.addArrangedSubview(scan)
  let cancel = UIButton(type:.system); cancel.setTitle("停止扫描 / 配网",for:.normal); cancel.addTarget(self,action:#selector(cancelOperation),for:.touchUpInside); stack.addArrangedSubview(cancel)
  status.numberOfLines = 0; status.text = "请选择扫描；需要允许蓝牙权限。"; stack.addArrangedSubview(status)
  results.axis = .vertical; results.spacing = 12; stack.addArrangedSubview(results)
  NotificationCenter.default.addObserver(self,selector:#selector(cancelOperation),name:UIApplication.didEnterBackgroundNotification,object:nil)
 }
 override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
 @objc private func cancelOperation() { stop(); status.text = "已停止。若设备已接收配网信息，仍可能完成绑定，请返回刷新设备列表。" }
 private func stop() {
  run += 1; scanning = false; pairing = false; timer?.invalidate(); timer = nil
  ThingSmartBLEManager.sharedInstance().stopListening(true)
  ThingSmartBLEManager.sharedInstance().delegate = nil
  ThingSmartBLEWifiActivator.sharedInstance().stopDiscover()
  ThingSmartBLEWifiActivator.sharedInstance().bleWifiDelegate = nil
  results.isUserInteractionEnabled = false
 }
 @objc private func startScan() {
  guard !pairing else { status.text = "正在配网，请等待或停止。"; return }
  stop(); seen.removeAll(); results.arrangedSubviews.forEach { $0.removeFromSuperview() }
  scanning = true; results.isUserInteractionEnabled = true
  status.text = "扫描中（60 秒）…若没有结果，请检查蓝牙权限及设备是否处于待配网状态。"
  ThingSmartBLEManager.sharedInstance().delegate = self
  ThingSmartBLEManager.sharedInstance().startListening(true)
  timer = Timer.scheduledTimer(withTimeInterval:60,repeats:false) { [weak self] _ in
   guard let self = self else { return }; self.stop(); self.status.text = "扫描已结束。可重新扫描；此操作未重置设备。"
  }
 }
 func didDiscoveryDevice(withDeviceInfo info: ThingBLEAdvModel) {
  DispatchQueue.main.async { [weak self] in
   guard let self = self, self.scanning, !self.pairing, let uuid = info.uuid, !uuid.isEmpty else { return }
   let type = info.bleType
   guard type == ThingSmartBLETypeBLEWifi || type == ThingSmartBLETypeBLEWifiSecurity || type == ThingSmartBLETypeBLEWifiPlugPlay || type == ThingSmartBLETypeBLEWifiPriorBLE else { return }
   guard self.seen.insert(uuid).inserted else { return }
   let b = UIButton(type:.system); b.setTitle("选择设备 …\(uuid.suffix(8))",for:.normal)
   b.addAction(UIAction { [weak self] _ in self?.confirm(info) },for:.touchUpInside); self.results.addArrangedSubview(b)
  }
 }
 private func confirm(_ info: ThingBLEAdvModel) {
  guard scanning, !pairing, let name = ssid.text, !name.isEmpty else { status.text = "请先填写 Wi-Fi 名称，并在扫描期间选择设备。"; return }
  let alert = UIAlertController(title:"确认配网",message:"将所选设备加入当前家庭。请确认这是你的测试设备，且已准备好转绑；原 App 的设备访问可能受到影响。",preferredStyle:.alert)
  alert.addAction(UIAlertAction(title:"取消",style:.cancel))
  alert.addAction(UIAlertAction(title:"开始配网",style:.default) { [weak self] _ in self?.activate(info) }); present(alert,animated:true)
 }
 private func activate(_ info: ThingBLEAdvModel) {
  guard scanning, !pairing else { return }
  view.endEditing(true); timer?.invalidate(); scanning = false; pairing = true; results.isUserInteractionEnabled = false
  ThingSmartBLEManager.sharedInstance().stopListening(false)
  ThingSmartBLEManager.sharedInstance().delegate = nil
  let id = run; status.text = "正在配网并等待云端激活（最多 120 秒）…"
  ThingSmartBLEWifiActivator.sharedInstance().bleWifiDelegate = self
  timer = Timer.scheduledTimer(withTimeInterval:120,repeats:false) { [weak self] _ in
   guard let self = self, self.run == id else { return }; self.stop(); self.status.text = "配网等待超时，结果未知。请返回刷新设备列表后再决定是否重试。"
  }
  ThingSmartBLEWifiActivator.sharedInstance().startConfigBLEWifiDevice(withUUID:info.uuid,homeId:homeID,productId:info.productId,ssid:ssid.text ?? "",password:password.text ?? "",timeout:100,success: { [weak self] in
   DispatchQueue.main.async { guard let self = self, self.run == id, self.pairing else { return }; self.status.text = "配网信息发送成功，正在等待云端激活…" }
  },failure: { [weak self] in
   DispatchQueue.main.async { guard let self = self, self.run == id, self.pairing else { return }; self.stop(); self.status.text = "配网信息发送失败。请检查设备、蓝牙及 Wi-Fi，再刷新设备列表。" }
  })
 }
 func bleWifiActivator(_ activator: ThingSmartBLEWifiActivator, didReceiveBLEWifiConfigDevice model: ThingSmartDeviceModel?, error: Error?) {
  DispatchQueue.main.async { [weak self] in
   guard let self = self, self.pairing else { return }; self.stop()
   if let error = error { self.status.text = "激活失败：\(error.localizedDescription)" }
   else if let model = model { self.password.text = ""; self.status.text = "设备 \(model.name ?? "") 激活成功。请返回并刷新家庭设备列表。" }
   else { self.status.text = "未收到设备结果，请返回刷新列表。" }
  }
 }
 deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}
