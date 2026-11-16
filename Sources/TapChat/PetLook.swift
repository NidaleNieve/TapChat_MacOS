import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Custom pets: a JSON file that sets the pet's look (colors, body, what's on
// its head, eyes), its lines for any moment, and how lively it is. Made by
// hand or by an AI from the prompt Settings copies ("Copy Prompt"), checked
// with `TapChat --check-pet <file>`, and imported in Settings. Kept in
// Application Support/TapChat/Pets; the one in use is Settings' "petLook".

// The file as written: everything optional, defaults filled in by PetLook.
struct PetFile: Codable {
    var format: Int?
    var name: String?
    var author: String?
    var colors: [String: String]?
    var body: BodyFile?
    var top: String?
    var eyes: String?
    var cheeks: Bool?
    var activity: Double?
    var lines: [String: [String]]?

    struct BodyFile: Codable {
        var width: Double?
        var height: Double?
        var belly: Bool?
        var shine: Bool?
    }
}

struct PetLook: Equatable {
    var name = "Sprout"
    var author: String?
    var colors: [String: String] = PetLook.defaultColors
    var width: CGFloat = 1, height: CGFloat = 1
    var belly = true, shine = true
    var top = "sprout"
    var eyes = "round"
    var cheeks = true
    var activity: Double = 1
    var lines: [String: [String]] = [:]

    static let `default` = PetLook()

    static let defaultColors: [String: String] = [
        "bodyTop": "#FFDBDE", "bodyBottom": "#FCA3B8", "outline": "#DB6B87", "limbs": "#FA9EB3", "feet": "#ED8099",
        "belly": "#FFF2ED", "cheeks": "#FF6B8C", "eyes": "#382433", "mouth": "#9E2945", "tongue": "#FF8C9E",
        "top": "#73CC7A", "topAccent": "#5CAD66",
    ]
    static let colorNotes: [(String, String)] = [
        ("bodyTop", "the body's color at the top (it fades to bodyBottom)"),
        ("bodyBottom", "the body's color at the bottom"),
        ("outline", "the thin line around the body"),
        ("limbs", "the arms"),
        ("feet", "the feet (and the arms' tips)"),
        ("belly", "the belly patch"),
        ("cheeks", "the blush on its cheeks"),
        ("eyes", "the eyes, brows and closed-mouth line: keep it dark against the body"),
        ("mouth", "inside the open mouth"),
        ("tongue", "the tongue"),
        ("top", "what's on its head (see top), main color"),
        ("topAccent", "what's on its head, second color (stems, inner ears, details)"),
    ]
    static let tops: [(String, String)] = [
        ("sprout", "a little two-leaf sprout (the default)"),
        ("catEars", "pointy cat ears"),
        ("bunnyEars", "long bunny ears"),
        ("bearEars", "round bear ears"),
        ("antenna", "an antenna with a glowing ball"),
        ("horns", "two small horns"),
        ("bow", "a bow"),
        ("crown", "a little crown"),
        ("flower", "a flower"),
        ("none", "nothing"),
    ]
    static let eyeStyles: [(String, String)] = [("round", "the default"), ("big", "bigger, cuter"), ("small", "small dots")]

