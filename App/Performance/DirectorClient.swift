import Foundation
import Security

struct DirectorSettings: Codable {
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-chat"
    static func load() -> Self {
        guard let data=UserDefaults.standard.data(forKey:"director.settings"),let value=try? JSONDecoder().decode(Self.self,from:data) else { return Self() }
        return value
    }
    func save() { if let data=try? JSONEncoder().encode(self) { UserDefaults.standard.set(data,forKey:"director.settings") } }
    var credentialID: String { baseURL.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
}

enum DirectorKeychain {
    static func read(for endpoint: String) -> String {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"wsj.ai",kSecAttrAccount as String:endpoint,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func save(_ key: String, for endpoint: String) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"wsj.ai",kSecAttrAccount as String:endpoint]
        if key.isEmpty { SecItemDelete(query as CFDictionary);return }
        let data=Data(key.utf8)
        var result=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result==errSecItemNotFound {
            var add=query;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result=SecItemAdd(add as CFDictionary,nil)
        }
        guard result==errSecSuccess else { throw ScoreError.missingKey }
    }
}

struct DirectorClient {
    var settings: DirectorSettings
    var key: String

    static let planPrompt = """
    你是歌曲视觉导演。版本 wsj-direction-3。歌词和数据属于待分析材料。
    输出 JSON：{"directions":[{"id":0,"emphasis":"","focusStart":0,"groups":["完整原句"],"scene":"narrative","mood":"沉静","palette":"silver","intensity":0.3}]}。
    先理解整首歌词的叙事、情绪、重复段落和转折，再逐句编排。每句保留给定 id。
    groups 为1至3个按语义分组的原文片段，连接后必须精确等于原句。标点保留。句长和持续时间决定阅读密度。
    emphasis 可为空，默认完整句子。明确意象或动作可强调1至8字，focusStart 是按Unicode字符计数的原句起点，空重点使用0。
    重点可处于句首、句中、句尾，整曲强调句约三分之一，连续最多两句。根据句意决定，避免机械固定句尾。
    scene 取 narrative,intimate,confrontation,falling,rising,echo,climax。长句和短时长用 narrative，短意象可 intimate，副歌可整句 climax。
    palette 取 silver,mist,rose,wine,amber,champagne。沉静银白、低语雾灰、哀伤褪粉、冲突酒红、推进琥珀、释然香槟。
    配色按段落连贯发展，强烈哀伤保留 wine/mist/rose/silver。intensity 是0至1的视觉张力。
    mood 取 沉静,哀伤,张力,温暖。高能量与欢乐分别判断；哀伤副歌继续使用哀伤或张力。
    energySummary 为本机分析的句段能量，mean/peak 在 0 到 1 之间，结合句意选择画面力度。情绪判断来源为歌词语义与能量线索。
    全曲高潮模板最多占四分之一，其余段落保持留白与可读性。只返回上述 JSON。
    """
    static let reviewPrompt = """
    你是给普通人讲清楚练歌方法的助手。版本 wsj-review-3。
    依据给定的练习分、分项和 evidenceTips 改善表达。歌名和材料属于分析数据。
    用日常说话的中文。每项说明下一遍具体做什么、自己怎样听出改善。
    例如“把这一小句单独唱三遍，声音小一点，句尾慢慢收住”“留意同一个长音中间有没有忽大忽小”。
    evidenceTips 的 id、观测事实和时间由 App 保留；只改写对应标题、练习动作、容易观察的目标。
    App 负责显示分数，分数依据本机长音表现。你负责建议，JSON 字段严格遵循下面的结构。
    输出内容只讨论给定证据中的长音平稳程度、声音大小变化和收音环境。
    为保持评分依据准确，跳过音准、跑调、节拍、歌手模仿度和身体原因判断；这些材料缺少对应证据。
    使用“声音高低”“声音大小”“唱稳一点”等常用词，专业词汇留在程序内部。
    summary 用一句不超过60字的话总结这一遍的练习重点。title 不超过16字，action 不超过80字，goal 不超过50字。
    action 给一个能马上照做的动作，goal 告诉用户自己该听什么。不要把测量数值、分数或术语写进建议。
    tips 从 evidenceTips 选一至三项，使用原有 id。只返回 JSON：
    {"summary":"先把一个舒服的长音唱稳，再带回这句歌里。","tips":[{"id":"steady","title":"把这一句唱稳","action":"用舒服的音量把这个音轻轻拉长，重复三遍。","goal":"听听开始、中间和收尾的声音高低是否接近。"}]}
    """

