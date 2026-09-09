import Foundation
import CryptoKit

enum DirectorCache {
    static var automatic:Bool { UserDefaults.standard.object(forKey:"director.automatic") as? Bool ?? true }
    static func key(cues:[LyricCue],settings:DirectorSettings)->String {
        let text=cues.map { "\($0.id)|\($0.start)|\($0.end)|\($0.text)" }.joined(separator:"\n")
        return SHA256.hash(data:Data((DirectorClient.planPrompt+settings.baseURL+settings.model+text).utf8)).map{String(format:"%02x",$0)}.joined()
    }
    static func read(_ key:String)->PerformanceScore.Plan? {
        guard let data=UserDefaults.standard.data(forKey:"director.plan."+key) else { return nil }
        return try? JSONDecoder().decode(PerformanceScore.Plan.self,from:data)
    }
    static func save(_ plan:PerformanceScore.Plan,key:String) {
        guard let data=try? JSONEncoder().encode(plan),data.count<=512_000 else { return }
        var keys=UserDefaults.standard.stringArray(forKey:"director.plan.keys") ?? []
        keys.removeAll{$0==key};keys.insert(key,at:0)
        for old in keys.dropFirst(8) { UserDefaults.standard.removeObject(forKey:"director.plan."+old) }
        UserDefaults.standard.set(Array(keys.prefix(8)),forKey:"director.plan.keys")
        UserDefaults.standard.set(data,forKey:"director.plan."+key)
    }
}
