import Foundation
import Combine

struct CoachLaunch: Identifiable {
    let id=UUID()
    let context:CoachContext
    let reference:CoachReference
}

@MainActor final class ReplayStore:ObservableObject {
    @Published private(set) var matches:[ReplayMatch]=[]
    @Published private(set) var loading=false
    @Published private(set) var error=""
    @Published private(set) var context:CoachContext?
    @Published private(set) var launch:CoachLaunch?
    private var epoch=UUID()
    private let load:(CoachContext) async throws -> [ReplayMatch]
    init(load:((CoachContext) async throws -> [ReplayMatch])?=nil) {
        let client=ReplayClient()
        self.load=load ?? { try await client.matches($0) }
    }
    func configure(_ value:CoachContext?) {
        guard value != context else { return }
        epoch=UUID();context=value;matches=[];error="";loading=false;launch=nil
    }
    func refresh() async {
        guard !loading,let context else { return }
        let run=epoch;loading=true;error=""
        defer { if run==epoch { loading=false } }
        do {
            let result=try await load(context)
            guard epoch==run,self.context==context else { return }
            matches=result
        } catch {
            guard epoch==run,self.context==context,!(error is CancellationError) else { return }
            self.error="演示回放未能加载："+error.localizedDescription
        }
    }
    func requestCoach(_ reference:CoachReference) {
        guard let context else { return }
        launch=CoachLaunch(context:context,reference:reference)
    }
    func consumeLaunch(for context:CoachContext?) -> CoachReference? {
        guard let launch else { return nil }
        self.launch=nil
        return launch.context==context ? launch.reference : nil
    }
}