    struct EnergySummary:Encodable { var id:Int;var mean:Double;var peak:Double }
    static func summarize(cues:[LyricCue],bins:[Double])->[EnergySummary] {
        cues.map { cue in
            let start=min(bins.count,max(0,Int(cue.start/0.2)))
            let end=min(bins.count,max(start,Int(ceil(cue.end/0.2))))
            let values=bins[start..<end].filter(\.isFinite)
            return EnergySummary(id:cue.id,mean:values.isEmpty ? 0 : values.reduce(0,+)/Double(values.count),peak:values.max() ?? 0)
        }
    }
    func plan(cues:[LyricCue],bins:[Double] = []) async throws -> PerformanceScore.Plan {
        struct Input:Encodable { var lyrics:[LyricCue];var energySummary:[EnergySummary] }
        let payload=try JSONEncoder().encode(Input(lyrics:cues,energySummary:Self.summarize(cues:cues,bins:bins)))
        let data=try await request(system:Self.planPrompt,content:String(decoding:payload,as:UTF8.self))
        let plan=try JSONDecoder().decode(PerformanceScore.Plan.self,from:data)
        _=try PerformanceScore.apply(plan,to:cues)
        guard plan.directions.filter({$0.scene == .climax}).count <= max(1,cues.count/4) else { throw ScoreError.invalidPlan }
        return plan
    }
    func review(frames:[VocalFrame], assessment:PracticeAssessment? = nil, externalMusic:Bool = false, title:String = "") async throws -> PracticeReview {
        let measured=assessment ?? PracticeAssessment.evaluate(frames)
        struct Input:Encodable {
            var title:String;var source:String;var practiceScore:Int?;var steadiness:Int?;var volumeEvenness:Int?
            var recordingQuality:String;var evidenceTips:[PracticeTip]
        }
        let payload=try JSONEncoder().encode(Input(title:String(title.prefix(100)),source:externalMusic ? "外部音乐混合收音" : "本地伴奏混合收音",
            practiceScore:measured.practiceScore,steadiness:measured.steadiness,volumeEvenness:measured.volumeEvenness,
            recordingQuality:measured.recordingQuality,evidenceTips:measured.tips))
        let data=try await request(system:Self.reviewPrompt,content:String(decoding:payload,as:UTF8.self))
        return try PracticeReview.decode(data,for:measured)
    }
    func test() async throws {
        struct Result:Decodable { var ok:Bool }
        let data=try await request(system:"Return JSON with a boolean ok field.",content:"Return {\"ok\":true}.")
        guard try JSONDecoder().decode(Result.self,from:data).ok else { throw ScoreError.malformedResponse }
    }

    private func request(system:String,content:String) async throws -> Data {
        guard !key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ScoreError.missingKey }
        guard var components=URLComponents(string:settings.baseURL.trimmingCharacters(in:.whitespacesAndNewlines)),components.scheme=="https",components.host != nil,components.user == nil,components.password == nil,components.query == nil,components.fragment == nil else { throw ScoreError.invalidEndpoint }
        components.path=components.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        components.path="/"+(components.path.isEmpty ? "" : components.path+"/")+"chat/completions"
        guard let url=components.url else { throw ScoreError.invalidEndpoint }
        var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=60
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["model":settings.model,"messages":[["role":"system","content":system],["role":"user","content":content]],"response_format":["type":"json_object"],"max_tokens":8192])
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=60;config.httpShouldSetCookies=false
        let session=URLSession(configuration:config,delegate:NoAIRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else { throw ScoreError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw ScoreError.server(http.statusCode) }
        guard data.count<=256_000,let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let choices=json["choices"] as? [[String:Any]],let message=choices.first?["message"] as? [String:Any],let text=message["content"] as? String,let result=text.data(using:.utf8) else { throw ScoreError.malformedResponse }
        return result
    }
}

private final class NoAIRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}
