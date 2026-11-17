// Experiment: what the App Sandbox lets an app do with the Trash.
// Run sandboxed (ad hoc signed with the entitlements given to run.sh).
// Argument: the folder to work in (inside ~/Pictures for the Store's
// entitlements). Prints one line per step.
import AppKit

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default

// A later process (a relaunched app): take back what an earlier one trashed
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "later" {
    for name in ["Stay Folder", "stay-file.txt"] {
        let inTrash = URL(fileURLWithPath: "/Users/\(NSUserName())/.Trash").appendingPathComponent(name)
        var info = stat()
        print("[later \(name)] in Trash: \(inTrash.path), lstat \(lstat(inTrash.path, &info) == 0 ? "ok" : String(cString: strerror(errno)))")
        do {
            try fm.moveItem(at: inTrash, to: base.appendingPathComponent(name))
            print("[later \(name)] moveItem out of Trash: OK")
        } catch {
            print("[later \(name)] moveItem out of Trash failed: \(error as NSError)")
        }
    }
    exit(0)
}

// A volume of its own (a disk image): its Trash is .Trashes/<uid> there
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "volume" {
    let url = base.appendingPathComponent("vol-folder")
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: url.appendingPathComponent("inside.txt"))
    var result: NSURL?
    do {
        try fm.trashItem(at: url, resultingItemURL: &result)
        print("[volume] trashItem → \(result?.path ?? "nil")")
        if let inTrash = result as URL? {
            try fm.moveItem(at: inTrash, to: url)
            print("[volume] moveItem out of Trash: OK, back at \(fm.fileExists(atPath: url.path))")
        }
    } catch {
        print("[volume] failed: \(error as NSError)")
    }
    exit(0)
}
let home = NSHomeDirectory()
print("home (container?): \(home)")
print("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "no")")

func describe(_ error: Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    while let e = current {
        parts.append("\(e.domain) \(e.code)")
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return parts.joined(separator: " <- ")
}

func make(_ name: String, folder: Bool) -> URL {
    let url = base.appendingPathComponent(name)
    try? fm.removeItem(at: url)
    if folder {
        try! fm.createDirectory(at: url, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: url.appendingPathComponent("inside.txt"))
    } else {
        try! Data("x".utf8).write(to: url)
    }
    return url
}

func roundTrip(_ name: String, folder: Bool) {
    let url = make(name, folder: folder)
    var result: NSURL?
    do {
        try fm.trashItem(at: url, resultingItemURL: &result)
    } catch {
        print("[\(name)] trashItem failed: \(describe(error))"); return
    }
    guard let inTrash = result as URL? else { print("[\(name)] trashItem: resultingItemURL nil"); return }
    print("[\(name)] trashItem → \(inTrash.path)")
    print("[\(name)] exists in Trash (fileExists): \(fm.fileExists(atPath: inTrash.path))")
    var info = stat()
    print("[\(name)] lstat in Trash: \(lstat(inTrash.path, &info) == 0 ? "ok" : String(cString: strerror(errno)))")
    print("[\(name)] list Trash: \((try? fm.contentsOfDirectory(atPath: inTrash.deletingLastPathComponent().path).count).map(String.init) ?? "denied")")
    do {
        try fm.moveItem(at: inTrash, to: url)
        print("[\(name)] moveItem out of Trash: OK, back at \(fm.fileExists(atPath: url.path))")
    } catch {
        print("[\(name)] moveItem out of Trash failed: \(describe(error))")
        if rename(inTrash.path, url.path) == 0 {
            print("[\(name)] rename(2) out of Trash: OK")
        } else {
            print("[\(name)] rename(2) out of Trash: \(String(cString: strerror(errno)))")
        }
    }
    // Copy out (would be the fallback)
    if !fm.fileExists(atPath: url.path) {
        do {
            try fm.copyItem(at: inTrash, to: base.appendingPathComponent("copy-" + name))
            print("[\(name)] copy out of Trash: OK")
        } catch {
            print("[\(name)] copy out of Trash failed: \(describe(error))")
        }
    }
}

roundTrip("Folder A", folder: true)
roundTrip("file-a.txt", folder: false)

// NSWorkspace.recycle (goes through the Finder, may record Put Back)
let recycled = make("Folder B", folder: true)
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.recycle([recycled]) { urls, error in
    if let error { print("[Folder B] recycle failed: \(describe(error))") }
    print("[Folder B] recycle → \(urls[recycled]?.path ?? "nil")")
    if let inTrash = urls[recycled] {
        do {
            try fm.moveItem(at: inTrash, to: recycled)
            print("[Folder B] moveItem out of Trash: OK")
        } catch { print("[Folder B] moveItem out of Trash failed: \(describe(error))") }
    }
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

// One more of each left in the Trash, for the Put Back check from outside
_ = try? fm.trashItem(at: make("Stay Folder", folder: true), resultingItemURL: nil)
_ = try? fm.trashItem(at: make("stay-file.txt", folder: false), resultingItemURL: nil)
print("done")
