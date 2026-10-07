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
