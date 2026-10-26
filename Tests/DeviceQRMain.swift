import Foundation

@main struct DeviceQRTests {
    static func main() {
        let valid = "https://smartapp.tuya.com/s/p?p=testproduct&uuid=test-device-123&v=2.0"
        precondition(DevicePairingCode.parse(valid)?.uuid == "test-device-123")
        precondition(DevicePairingCode.parse(" \n" + valid + "\n")?.productID == "testproduct")
        for input in ["", "test-device-123", valid.replacingOccurrences(of: "https:", with: "http:"),
                      valid.replacingOccurrences(of: "smartapp.tuya.com", with: "smartapp.tuya.com.evil.com"),
                      valid + "&uuid=other", valid.replacingOccurrences(of: "uuid=test-device-123", with: "uuid="),
                      valid.replacingOccurrences(of: "p=testproduct", with: "p="),
                      valid.replacingOccurrences(of: "/s/p?", with: "/invite?"),
                      valid.replacingOccurrences(of: "v=2.0", with: "v=3.0"),
                      valid.replacingOccurrences(of: "uuid=test-device-123", with: "uuid=a%0Ab"),
                      valid.replacingOccurrences(of: "smartapp.tuya.com", with: "user@smartapp.tuya.com")] {
            precondition(DevicePairingCode.parse(input) == nil, "Unexpected QR accepted")
        }
        print("Device QR validation passed")
    }
}
