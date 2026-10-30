import Foundation
@main struct AccountActionChecks {
    static func main() {
        var state = AccountActionState()
        state.loggedIn = true
        state.deviceMatchActive = true
        state.deviceCommandPending = true
        precondition(state.businessAuthorizationBlockReason == nil, "Device match must not block business authorization")
        precondition(state.deviceChangeBlockReason != nil, "Device switch must remain blocked")
        state.businessContext = true
        precondition(state.businessAuthorizationBlockReason == "请先处理当前组局球局，再授权登录。")
        state.businessContext = false; state.pendingEvents = true
        precondition(state.businessAuthorizationBlockReason == "请先同步待上传的组局操作，再授权登录。")
        state.pendingEvents = false; state.pendingRecords = true
        precondition(state.businessAuthorizationBlockReason == "请先同步待上传的战绩，再授权登录。")
        state.renewingBusinessIdentity = true
        precondition(state.businessAuthorizationBlockReason == nil, "Same identity must be able to reauthorize with pending records")
        precondition(state.deviceChangeBlockReason != nil)
        state.renewingBusinessIdentity = false
        state.pendingRecords = false; state.authorizing = true
        precondition(state.businessAuthorizationBlockReason == "正在授权，请完成或取消本次授权。")
        state.authorizing = false; state.loggedIn = false
        precondition(state.businessAuthorizationBlockReason == "请先登录设备账号。")
        print("PASS: device match/pending command permits OAuth but blocks account switch; business blockers are explained")
    }
}
