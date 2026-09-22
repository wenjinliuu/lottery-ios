import Foundation
@testable import LotteryWallet

/// V2 四个端点的样例响应。
///
/// **全部裁剪自真实响应**（`public_data/v2` 上的实际文件，和 CloudBase 同构），
/// 不是照着文档手写的。这一点当初救了命 —— 那时文档和实际有三处对不上，
/// 每一处都足以让对应端点静默失效：`latest.*.time` 文档里有实际没有、
/// `year` 文档说数字实际是字符串、日历的结构整个不同。
///
/// 数据端后来把这三处都对齐了（`year` 统一成数字、新增 `earliest_year`），
/// 但 fixture 仍然按「照着真实响应写」这条规矩维护，并且**新旧两种都留着** ——
/// GitHub 镜像要等下一次导出才会更新，在那之前读到的还是旧格式。
enum LotteryV2Fixtures {

    static var bootstrap: Data { Data(bootstrapJSON.utf8) }
    static var recentDraws: Data { Data(recentJSON.utf8) }
    static var yearDraws: Data { Data(yearJSON.utf8) }
    static var legacyYearDraws: Data { Data(legacyYearJSON.utf8) }
    static var calendar: Data { Data(calendarJSON.utf8) }

    static let bootstrapJSON = """
    {
      "schema": "duigehao.lottery.bootstrap",
      "version": 2,
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "timezone": "Asia/Shanghai",
      "latest": {
        "ssq": {
          "issue": "2026109", "date": "2026-09-20",
          "numbers": {"red": [9, 12, 15, 26, 30, 33], "blue": [6]},
          "pool": "0.00", "sales": "0",
          "fetched_at": "2026-09-20T21:34:06.201+08:00"
        },
        "kl8": {
          "issue": "2026253", "date": "2026-09-20",
          "numbers": {"nums": [1, 2, 8, 17, 23, 24, 29, 31, 40, 41,
                               46, 47, 51, 54, 59, 62, 65, 72, 74, 79]},
          "fetched_at": "2026-09-20T21:44:05.694+08:00"
        },
        "qxc": {
          "issue": "26109", "date": "2026-09-20",
          "numbers": {"digits": [2, 9, 0, 5, 0, 3, 9]},
          "pool": "0.00", "sales": "0",
          "fetched_at": "2026-09-20T21:44:07.049+08:00"
        },
        "qlc": {
          "issue": "2026108", "date": "2026-09-18",
          "numbers": {"basic": [11, 13, 19, 20, 25, 28, 29], "special": 26},
          "pool": "1518862.00", "sales": "4058672",
          "prizes": [
            {"name": "一等奖", "match": "中7+0"},
            {"name": "二等奖", "match": "中6+1", "winners": 3, "amount": "43695"}
          ],
          "fetched_at": "2026-09-20T04:55:56+08:00"
        }
      },
      "schedule": {
        "ssq": {
          "name": "双色球", "weekdays": [0, 2, 4],
          "draw_time": "21:15", "sale_close_time": "20:00",
          "next": {
            "issue": "2026110", "date": "2026-09-22",
            "open_time": "2026-09-22 21:15:00", "buy_end_time": "2026-09-22 20:00:00",
            "status": "inferred", "source": "schedule_inference",
            "confirmed": false, "basis_issue": "2026109"
          }
        },
        "kl8": {
          "name": "快乐8", "weekdays": [0, 1, 2, 3, 4, 5, 6],
          "draw_time": "21:30", "sale_close_time": "20:00",
          "next": {
            "issue": "2026254", "date": "2026-09-21",
            "open_time": "2026-09-21 21:30:00", "buy_end_time": "2026-09-21 20:00:00",
            "status": "inferred", "source": "schedule_inference",
            "confirmed": false, "basis_issue": "2026253"
          }
        },
        "qxc": {
          "name": "七星彩", "weekdays": [0, 2, 5],
          "draw_time": "20:30", "sale_close_time": "20:00",
          "next": {
            "issue": "26110", "date": "2026-09-22",
            "open_time": "2026-09-22 20:30:00", "buy_end_time": "2026-09-22 20:00:00",
            "status": "inferred", "source": "schedule_inference",
            "confirmed": false, "basis_issue": "26109"
          }
        },
        "qlc": {
          "name": "七乐彩", "weekdays": [1, 3, 5],
          "draw_time": "21:15", "sale_close_time": "20:00",
          "next": {
            "issue": "2026109", "date": "2026-09-21",
            "open_time": "2026-09-21 21:15:00", "buy_end_time": "2026-09-21 20:00:00",
            "status": "confirmed", "source": "official_calendar",
            "confirmed": true, "basis_issue": "2026108"
          }
        }
      }
    }
    """

