import SwiftUI
import UniformTypeIdentifiers

/// 「导出数据…」交给系统的那个文件。
///
/// 只是 `fileExporter` 要求的一层薄壳：里面就是 `BackupService.exportData`
/// 产出的那份 JSON，一个字节都没改过。
///
/// **导出和备份必须是同一种文件。** 用户手里那个导出的文件，将来要能原样
/// 从「从文件导入」读回来；两套格式意味着某一天他拿着一个文件，
/// 而 App 说「这不是我的备份」。
struct BackupDocument: FileDocument {
    /// 只写不读。这个类型只用于导出 —— 导入走的是
    /// `fileImporter` + `BackupService`，那条路要做版本兼容和合并，
    /// 不是简单地把字节读进来。
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        // 不会被调用：`readableContentTypes` 是空的。
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
