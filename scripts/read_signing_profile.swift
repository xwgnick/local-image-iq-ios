import Foundation

enum ProfileReadError: Error { case arguments, dictionary, unsupportedValue }

func jsonValue(_ value: Any) throws -> Any {
    switch value {
    case let data as Data:
        return data.base64EncodedString()
    case let date as Date:
        return ISO8601DateFormatter().string(from: date)
    case let dictionary as [String: Any]:
        return try dictionary.mapValues(jsonValue)
    case let array as [Any]:
        return try array.map(jsonValue)
    case let string as String:
        return string
    case let number as NSNumber:
        return number
    default:
        throw ProfileReadError.unsupportedValue
    }
}

do {
    guard CommandLine.arguments.count == 2 else { throw ProfileReadError.arguments }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let profile = try PropertyListSerialization.propertyList(from: bytes, format: nil)
    guard profile is [String: Any] else { throw ProfileReadError.dictionary }
    let output = try JSONSerialization.data(withJSONObject: jsonValue(profile), options: [.sortedKeys])
    FileHandle.standardOutput.write(output)
} catch {
    FileHandle.standardError.write(Data("Cannot decode verified provisioning profile.\n".utf8))
    exit(1)
}