    static let recentJSON = """
    {
      "schema": "duigehao.lottery.recent",
      "version": 2,
      "lottery_type": "ssq",
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "limit": 30,
      "draws": [
        {
          "issue": "2026109", "date": "2026-09-20",
          "numbers": {"red": [9, 12, 15, 26, 30, 33], "blue": [6]},
          "pool": "0.00", "sales": "0",
          "fetched_at": "2026-09-20T21:34:06.201+08:00"
        },
        {
          "issue": "2026108", "date": "2026-09-17",
          "numbers": {"red": [6, 11, 13, 14, 20, 28], "blue": [16]},
          "pool": "917243647.00", "sales": "335294274",
          "prizes": [
            {"name": "一等奖", "match": "中6+1", "winners": 2, "amount": "10000000"},
            {"name": "二等奖", "match": "中6+0", "winners": 95, "amount": "276194"}
          ],
          "fetched_at": "2026-09-18T05:39:32+08:00"
        }
      ]
    }
    """

    /// 现行契约：`year` / `earliest_year` 都是 **JSON 数字**。
    static let yearJSON = """
    {
      "schema": "duigehao.lottery.year",
      "version": 2,
      "lottery_type": "ssq",
      "year": 2026,
      "earliest_year": 2026,
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "draws": [
        {
          "issue": "2026109", "date": "2026-09-20",
          "numbers": {"red": [9, 12, 15, 26, 30, 33], "blue": [6]},
          "pool": "0.00", "sales": "0",
          "fetched_at": "2026-09-20T21:34:06.201+08:00"
        },
        {
          "issue": "2026001", "date": "2026-01-01",
          "numbers": {"red": [1, 2, 3, 4, 5, 6], "blue": [7]},
          "pool": "1.00", "sales": "2",
          "fetched_at": "2026-01-01T22:00:00+08:00"
        }
      ]
    }
    """

    /// 扁平数组；`draw_time` / `sale_close_time` **只有时刻**，没有日期。
    static let calendarJSON = """
    {
      "schema": "duigehao.lottery.calendar",
      "version": 2,
      "year": 2026,
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "entries": [
        {"lottery_type": "kl8", "issue": "2026001", "date": "2026-01-01",
         "draw_time": "21:30:00", "sale_close_time": "20:00:00"},
        {"lottery_type": "ssq", "issue": "2026001", "date": "2026-01-01",
         "draw_time": "21:15:00", "sale_close_time": "20:00:00"},
        {"lottery_type": "kl8", "issue": "2026002", "date": "2026-01-02",
         "draw_time": "21:30:00", "sale_close_time": "20:00:00"},
        {"lottery_type": "ssq", "issue": "2026002", "date": "2026-01-04",
         "draw_time": "21:15:00", "sale_close_time": "20:00:00"}
      ]
    }
    """

    /// 迁移之前生成的 GitHub 镜像：`year` 是**字符串**，而且没有
    /// `earliest_year`。这份还会在镜像重新导出之前被读到，不能解码失败，
    /// 也不能因为少了边界字段就乱判断。
    static let legacyYearJSON = """
    {
      "schema": "duigehao.lottery.year",
      "version": 2,
      "lottery_type": "ssq",
      "year": "2026",
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "draws": [
        {
          "issue": "2026109", "date": "2026-09-20",
          "numbers": {"red": [9, 12, 15, 26, 30, 33], "blue": [6]},
          "fetched_at": "2026-09-20T21:34:06.201+08:00"
        }
      ]
    }
    """

