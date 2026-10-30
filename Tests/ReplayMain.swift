import Foundation

@main struct ReplayChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count==2 {
            do { try await network(origin:CommandLine.arguments[1]) }
            catch { print("FAIL: actual SSE reference integration: "+error.localizedDescription);exit(1) }
            return
        }
        var attempt=ReplayPlaybackState()
        let first=attempt.begin()
        precondition(attempt.ready(first))
        precondition(attempt.waiting(first))
        precondition(attempt.fail(first))
        precondition(!attempt.ready(first) && !attempt.accepts(first),"Late ready must not restart a timed-out player")
        let second=attempt.begin()
        precondition(!attempt.accepts(first) && attempt.accepts(second))
        precondition(attempt.ready(second) && attempt.waiting(second) && attempt.playing(second))
        attempt.stop();precondition(!attempt.accepts(second))
        let reference = CoachReference(type:"point",id:"point",match_id:"match",label:"演示最后一分",is_demo:true)
        let a=CoachContext(origin:"https://a.example",userID:"a",token:"a-token")
        let b=CoachContext(origin:"https://a.example",userID:"b",token:"b-token")
        let defaults=UserDefaults(suiteName:"replay-check-"+UUID().uuidString)!
        var gate:CheckedContinuation<Void,Never>?
        var sent:[CoachReference]=[]
        let store=CoachStore(defaults:defaults, referencedStreaming:{ _,_,references,onDelta,onMetadata in
            sent=references
            onMetadata(references,[])
            onDelta("这是演示比分")
            await withCheckedContinuation { gate=$0 }
            return CoachReply(reply:"这是演示比分",references:references)
        })
        store.bind(a);store.selectReference(reference);store.draft="看看最后一分"
        let task=Task { await store.send() }
        while gate==nil { await Task.yield() }
        precondition(sent==[reference])
        store.selectReference(nil) // During generation, current request stays frozen.
        store.stop()
        precondition(store.messages.last?.completion=="stopped")
        precondition(store.messages.last?.references==[reference])
        store.bind(b);gate!.resume();await task.value
        precondition(store.messages.isEmpty && store.references.isEmpty)
        store.bind(a)
        precondition(store.messages.last?.references==[reference])
        let old=try JSONDecoder().decode(CoachMessage.self,from:Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"role\":\"user\",\"content\":\"old\",\"date\":0}".utf8))
        precondition(old.references==nil)
        let good=ReplayGrant(asset_id:"asset",url:URL(string:"https://shuttle-oss.tos-cn-beijing.volces.com/key?signed=test")!,expires_at:1100,duration_seconds:48.66)
        try good.validate(assetID:"asset",now:1000)
        for bad in [ReplayGrant(asset_id:"asset",url:URL(string:"https://evil.test/key")!,expires_at:1100,duration_seconds:48.66),
                    ReplayGrant(asset_id:"asset",url:good.url,expires_at:999,duration_seconds:48.66),
                    ReplayGrant(asset_id:"other",url:good.url,expires_at:1100,duration_seconds:48.66)] {
            do { try bad.validate(assetID:"asset",now:1000);preconditionFailure("Invalid grant accepted") } catch {}
        }
        var loadGate:CheckedContinuation<[ReplayMatch],Never>?
        let replay=ReplayStore(load:{ _ in await withCheckedContinuation { loadGate=$0 } })
        replay.configure(a);let loading=Task { await replay.refresh() }
        while loadGate==nil { await Task.yield() }
        replay.configure(b);loadGate!.resume(returning:[]);await loading.value
        precondition(!replay.loading && replay.matches.isEmpty)
        replay.requestCoach(reference)
        precondition(replay.consumeLaunch(for:a)==nil && replay.launch==nil)
        print("PASS: replay grants, frozen references/partial history, legacy decoding, stale loads/navigation, identity isolation")
    }
    @MainActor static func network(origin:String) async throws {
        precondition(URL(string:origin)?.host=="127.0.0.1")
        var request=URLRequest(url:URL(string:origin+"/api/social/session/register")!)
        request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["username":"yhb","password":"local fixture password","name":"binbin"])
        let (data,_)=try await URLSession.shared.data(for:request)
        let session=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let user=session["user"] as! [String:Any]
        let context=CoachContext(origin:origin,userID:user["id"] as! String,token:session["token"] as! String)
        let match=try await ReplayClient().matches(context)[0]
        let ref=match.reference(to:match.points[0]);var received:[CoachContentBlock]=[]
        let reply=try await CoachClient().stream(context:context,messages:[.init(role:"user",content:"complete")],references:[ref],onMetadata:{ refs,blocks in
            precondition(refs[0].id==ref.id);received=blocks
        }) { _ in }
        precondition(received.first?.video?.assetID==match.points[0].video.asset_id)
        precondition(reply.blocks?.last?.video?.assetID==received.first?.video?.assetID)
        let defaults=UserDefaults(suiteName:"replay-network-"+UUID().uuidString)!
        let store=CoachStore(defaults:defaults);store.bind(context);store.selectReference(ref);store.draft="interrupt"
        await store.send()
        precondition(store.messages.last?.completion=="interrupted")
        precondition(store.messages.last?.blocks?.last?.video?.assetID==match.points[0].video.asset_id)
        precondition(store.messages.last?.references?.first?.id==ref.id)
        let restored=CoachStore(defaults:defaults);restored.bind(context)
        precondition(restored.messages.last?.blocks?.last?.video?.assetID==match.points[0].video.asset_id)
        print("PASS: real Swift URLSession + business auth + SSE reference/card decoding, interruption and history persistence")
    }
}