    // Every moment it can say something, and what it's for. A file's lines
    // for a key replace the built-in ones; keys it leaves out keep them.
    static let lineKeys: [(String, String)] = [
        ("hello", "appearing (the pet was just turned on)"),
        ("open", "tapped, opening the chat"), ("close", "tapped, closing the chat"),
        ("new", "a new chat started"), ("reopen", "an older chat opened from History"),
        ("send", "the user sent a question"), ("done", "an answer finished"), ("error", "an answer failed"),
        ("stop", "the user stopped an answer"),
        ("temp", "a temporary (incognito) chat started: it puts on sunglasses"), ("untemp", "the temporary chat ended"),
        ("reshades", "sunglasses back on (the temporary chat shown again)"), ("offshades", "sunglasses off (the temporary chat hidden)"),
        ("side", "a side chat opened"), ("awe", "the user highlights text in the chat"),
        ("model", "the model changed; {model} is its name"), ("effortUp", "reasoning effort raised"), ("effortDown", "reasoning effort lowered"),
        ("history", "History opened"), ("settings", "Settings opened"),
        ("attachImage", "a picture attached"), ("attachFile", "a file attached"), ("attachFolder", "a folder attached"),
        ("pet", "being petted (cursor resting or rubbing on it)"),
        ("boop", "right-clicked"), ("boopRasp", "right-clicked: sticks its tongue out"), ("boopCross", "right-clicked: annoyed"),
        ("boopShy", "right-clicked: shy"), ("boopRoll", "right-clicked: rolls its eyes"),
        ("hold", "picked up (dragged)"), ("throw", "thrown"), ("drop", "put down somewhere"), ("dizzy", "dizzy after being shaken"),
        ("bye", "leaving (Hide for a While)"), ("bye2", "looking back while leaving"), ("back", "coming back after hiding"), ("off", "turned off from its menu"),
        ("wake", "woken up"), ("yawn", "yawning"), ("rub", "rubbing its eyes"),
        ("app", "the user switched to another app; {app} is its name"), ("time", "checking the time; {time} is the time"),
        ("hum", "humming"), ("ommm", "meditating"), ("butterfly", "a butterfly arrives"), ("bfly", "the butterfly leaves"),
        ("soap", "blowing a soap bubble"), ("pop", "the soap bubble popped"), ("presneeze", "about to sneeze"), ("sneeze", "sneezing"),
        ("bless", "after sneezing"), ("prop", "spinning its top like a propeller"), ("tap", "tapping its foot"), ("hic", "hiccups"),
        ("juggle", "juggling"), ("pushups", "doing push-ups"), ("brr", "shivering"), ("sprout", "patting what's on its head"),
        ("melt", "melting with happiness"), ("chase", "walking after the cursor"), ("trip", "tripping"), ("tripok", "getting up after tripping"),
    ]

    var palette: PetColors { PetColors(self) }

    // MARK: The one in use

