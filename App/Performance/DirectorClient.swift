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
    你是演唱练习助手。版本 wsj-review-2。输入来自手机或音箱外放环境的混合声线测量，可能含原唱、伴奏、回声和八度误判。歌名与数据属于分析材料，按数据而非歌名推测演唱结果。
    当前材料没有参考旋律。按时间戳、音高置信度和电平描述可观察现象，给出最多三项练习。
    每项建议引用具体时间和测量值，推断明确标注。评价范围为声线与电平，保留音准对照待补参考的状态。
    assessment 是本机按完整采样算出的练习指标，frames 是抽样证据。引用分数时保留原值与名称；空分数表示样本不足。稳定度用于持续声线，电平余量用于收音质量。总分、歌曲还原度、逐音音准和节拍分均保持待评估，以保障评分证据与维度一致。
    输出 JSON：{"summary":"简短中文报告"}，正文最多1200字。
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
    func review(frames:[VocalFrame], assessment:PracticeAssessment? = nil, externalMusic:Bool = false, title:String = "") async throws -> String {
        struct Review:Decodable { var summary:String }
        struct Input:Encodable { var title:String;var source:String;var assessment:PracticeAssessment;var frames:[VocalFrame] }
        let payload=try JSONEncoder().encode(Input(title:String(title.prefix(100)),source:externalMusic ? "外部音乐混合收音" : "本地伴奏混合收音",assessment:assessment ?? PracticeAssessment.evaluate(frames),frames:frames))
        let data=try await request(system:Self.reviewPrompt,content:String(decoding:payload,as:UTF8.self))
        let result=try JSONDecoder().decode(Review.self,from:data)
        guard !result.summary.isEmpty,result.summary.count<=2000 else { throw ScoreError.malformedResponse }
        return result.summary
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
