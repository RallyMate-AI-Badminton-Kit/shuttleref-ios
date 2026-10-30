import Foundation
import Combine

@MainActor final class RacketDiagnosticLog: ObservableObject {
    static let shared = RacketDiagnosticLog()
    @Published private(set) var trace = RacketDiagnostics()
    func record(_ event:RacketDiagnostics.Event, operation:String? = nil, device:String? = nil,
                code:String? = nil,status:Int? = nil,length:Int? = nil,version:Int? = nil,
                kind:Int? = nil,bound:Int? = nil,before:UInt32? = nil,after:UInt32? = nil) {
        trace.record(event,operation:operation,device:device,code:code,status:status,length:length,version:version,kind:kind,bound:bound,before:before,after:after)
    }
    func reset() { trace = RacketDiagnostics() }
    var report: String {
        let b=Bundle.main
        return "App \(b.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版") (\(b.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "-"))\n" + trace.report()
    }
}
