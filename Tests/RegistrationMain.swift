import Foundation
@main struct RegistrationChecks {
    static func main() {
        let g = Gathering(id:"g",title:"test",location:"court",starts_at:0,capacity:2,owner_id:"a",organizer:"A",status:"open",signup_open:true,ends_at:nil,notes:"",court:"",members:[
            GatheringMember(user_id:"a",name:"A",status:"confirmed"),
            GatheringMember(user_id:"b",name:"B",status:"waitlisted"),
            GatheringMember(user_id:"c",name:"C",status:"confirmed"),
            GatheringMember(user_id:"d",name:"D",status:"waitlisted")],fixtures:[])
        precondition(g.registration(for:"a") == .confirmed)
        precondition(g.registration(for:"b") == .waitlisted(1))
        precondition(g.registration(for:"d") == .waitlisted(2))
        precondition(g.registration(for:"missing") == .notJoined)
        precondition(g.registration(for:"d").title == "候补第 2 位")
        print("PASS: confirmed, absent member, ordered waitlist rank independent of confirmed members")
    }
}
