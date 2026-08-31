import Foundation

private func values(at path: UnsafePointer<CChar>) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: String(cString: path))) else { return [:] }
    guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fputs("Oizys config is not a JSON object; using defaults\n", stderr)
        return [:]
    }
    return values
}

@_cdecl("oizys_settings_read")
func readSettings(_ path: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
                  _ apply: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void) {
    for (key, value) in values(at: path) {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber { text = number.stringValue }
        else { continue }
        key.withCString { key in text.withCString { apply(context, key, $0) } }
    }
}

@_cdecl("oizys_settings_write")
func writeSettings(_ path: UnsafePointer<CChar>, _ key: UnsafePointer<CChar>,
                   _ value: UnsafePointer<CChar>, _ type: Int32) -> Int32 {
    var settings = values(at: path)
    let text = String(cString: value)
    settings[String(cString: key)] = type == 2 ? (text == "true") : type == 1 ? (Double(text) as Any) : text
    do {
        let url = URL(fileURLWithPath: String(cString: path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return 0
    } catch { fputs("Oizys could not save settings: \(error)\n", stderr); return -1 }
}

@_cdecl("oizys_settings_reset")
func resetSettings(_ path: UnsafePointer<CChar>) -> Int32 {
    let file = String(cString: path)
    if !FileManager.default.fileExists(atPath: file) { return 0 }
    do { try FileManager.default.removeItem(atPath: file); return 0 }
    catch { return -1 }
}