    /// 按年响应的构造器。
    ///
    /// 渐进式加载那组用例要分别控制**年份**、**边界**和**空不空**，
    /// 写死一份 fixture 不够用 —— 而这三样恰恰决定了「还能不能往前翻」。
    static func yearPayload(year: Int, earliestYear: Int?, empty: Bool = false) -> Data {
        let boundary = earliestYear.map { "\n      \"earliest_year\": \($0)," } ?? ""
        let draws = empty ? "" : """

              {
                "issue": "\(year)109", "date": "\(year)-09-20",
                "numbers": {"red": [9, 12, 15, 26, 30, 33], "blue": [6]},
                "fetched_at": "\(year)-09-20T21:34:06.201+08:00"
              },
              {
                "issue": "\(year)001", "date": "\(year)-01-01",
                "numbers": {"red": [1, 2, 3, 4, 5, 6], "blue": [7]},
                "fetched_at": "\(year)-01-01T22:00:00+08:00"
              }
        """
        return Data("""
        {
          "schema": "duigehao.lottery.year",
          "version": 2,
          "lottery_type": "ssq",
          "year": \(year),\(boundary)
          "generated_at": "\(year)-09-21T00:52:29.144+08:00",
          "draws": [\(draws)]
        }
        """.utf8)
    }

    // MARK: - 抓取状态

    static var status: Data { Data(statusJSON.utf8) }

    /// 文档给的那份样例：六个 completed、一个 numbers_ready、一个 waiting。
    /// 对应界面上的 `09月22日 02:44 · 执行成功 · 6/8 数据完整`。
    static let statusJSON = """
    {
      "latest_execution": {
        "executed_at": "2026-09-22T02:44:00+08:00",
        "execution_status": "success"
      },
      "lotteries": {
        "ssq": {"data_status": "completed"},
        "dlt": {"data_status": "completed"},
        "fc3d": {"data_status": "completed"},
        "pl3": {"data_status": "completed"},
        "pl5": {"data_status": "completed"},
        "qxc": {"data_status": "completed"},
        "qlc": {"data_status": "numbers_ready"},
        "kl8": {"data_status": "waiting"}
      }
    }
    """

    /// 执行失败。
    static let failedStatusJSON = """
    {
      "latest_execution": {
        "executed_at": "2026-09-22T02:44:00+08:00",
        "execution_status": "failed"
      },
      "lotteries": {
        "ssq": {"data_status": "completed"}
      }
    }
    """

    /// 还没有执行记录。界面上是「暂无执行记录」，不是「0/8」。
    static let emptyStatusJSON = """
    {
      "latest_execution": null,
      "lotteries": {}
    }
    """

    /// 八个全齐。
    static let completeStatusJSON = """
    {
      "latest_execution": {
        "executed_at": "2026-09-22T02:44:00+08:00",
        "execution_status": "success"
      },
      "lotteries": {
        "ssq": {"data_status": "completed"},
        "dlt": {"data_status": "completed"},
        "kl8": {"data_status": "completed"},
        "fc3d": {"data_status": "completed"},
        "pl3": {"data_status": "completed"},
        "pl5": {"data_status": "completed"},
        "qxc": {"data_status": "completed"},
        "qlc": {"data_status": "completed"}
      }
    }
    """

    /// 少了三个彩种、其中一个值是 `null`。
    ///
    /// **分母仍然是 8。** 跟着字典大小走的话这份会显示成 `5/5 数据完整`，
    /// 恰好把「后端连记录都没有」这件事抹平。
    static let sparseStatusJSON = """
    {
      "latest_execution": {
        "executed_at": "2026-09-22T02:44:00+08:00",
        "execution_status": "success"
      },
      "lotteries": {
        "ssq": {"data_status": "completed"},
        "dlt": {"data_status": "completed"},
        "kl8": {"data_status": "completed"},
        "fc3d": {"data_status": "completed"},
        "pl3": {"data_status": "completed"},
        "qlc": null
      }
    }
    """

    /// 空到不能再空的一份 bootstrap：字段能省的全省了。
    /// 服务端省略空值是常态，这种响应不能把解码打挂。
    static let sparseBootstrapJSON = """
    {
      "schema": "duigehao.lottery.bootstrap",
      "version": 2,
      "latest": {
        "ssq": {"issue": "2026109", "date": "2026-09-20",
                "numbers": {"red": [1, 2, 3, 4, 5, 6], "blue": [7]}}
      },
      "schedule": {
        "ssq": {"name": "双色球", "weekdays": [0, 2, 4],
                "next": {"status": "unavailable"}}
      }
    }
    """
}