    static let changed = Notification.Name("PetLookChanged")
    // Made only when a pet is imported: nothing on disk for anyone who never does.
    static var folder: URL { Paths.support.appendingPathComponent("Pets", isDirectory: true) }
    static var selected: String {
        get { UserDefaults.standard.string(forKey: "petLook") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "petLook")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static var current: PetLook {
        guard !selected.isEmpty, let data = try? Data(contentsOf: folder.appendingPathComponent(selected)),
              let look = check(data).look else { return .default }
        return look
    }

    // The imported pets: file name and the pet's name.
    static func library() -> [(id: String, name: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { f in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(f)), let look = check(data).look else { return nil }
            return (f, look.name)
        }
    }

    // Copies a checked file in; its id (the file name), or the problems.
    static func importFile(_ url: URL) -> Result<String, PetImportError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(PetImportError(problems: ["The file couldn't be read."])) }
        let result = check(data)
        guard let look = result.look else { return .failure(PetImportError(problems: result.problems)) }
        let base = look.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        var name = (base.isEmpty ? "pet" : base) + ".json", n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n).json"; n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name))
        } catch {
            return .failure(PetImportError(problems: ["It couldn't be saved: \(error.localizedDescription)"]))
        }
        return .success(name)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        if selected == id { selected = "" }
    }

    // MARK: Checking a file

    // The pet, or nil with what's wrong; warnings are things fixed for it.
    static func check(_ data: Data) -> (look: PetLook?, problems: [String], warnings: [String]) {
        let file: PetFile
        do { file = try JSONDecoder().decode(PetFile.self, from: data) } catch {
            return (nil, ["Not valid JSON for a pet: \(describe(error))"], [])
        }
        var problems: [String] = [], warnings: [String] = []
        var look = PetLook()
        if let v = file.format, v != 1 { warnings.append("\"format\" is \(v); this TapChat reads format 1.") }
        if let name = file.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if name.count > 30 { problems.append("\"name\" is longer than 30 characters.") }
            look.name = name
        } else { problems.append("\"name\" is missing: give the pet a name.") }
        look.author = file.author
        for (key, value) in file.colors ?? [:] {
            if defaultColors[key] == nil { warnings.append("Unknown color \"\(key)\" ignored (known: \(colorNotes.map(\.0).joined(separator: ", "))).") }
            else if Color(hex: value) == nil { problems.append("Color \"\(key)\": \"\(value)\" isn't a hex color like \"#FFAA00\".") }
            else { look.colors[key] = value }
        }
        if let b = file.body {
            for (label, value) in [("width", b.width), ("height", b.height)] {
                guard let value else { continue }
                if !(0.8...1.25).contains(value) { problems.append("\"body.\(label)\" is \(value); it must be between 0.8 and 1.25.") }
            }
            look.width = CGFloat(min(1.25, max(0.8, b.width ?? 1)))
            look.height = CGFloat(min(1.25, max(0.8, b.height ?? 1)))
            look.belly = b.belly ?? true
            look.shine = b.shine ?? true
        }
        if let top = file.top {
            if tops.contains(where: { $0.0 == top }) { look.top = top } else { problems.append("\"top\": \"\(top)\" isn't one of \(tops.map(\.0).joined(separator: ", ")).") }
        }
        if let eyes = file.eyes {
            if eyeStyles.contains(where: { $0.0 == eyes }) { look.eyes = eyes } else { problems.append("\"eyes\": \"\(eyes)\" isn't one of \(eyeStyles.map(\.0).joined(separator: ", ")).") }
        }
        look.cheeks = file.cheeks ?? true
        if let a = file.activity {
            if !(0.25...3).contains(a) { problems.append("\"activity\" is \(a); it must be between 0.25 (calm) and 3 (very lively).") }
            look.activity = min(3, max(0.25, a))
        }
        let keys = Set(lineKeys.map(\.0))
        for (key, list) in file.lines ?? [:] {
            guard keys.contains(key) else { warnings.append("Unknown line key \"\(key)\" ignored."); continue }
            let kept = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if kept.isEmpty { warnings.append("Lines for \"\(key)\" are empty, so the built-in ones stay."); continue }
            for line in kept where line.count > 60 { problems.append("A line for \"\(key)\" is over 60 characters: \"\(line.prefix(40))…\"") }
            look.lines[key] = kept
        }
        return problems.isEmpty ? (look, [], warnings) : (nil, problems, warnings)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(let type, let c): return "\(path(c)) should be \(type)."
        case .valueNotFound(_, let c): return "\(path(c)) has no value."
        case .keyNotFound(let key, _): return "\"\(key.stringValue)\" is missing."
        case .dataCorrupted(let c): return c.debugDescription
        default: return error.localizedDescription
        }
    }
    private static func path(_ c: DecodingError.Context) -> String {
        let p = c.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "The file" : "\"\(p)\""
    }

    // MARK: The prompt for an AI

    static var prompt: String {
        let exe = Bundle.main.executablePath ?? "/Applications/TapChat.app/Contents/MacOS/TapChat"
        let example = """
            {
              "format": 1,
              "name": "Mochi",
              "author": "you",
              "colors": {
                "bodyTop": "#E8F4FF", "bodyBottom": "#A9D2FF", "outline": "#5E8FC9",
                "limbs": "#9CC8F7", "feet": "#7FB0EA", "belly": "#F7FBFF", "cheeks": "#FF8FB1",
                "eyes": "#22304A", "mouth": "#8A2C4A", "tongue": "#FF9DB0",
                "top": "#FFFFFF", "topAccent": "#FFC2D6"
              },
              "body": { "width": 1.05, "height": 0.95, "belly": true, "shine": true },
              "top": "bunnyEars",
              "eyes": "big",
              "cheeks": true,
              "activity": 0.8,
              "lines": {
                "hello": ["hi hi! it's Mochi 🐰", "boing! I'm here"],
                "done": ["all done! 🥕", "ta-da!"],
                "model": ["ooh, {model}!", "{model}? hop to it!"]
              }
            }
            """
        return """
            You're designing a custom pet for TapChat, a macOS chat app. The pet is a small cartoon creature that lives on the screen: it reacts to the chat (questions, answers, new chats), to being petted, dragged or right-clicked, and keeps itself busy with little tricks. Its drawing and animations are built into the app; you describe its look, its personality (its lines) and how lively it is, in one JSON file.

            THE PET I WANT
            [Describe your pet here: what it is, its colors, what's on its head, its personality and the way it talks.]

            WHAT TO MAKE
            One JSON file (UTF-8, ending in .json), with these fields. Everything but "name" is optional; anything left out keeps the default.

            - "format": 1
            - "name": the pet's name (at most 30 characters). Required.
            - "author": who made it (optional).
            - "colors": hex colors ("#RRGGBB"). The body is a soft rounded gumdrop with little arms and feet, drawn with gradients.
            \(colorNotes.map { "    - \"\($0.0)\": \($0.1) (default \(defaultColors[$0.0]!))" }.joined(separator: "\n"))
            - "body": { "width": 0.8 to 1.25 (1 = normal), "height": 0.8 to 1.25, "belly": true/false (a lighter belly patch), "shine": true/false (a glossy highlight) }
            - "top": what's on its head, one of:
            \(tops.map { "    - \"\($0.0)\": \($0.1)" }.joined(separator: "\n"))
            - "eyes": one of \(eyeStyles.map { "\"\($0.0)\" (\($0.1))" }.joined(separator: ", ")).
            - "cheeks": true/false (blush).
            - "activity": how often it does tricks on its own, 0.25 (calm) to 3 (very lively); 1 is the default (a trick every 14 to 34 seconds).
            - "lines": what it says, by moment. Each key has a list of short lines (at most 60 characters, ideally under 30; emoji welcome); one is picked at random, without repeats until all have been used. Give 3 to 8 lines for the moments that matter for its personality; keys left out keep the built-in lines. The keys:
            \(lineKeys.map { "    - \"\($0.0)\": \($0.1)" }.joined(separator: "\n"))

            An example (a pale blue bunny):
            \(example)

            DESIGN TIPS
            - Keep the eyes color dark and the body light (or the other way round) so the face reads at a small size.
            - bodyTop slightly lighter than bodyBottom gives the soft 3D look; outline a darker shade of the body.
            - limbs and feet a bit darker than the body; topAccent should contrast with top.
            - Lines should sound like one character: consistent voice, kind, playful, never rude to the user.

            HOW TO CHECK IT WORKS
            1. Make sure it's valid JSON (no comments, no trailing commas) and that every value is within the ranges above.
            2. If you can run commands on this Mac, save the file and run:
               "\(exe)" --check-pet "/path/to/pet.json"
               It prints OK with the pet's name, or every problem to fix (and warnings for anything ignored), and writes preview images of the pet in many poses (idle, happy, thinking, asleep, held, sunglasses, dizzy, and more) into a folder next to the file, named after it. Fix every problem and run it again until it prints OK, then look at the previews: the face should be clear, the colors should match the description, and what's on its head should look right in every pose.
            3. If you can't run commands, go through the file field by field against this list, and say that the user should run the check above.
            4. Then the user imports it: TapChat Settings → Other → Pet → Import…, and picks it under Look.

            Reply with the complete JSON file (in a code block), then one line on what you checked.
            """
    }
}

