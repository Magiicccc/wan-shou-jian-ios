import Foundation
import Combine

struct ExternalTrack: Equatable {
    var title: String
    var artist: String
    var album: String = ""
    var duration: Double
    var key: String { [Self.normalize(title), Self.normalize(artist), String(Int(duration.rounded()))].joined(separator:"|") }
    func sameRecording(as other:Self) -> Bool {
        Self.normalize(title)==Self.normalize(other.title) && Self.normalize(artist)==Self.normalize(other.artist) && abs(duration-other.duration)<=2
    }
    static func normalize(_ text: String) -> String {
        text.folding(options:[.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale:Locale(identifier:"en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

struct PlayerSnapshot {
    var track: ExternalTrack
    var elapsed: Double?
    var rate: Double?
    var observed: Double

    init?(dictionary: [String:Any], now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard let title=dictionary["title"] as? String, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let duration=(dictionary["duration"] as? NSNumber)?.doubleValue,
              duration.isFinite, duration>0, duration<=7200 else { return nil }
        track = .init(title:String(title.prefix(200)), artist:String((dictionary["artist"] as? String ?? "").prefix(200)),
                      album:String((dictionary["album"] as? String ?? "").prefix(200)), duration:duration)
        observed=uptime
        if let value=(dictionary["rate"] as? NSNumber)?.doubleValue, value.isFinite, (0...4).contains(value) { rate=value }
        if let value=(dictionary["elapsed"] as? NSNumber)?.doubleValue, value.isFinite, value>=0, value<=duration {
            var corrected=value
            if let date=dictionary["timestamp"] as? Date, let rate {
                let age=now.timeIntervalSince(date)
                guard age.isFinite, age>=(-2), age<=86400 else { return }
                corrected += max(0,age)*rate
            }
            elapsed=min(duration,corrected)
        }
    }
}

struct LyricClock {
    var anchor=0.0
    var observed=0.0
    var rate=0.0
    var duration=1.0
    var system=false
    var offset=0.0
    func position(at now:Double) -> Double {
        guard now.isFinite else { return max(0,min(duration,anchor)) }
        // System estimates expire after eight seconds without a fresh response.
        let delta=max(0,now-observed)
        return max(0,min(duration,anchor + min(delta,system ? 8 : delta)*rate + offset))
    }
    mutating func freeze(at now:Double) { anchor=position(at:now)-offset; observed=now; rate=0 }
}

struct LyricRecord: Codable, Identifiable, Equatable {
    var id: Int
    var trackName: String
    var artistName: String
    var albumName: String?
    var duration: Double
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
    var source: String? = nil
    var wordLyrics:String? = nil
    var sourceName:String { source ?? "LRCLIB" }
    var hasTiming: Bool {
        !(syncedLyrics?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) ||
        !(wordLyrics?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)
    }
    var track: ExternalTrack { .init(title:trackName,artist:artistName,album:albumName ?? "",duration:duration) }
    func matches(_ other: ExternalTrack) -> Bool {
        duration.isFinite && abs(duration-other.duration)<=2 &&
        ExternalTrack.normalize(trackName)==ExternalTrack.normalize(other.title) &&
        ((!other.artist.isEmpty && ExternalTrack.normalize(artistName)==ExternalTrack.normalize(other.artist)) ||
         (other.artist.isEmpty && !other.album.isEmpty && ExternalTrack.normalize(albumName ?? "")==ExternalTrack.normalize(other.album)))
    }
    static func automatic(in records:[Self], for track:ExternalTrack) -> Self? {
        let exact=records.filter { $0.matches(track) && $0.hasTiming }
        let album=exact.filter { !track.album.isEmpty && ExternalTrack.normalize($0.albumName ?? "")==ExternalTrack.normalize(track.album) }
        let choices=album.isEmpty ? exact : album
        // Duplicate releases with identical timelines are safe; differing versions need a choice.
        guard let first=choices.first, choices.allSatisfy({ $0.syncedLyrics==first.syncedLyrics && $0.wordLyrics==first.wordLyrics }) else { return nil }
        return first
    }
}

enum LyricsError: LocalizedError {
    case service, tooLarge, timing
    var errorDescription: String? {
        switch self {
        case .service: return "歌词服务暂时不可用，可重试搜索或导入 LRC。"
        case .tooLarge: return "歌词响应超过大小上限，请换一个版本。"
        case .timing: return "这个版本提供纯文本歌词，可阅读；同步需要带时间轴的版本。"
        }
    }
}

struct LyricsClient {
    var session: URLSession = .shared
    func search(title:String, artist:String = "") async throws -> [LyricRecord] {
        var primary:[LyricRecord]=[]
        do { primary=try await NetEaseLyrics(session:session).search(title:title,artist:artist) }
        catch is CancellationError { throw CancellationError() }
        catch { }
        try Task.checkCancellation()
        if primary.contains(where: {
            $0.hasTiming && ExternalTrack.normalize($0.trackName)==ExternalTrack.normalize(title) &&
            (artist.isEmpty || ExternalTrack.normalize($0.artistName)==ExternalTrack.normalize(artist))
        }) { return primary }
        do { return primary + (try await searchLRCLIB(title:title,artist:artist)) }
        catch is CancellationError { throw CancellationError() }
        catch { if !primary.isEmpty { return primary };throw error }
    }
    private func searchLRCLIB(title:String, artist:String) async throws -> [LyricRecord] {
        var url=URLComponents(string:"https://lrclib.net/api/search")!
        url.queryItems=artist.isEmpty ? [.init(name:"q",value:String(title.prefix(200)))] :
            [.init(name:"track_name",value:String(title.prefix(200))),.init(name:"artist_name",value:String(artist.prefix(200)))]
        var request=URLRequest(url:url.url!);request.timeoutInterval=15
        request.setValue("WanShouJian/0.4.0",forHTTPHeaderField:"User-Agent")
        let data=try await Self.data(request,session:session)
        return try JSONDecoder().decode([LyricRecord].self,from:data).filter {
            $0.duration.isFinite && $0.duration>0 && $0.duration<=7200 && $0.trackName.count<=300
        }.prefix(40).map { $0 }
    }
    static func data(_ request:URLRequest,session:URLSession) async throws -> Data {
        let (bytes,response)=try await session.bytes(for:request)
        guard let response=response as? HTTPURLResponse, response.statusCode==200 else { throw LyricsError.service }
        guard response.expectedContentLength<=2_000_000 else { throw LyricsError.tooLarge }
        var data=Data()
        for try await byte in bytes {
            if data.count>=2_000_000 { throw LyricsError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

@MainActor final class ExternalLyrics: ObservableObject {
    @Published private(set) var track: ExternalTrack?
    @Published private(set) var cues: [LyricCue] = []
    @Published private(set) var results: [LyricRecord] = []
    @Published private(set) var plainText=""
    @Published private(set) var message="开始收音后尝试读取播放器；也可以搜索歌曲。"
    @Published private(set) var syncing="等待歌曲"
    @Published private(set) var busy=false
    @Published private(set) var selectedID: Int?
    @Published var offset=0.0 { didSet { clock.offset=offset.isFinite ? min(10,max(-10,offset)) : 0 } }
    private(set) var clock=LyricClock()
    private var poll:Task<Void,Never>?
    private var lookup:Task<Void,Never>?
    private var epoch=0
    private var pollEpoch=0
    private var lastPlayerKey=""
    private var active=false
    private var manuallyAligned=false
    private var audioAligned=false
    private var lastPlayerTime = -Double.infinity
    private var lastHeardTime = -Double.infinity
    private let preview:Bool
    private let search: (String,String) async throws -> [LyricRecord]
    private let read: () async -> PlayerSnapshot?
    private var cache:[LyricRecord]=[]
    private let cacheURL:URL?

    init(preview:Bool=false, search:((String,String) async throws -> [LyricRecord])?=nil,
         read:(() async -> PlayerSnapshot?)?=nil, cacheURL:URL?=nil) {
        self.preview=preview
        self.search=search ?? { try await LyricsClient().search(title:$0,artist:$1) }
        self.read=read ?? {
            await withCheckedContinuation { continuation in
                WSJNowPlayingReader.read { dictionary in
                    continuation.resume(returning:(dictionary as? [String:Any]).flatMap { PlayerSnapshot(dictionary:$0) })
                }
            }
        }
        self.cacheURL=preview ? nil : cacheURL ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.appendingPathComponent("stage-lyrics.json")
        if let url=self.cacheURL, let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size<=2_000_000,
           let data=try? Data(contentsOf:url), let saved=try? JSONDecoder().decode([LyricRecord].self,from:data) { cache=Array(saved.prefix(20)) }
    }
    deinit { poll?.cancel();lookup?.cancel() }
    func position(at now:Double = ProcessInfo.processInfo.systemUptime) -> Double { clock.position(at:now) }
    var currentCue:LyricCue? { PerformanceScore.cue(at:position(),in:cues) }
    var nextCue:LyricCue? { cues.first { $0.start>position() } }
    var hasPosition:Bool {
        manuallyAligned || (clock.system && ((!active && clock.rate==0) || ProcessInfo.processInfo.systemUptime-clock.observed<8))
    }
    func accept(words:[HeardWord]) {
        let now=ProcessInfo.processInfo.systemUptime
        guard active,!manuallyAligned,now-lastPlayerTime>4,!cues.isEmpty,
              let match=LyricAlignment.match(words:words,cues:cues,near:hasPosition ? position() : nil,now:now),
              match.observed>lastHeardTime else { return }
        lastHeardTime=match.observed;audioAligned=true
        clock = .init(anchor:match.cue.start,observed:match.observed,rate:1,duration:track?.duration ?? match.cue.end,system:true)
        syncing="声音辅助同步 · 句级估计"
    }

    func reset() {
        stop();epoch += 1;lookup?.cancel();lookup=nil;track=nil;cues=[];results=[];plainText="";busy=false
        lastPlayerKey="";selectedID=nil;manuallyAligned=false;clock=LyricClock();offset=0
        audioAligned=false;lastPlayerTime = -.infinity;lastHeardTime = -.infinity
        syncing="等待歌曲";message="开始收音后尝试读取播放器；也可以搜索歌曲。"
    }
    func start() {
        guard !active else { return };active=true;pollEpoch += 1
        if manuallyAligned { clock.anchor=position()-clock.offset;clock.observed=ProcessInfo.processInfo.systemUptime;clock.rate=1 }
        guard !preview else { return }
        let token=pollEpoch
        poll=Task { [weak self] in
            while !Task.isCancelled {
                guard let reader=self?.read else { return }
                let snapshot=await reader()
                guard let self,self.active,self.pollEpoch==token,!Task.isCancelled else { return }
                if let snapshot { self.accept(snapshot) }
                else if !self.manuallyAligned {
                    self.syncing=self.hasPosition ? (self.audioAligned ? "声音辅助同步 · 句级估计" : "播放器同步") : "正在重新同步"
                    self.message=self.cues.isEmpty ? "正在获取曲目信息；也可搜索歌名定位版本。" : "正在聆听音乐，自动核对歌词位置。"
                }
                do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return }
            }
        }
    }
    func stop() {
        active=false;pollEpoch += 1;poll?.cancel();poll=nil;clock.freeze(at:ProcessInfo.processInfo.systemUptime)
    }
    func accept(_ snapshot:PlayerSnapshot) {
        let changed=lastPlayerKey != snapshot.track.key
        if changed {
            lastPlayerKey=snapshot.track.key
            let preserve=track?.sameRecording(as:snapshot.track) ?? false
            track=snapshot.track
            if !preserve {
                cues=[];plainText="";selectedID=nil;manuallyAligned=false;offset=0
                audioAligned=false;lastHeardTime = -.infinity;lastPlayerTime = -.infinity
                clock=LyricClock(duration:snapshot.track.duration)
                find(title:snapshot.track.title,artist:snapshot.track.artist,automatic:snapshot.track)
            }
        }
        guard !manuallyAligned,track?.sameRecording(as:snapshot.track)==true,
              let elapsed=snapshot.elapsed,let rate=snapshot.rate else { return }
        clock = .init(anchor:elapsed,observed:snapshot.observed,rate:rate,duration:snapshot.track.duration,system:true,offset:offset)
        audioAligned=false;lastPlayerTime=ProcessInfo.processInfo.systemUptime
        syncing=rate==0 ? "播放器已暂停" : "播放器同步 · 实验"
    }
    func find(title:String,artist:String="",automatic:ExternalTrack?=nil) {
        let query=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        epoch += 1;let token=epoch;lookup?.cancel();busy=true;results=[]
        if let automatic, let saved=LyricRecord.automatic(in:cache,for:automatic) {
            busy=false;choose(saved,preserveClock:true);message="已载入本机缓存 · \(saved.sourceName)";return
        }
        lookup=Task { [weak self] in
            guard let search=self?.search else { return }
            do {
                let records=try await search(query,artist)
                guard let self,self.epoch==token,!Task.isCancelled else { return }
                self.results=records;self.busy=false
                if let automatic,let record=LyricRecord.automatic(in:records,for:automatic) { self.choose(record,preserveClock:true) }
                else {
                    let exact=records.filter { $0.hasTiming && ExternalTrack.normalize($0.trackName)==ExternalTrack.normalize(query) &&
                        !artist.isEmpty && ExternalTrack.normalize($0.artistName)==ExternalTrack.normalize(artist) }
                    if automatic==nil,exact.count==1 { self.choose(exact[0]) }
                    else { self.message=records.isEmpty ? "各歌词源暂未找到匹配曲目。" : "正在核对版本，可在下方查看曲目。" }
                }
            } catch {
                guard let self,self.epoch==token,!Task.isCancelled else { return }
                self.busy=false;self.message="歌词搜索暂未完成，请检查网络后重试。"
            }
        }
    }
    func choose(_ record:LyricRecord,preserveClock:Bool=false) {
        guard record.duration.isFinite,record.duration>0,record.duration<=7200 else { return }
        epoch += 1;lookup?.cancel();busy=false
        let keep=preserveClock || (track.map { record.matches($0) } ?? false)
        track=record.track;selectedID=record.id;plainText=String((record.plainLyrics ?? "").prefix(100_000))
        cues=(try? PerformanceScore.parseYRC(record.wordLyrics ?? "",duration:record.duration)) ??
            (try? PerformanceScore.parseLRC(record.syncedLyrics ?? "",duration:record.duration)) ?? []
        if !keep { clock=LyricClock(duration:record.duration);offset=0;manuallyAligned=false;audioAligned=false;lastHeardTime = -.infinity;syncing="正在自动定位" }
        message=cues.isEmpty ? "已找到曲目，正在等待可用的时间轴歌词。" : "\(cues.contains(where:{$0.words != nil}) ? "逐字歌词" : "句级歌词") · \(record.sourceName) · 自动定位"
        cache.removeAll { $0.id==record.id };cache.insert(record,at:0);cache=Array(cache.prefix(20))
        if let url=cacheURL,let data=try? JSONEncoder().encode(cache),data.count<=2_000_000 { try? data.write(to:url,options:.atomic) }
    }
    func align(to cue:LyricCue) {
        guard cues.contains(cue) else { return }
        manuallyAligned=true;offset=0
        clock = .init(anchor:cue.start,observed:ProcessInfo.processInfo.systemUptime,rate:active ? 1 : 0,duration:track?.duration ?? cue.end)
        syncing="手动对齐";message="跟随本机时间轴。网易云跳转或换歌后，可再次点选当前句。"
    }
    func followPlayer() {
        manuallyAligned=false;audioAligned=false;lastPlayerKey="";lastHeardTime = -.infinity
        clock=LyricClock(duration:track?.duration ?? 1);syncing="正在重新同步"
    }
    func apply(_ plan:PerformanceScore.Plan) throws { cues=try PerformanceScore.apply(plan,to:cues) }
    func importLRC(_ text:String,title:String) throws {
        let duration=track?.duration ?? 1200
        let parsed=try PerformanceScore.parseLRC(text,duration:duration)
        epoch += 1;lookup?.cancel();busy=false;selectedID=nil;plainText=""
        if track==nil { track = .init(title:title,artist:"本机歌词",duration:duration) }
        cues=parsed;clock.duration=duration;message="本机 LRC · 点选当前句可对齐外部音乐。"
    }
    func loadPreview() {
        guard preview else { return }
        let lrc=PerformanceScore.demo.map { String(format:"[%02d:%05.2f]%@",Int($0.start)/60,$0.start.truncatingRemainder(dividingBy:60),$0.text) }.joined(separator:"\n")
        choose(.init(id:-1,trackName:PerformanceScore.demoTitle,artistName:"原创演示",albumName:"私人舞台",duration:48,syncedLyrics:lrc))
        if let first=cues.first { align(to:first) }
    }
}
