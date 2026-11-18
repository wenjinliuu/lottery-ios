import Foundation

/// 开奖通知里带下来的东西，以及「拿它核对完之后怎么说」。
///
/// 这里全是纯函数：云端只推开奖号码，**票据从不离开手机**。
/// 中没中是 App 被通知唤醒后在本机算出来的。
enum DrawPushPayload {

    /// 每个彩种、期号的本机去重键。
    static func identifier(game: GameKey, issue: String) -> String {
        "draw-\(game.apiKey)-\(issue)"
    }

    static func usesServiceExtension(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["lottery_type"] != nil &&
            (userInfo["aps"] as? [String: Any])?["mutable-content"] as? Int == 1
    }

    /// 解析通知里的 `lottery_type` 和 `draw`。
    ///
    /// `draw` 和 `/v2/draws` 里的单条开奖是同一个结构，所以直接走
    /// `LotteryV2Mapper` —— 不为通知另写一套号码解码。
    static func parse(_ userInfo: [AnyHashable: Any]) -> Draw? {
        guard let type = userInfo["lottery_type"] as? String,
              let game = GameKey.fromAPIKey(type),
              let raw = userInfo["draw"] as? [String: Any],
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let item = try? JSONDecoder().decode(LotteryV2.DrawItem.self, from: data),
              let draw = LotteryV2Mapper.draw(item, game: game),
              !draw.drawValues.isEmpty else { return nil }
        return draw
    }

    /// 一期开奖对我手里这些票的结论。
    struct Outcome: Equatable {
        var tickets = 0
        var won = 0
        /// 中了但单注奖金还没公布的注数。
        var floating = 0
        var amount: Double = 0
        /// 奖级名 → 注数，按出现顺序。
        var prizes: [Prize] = []

        struct Prize: Equatable {
            var name: String
            var count: Int
        }

        mutating func add(winning: Bool, isFloating: Bool, prizeName: String, amount: Double) {
            tickets += 1
            guard winning else { return }
            won += 1
            if isFloating { floating += 1 }
            self.amount += amount
            if let index = prizes.firstIndex(where: { $0.name == prizeName }) {
                prizes[index].count += 1
            } else {
                prizes.append(Prize(name: prizeName, count: 1))
            }
        }

        /// 通知正文。没有票时返回 nil —— 那条开奖号码的通知原样留着就行。
        var winAlert: String? { won > 0 ? text : nil }

        var text: String? {
            guard tickets > 0 else { return nil }
            guard won > 0 else { return "\(tickets) 注都没中" }
            let list = prizes.map { "\($0.name) \($0.count) 注" }.joined(separator: "、")
            let money: String
            if floating == 0 {
                money = "共 \(MoneyText.format(amount))"
            } else if amount > 0 {
                money = "已确定 \(MoneyText.format(amount))，其余奖金待公布"
            } else {
                money = "奖金待公布"
            }
            return "\(tickets) 注中 \(won) 注：\(list)，\(money)"
        }
    }
}
