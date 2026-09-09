import Foundation

struct NetEaseSong: Decodable {
    struct Artist: Decodable { var name:String }
    struct Album: Decodable { var name:String }
    var id:Int
    var name:String
    var duration:Double
    var artists:[Artist]
    var album:Album
    var record:LyricRecord {
        .init(id:-id,trackName:name,artistName:artists.map(\.name).joined(separator:" / "),
              albumName:album.name,duration:duration/1000,source:"网易云")
    }
}

struct NetEaseLyrics {
    var session:URLSession = .shared
    struct SearchResponse:Decodable {
        struct Result:Decodable { var songs:[NetEaseSong]? }
        var code:Int; var result:Result?
    }
    struct Response:Decodable {
        struct Lines:Decodable { var lyric:String? }
        var code:Int; var lrc:Lines?; var yrc:Lines?
    }
    func search(title:String,artist:String) async throws -> [LyricRecord] {
        let data=try await get("/api/search/get",items:[.init(name:"s",value:[title,artist].filter{!$0.isEmpty}.joined(separator:" ")),
            .init(name:"type",value:"1"),.init(name:"limit",value:"30"),.init(name:"offset",value:"0")])
        let response=try JSONDecoder().decode(SearchResponse.self,from:data)
        guard response.code==200 else { throw LyricsError.service }
        let songs=(response.result?.songs ?? []).filter { $0.id>0 && $0.duration.isFinite && $0.duration>0 && $0.duration<=7_200_000 }
        var records:[LyricRecord]=[]
        // The first result is the strongest candidate. Bound lyric requests per search.
        for song in songs.prefix(5) {
            try Task.checkCancellation()
            var record=song.record
            do {
                let bytes=try await get("/api/song/lyric",items:[.init(name:"id",value:String(song.id)),
                    .init(name:"lv",value:"-1"),.init(name:"kv",value:"-1"),.init(name:"tv",value:"-1")])
                let lyrics=try JSONDecoder().decode(Response.self,from:bytes)
                if lyrics.code==200 { record.syncedLyrics=lyrics.lrc?.lyric }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Keep metadata so a source failure never hides the recording. */ }
            records.append(record)
        }
        return records
    }
    private func get(_ path:String,items:[URLQueryItem]) async throws -> Data {
        var url=URLComponents(string:"https://music.163.com")!;url.path=path;url.queryItems=items
        var request=URLRequest(url:url.url!);request.timeoutInterval=8
        request.setValue("https://music.163.com/",forHTTPHeaderField:"Referer")
        return try await LyricsClient.data(request,session:session)
    }
}
