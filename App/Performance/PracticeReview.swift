import Foundation

struct PracticeReview:Decodable,Equatable {
    struct Suggestion:Decodable,Equatable {
        var id:String
        var title:String
        var action:String
        var goal:String
    }
    var summary:String
    var tips:[Suggestion]

    static func decode(_ data:Data,for assessment:PracticeAssessment) throws -> Self {
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(json.keys)==Set(["summary","tips"]),
              let rows=json["tips"] as? [[String:Any]],
              rows.allSatisfy({Set($0.keys)==Set(["id","title","action","goal"])}) else { throw CoachingError.unusable }
        let result=try JSONDecoder().decode(Self.self,from:data)
        let ids=Set(assessment.tips.map(\.id))
        guard !result.summary.isEmpty,result.summary.count<=120,
              !result.tips.isEmpty,result.tips.count<=3,
              Set(result.tips.map(\.id)).count==result.tips.count,
              result.tips.allSatisfy({ids.contains($0.id) && !$0.title.isEmpty && $0.title.count<=24 &&
                  !$0.action.isEmpty && $0.action.count<=120 && !$0.goal.isEmpty && $0.goal.count<=80}) else { throw CoachingError.unusable }
        let text=([result.summary]+result.tips.flatMap { [$0.title,$0.action,$0.goal] }).joined(separator:"\n")
        let jargon=["基频","置信度","电平","音分","赫兹","分贝","共振峰","声压","声带闭合","气息支撑","jitter","shimmer","cents","hz","db","f0"]
        let unsupported=["跑调","音准","节拍","抢拍","拖拍","唱错","参考旋律"]
        guard !(jargon+unsupported).contains(where:{text.lowercased().contains($0.lowercased())}),
              text.range(of:#"\d+\s*(?:分|/\s*100|%)"#,options:.regularExpression)==nil else { throw CoachingError.unusable }
        return result
    }

    func applying(to base:[PracticeTip])->[PracticeTip] {
        base.map { tip in
            guard let suggestion=tips.first(where:{$0.id==tip.id}) else { return tip }
            var value=tip
            value.title=suggestion.title;value.action=suggestion.action;value.goal=suggestion.goal
            return value
        }
    }
}

enum CoachingError:LocalizedError {
    case unusable
    var errorDescription:String? { "AI 这次的建议还不够清楚，先显示本机练习建议。" }
}
