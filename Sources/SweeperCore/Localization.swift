import Foundation

/// 翻译：用中文原文作为查找的键，在 App 的 en.lproj/Localizable.strings 里找英文。
/// 系统语言是中文、或者找不到翻译时，原样返回中文；命令行版没有翻译文件，始终是中文。
///
/// 带变量的句子写成格式：L("已选 %@", 大小)、L("%ld 个项目", 数量)。
/// 字符串用 %@，整数用 %ld。
public func L(_ key: String, _ args: CVarArg...) -> String {
    let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? text : String(format: text, arguments: args)
}

/// 版本号比较：按数字逐段比，0.12.0 < 0.13.0 < 1.0.0
public enum Version {
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
