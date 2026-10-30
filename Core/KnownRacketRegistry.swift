import Foundation

/// Confirmed association cache, never an authentication or live-connection proof.
enum KnownRacketRegistry {
    private static var live: [UUID:String] = [:]
    static func connected(_ device:String,context:RacketContext,connection:UUID) {
        live[connection] = key(context) + ":" + device
        UserDefaults.standard.set(UUID().uuidString,forKey:"racket.registry.revision")
    }
    static func disconnected(_ connection:UUID) {
        live.removeValue(forKey:connection)
        UserDefaults.standard.set(UUID().uuidString,forKey:"racket.registry.revision")
    }
    static func isConnected(_ device:String,context:RacketContext) -> Bool { live.values.contains(key(context) + ":" + device) }

    private struct Entry: Codable { let device: RacketDevice; var peripheral: String? }
    private static func key(_ context: RacketContext) -> String { "racket.confirmed." + context.origin + ":" + context.userID }
    private static func entries(_ context: RacketContext, defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey:key(context)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self,from:data)) ?? []
    }
    private static func save(_ values:[Entry],_ context:RacketContext,_ defaults:UserDefaults) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data,forKey:key(context)); defaults.set(UUID().uuidString,forKey:"racket.registry.revision")
    }
    static func remember(_ device:RacketDevice, peripheral:String?, context:RacketContext, defaults:UserDefaults = .standard) {
        guard device.user?.stableID == context.userID else { return }
        var values = entries(context,defaults:defaults)
        let previous = values.first { $0.device.id == device.id }
        values.removeAll { $0.device.id == device.id }
        values.append(Entry(device:device,peripheral:peripheral ?? previous?.peripheral)); save(values,context,defaults)
    }
    static func replace(_ devices:[RacketDevice],context:RacketContext,defaults:UserDefaults = .standard) {
        let old = entries(context,defaults:defaults)
        save(devices.filter { $0.user?.stableID == context.userID }.map { row in Entry(device:row,peripheral:old.first { $0.device.id == row.id }?.peripheral) },context,defaults)
    }
    static func isKnown(peripheral:String,context:RacketContext,defaults:UserDefaults = .standard) -> Bool {
        entries(context,defaults:defaults).contains { $0.peripheral == peripheral && $0.device.user?.stableID == context.userID }
    }
    static func devices(_ context:RacketContext,defaults:UserDefaults = .standard) -> [RacketDevice] {
        entries(context,defaults:defaults).map { entry in
            let d = entry.device
            return RacketDevice(id:d.id,name:d.name,version:d.version,user:d.user,hostID:d.hostID,authenticated:false,connection:.unknown,observedAt:.distantPast,matchActive:false)
        }
    }
}
