import AppKit
import Foundation

struct PasteboardItem: Codable {
    let values: [String: Data]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
if arguments.count != 3 {
    fail("usage: PasteboardSnapshot.swift <save|restore> <snapshot-path>")
}
let mode = arguments[1]
let url = URL(fileURLWithPath: arguments[2])
let pasteboard = NSPasteboard.general

switch mode {
case "save":
    let items = (pasteboard.pasteboardItems ?? []).map { item in
        PasteboardItem(values: Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
            item.data(forType: type).map { (type.rawValue, $0) }
        }))
    }
    do {
        let data = try PropertyListEncoder().encode(items)
        try data.write(to: url, options: .atomic)
    } catch {
        fail("could not save pasteboard: \(error)")
    }
case "restore":
    do {
        let data = try Data(contentsOf: url)
        let saved = try PropertyListDecoder().decode([PasteboardItem].self, from: data)
        let items = saved.map { savedItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, value) in savedItem.values {
                item.setData(value, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    } catch {
        fail("could not restore pasteboard: \(error)")
    }
default:
    fail("mode must be save or restore")
}