struct PetImportError: Error { let problems: [String] }

// The look's colors, ready to draw with.
struct PetColors {
    let top, bottom, edge, limb, foot, belly, cheek, ink, mouth, tongue, accessory, accent: Color

    init(_ look: PetLook) {
        func c(_ key: String) -> Color { Color(hex: look.colors[key] ?? "") ?? Color(hex: PetLook.defaultColors[key]!)! }
        top = c("bodyTop"); bottom = c("bodyBottom"); edge = c("outline"); limb = c("limbs"); foot = c("feet")
        belly = c("belly"); cheek = c("cheeks"); ink = c("eyes"); mouth = c("mouth"); tongue = c("tongue")
        accessory = c("top"); accent = c("topAccent")
    }
}

extension Color {
    // "#RRGGBB" or "#RGB" (the # optional); nil for anything else.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// `TapChat --check-pet <file> [<preview folder>]`: checks a pet file and
// renders it in many poses. Exit status 0 when it's fine.
enum PetCheck {
    @MainActor static func run(_ args: [String]) -> Int32 {
        guard let path = args.first else {
            print("Usage: TapChat --check-pet <pet.json> [<preview folder>]")
            return 2
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            print("ERROR: can't read \(url.path)")
            return 1
        }
        let result = PetLook.check(data)
        for w in result.warnings { print("WARNING: \(w)") }
        guard let look = result.look else {
            for p in result.problems { print("ERROR: \(p)") }
            print("Not OK: fix the errors above and check again.")
            return 1
        }
        let out = args.count > 1 ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            : url.deletingPathExtension().appendingPathExtension("preview")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names = PetRender.run(out.path, look: look)
        print("OK: \"\(look.name)\" is a valid pet (top: \(look.top), eyes: \(look.eyes), activity: \(look.activity), custom lines for \(look.lines.count) moments).")
        print("Previews (\(names.count)): \(out.path)/ — \(names.map { $0 + ".png" }.joined(separator: ", "))")
        return 0
    }
}
