import Foundation
@main struct AccountChecks {
    static func main() {
        precondition(AccountLoginMethod.phoneCode.valid(account: "13800138000", country: "86"))
        precondition(!AccountLoginMethod.phoneCode.valid(account: "138", country: "86"))
        precondition(!AccountLoginMethod.phoneCode.valid(account: "13800138000", country: ""))
        precondition(AccountLoginMethod.emailCode.valid(account: "player@example.com", country: "86"))
        precondition(!AccountLoginMethod.emailCode.valid(account: "player@", country: "86"))
        precondition(AccountLoginMethod.emailPassword.needsPassword)
        precondition(!AccountLoginMethod.emailCode.needsPassword)
        precondition(AccountLoginMethod.emailCode.codePurpose(register: false) == 2)
        precondition(AccountLoginMethod.emailCode.codePurpose(register: true) == 1)
        precondition(AccountPrivacy.mask("player@example.com") == "p***@example.com")
        precondition(AccountPrivacy.mask("13800138000") == "138****8000")
        precondition(!AccountPrivacy.mask("ab").contains("ab"))
        print("PASS: account validation, verification purpose and display masking")
    }
}
