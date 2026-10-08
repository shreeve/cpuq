import AppKit
import SwiftUI

/// A color theme for the graphs window: the projects' colors, the rose of needless waiting, and
/// the window's neutrals, each in a light and a dark mode. The window follows macOS between them
/// (Automatic), or keeps to one (Light, Dark).
struct Theme {
    struct Tones {
        /// The first six projects' colors, in the stacking order.
        var palette: [UInt32]
        var rose: UInt32
        var window: UInt32
        var card: UInt32
        var ink: UInt32
        var ink2: UInt32
        var ink3: UInt32
        var out: UInt32
    }

    let id: String
    let name: String
    let light: Tones
    let dark: Tones

    static let all: [Theme] = [
        Theme(id: "alive", name: "Alive",
              light: Tones(palette: [0x2f7cf6, 0x2fb457, 0x9b5de5, 0xf08a00, 0x14a9b8, 0xffcc00], rose: 0xee2f57,
                           window: 0xf4f4f6, card: 0xffffff, ink: 0x1d1d1f, ink2: 0x6e6e73, ink3: 0xa3a3a8, out: 0xa2a2a8),
              dark: Tones(palette: [0x3d86f5, 0x2db052, 0xa070ee, 0xcc7404, 0x16a0af, 0xffd60a], rose: 0xff4469,
                          window: 0x1b1b1d, card: 0x232326, ink: 0xf5f5f7, ink2: 0xa1a1a6, ink3: 0x66666b, out: 0x6c6c72)),
        Theme(id: "ocean", name: "Ocean",
              light: Tones(palette: [0x1e5eff, 0x13bdf0, 0x6a7dff, 0x0b97a6, 0x2fd6bb, 0x8fd8ff], rose: 0xff4f7b,
                           window: 0xeef4f9, card: 0xffffff, ink: 0x0f2537, ink2: 0x4e6578, ink3: 0x98a9b8, out: 0xa3b0bc),
              dark: Tones(palette: [0x4a7dff, 0x2fd0ff, 0x8a98ff, 0x14b5c4, 0x4ae8cd, 0xa8e2ff], rose: 0xff6b8f,
                          window: 0x0c1620, card: 0x13212e, ink: 0xe6f1fa, ink2: 0x93a8ba, ink3: 0x56697a, out: 0x5a6b7b)),
        Theme(id: "forest", name: "Forest",
              light: Tones(palette: [0x1f7a3a, 0x3fbf4f, 0x8cbf2f, 0xc0843a, 0x2e9c86, 0xe8bb18], rose: 0xe0445e,
                           window: 0xf1f4ee, card: 0xffffff, ink: 0x1c2a1e, ink2: 0x5c6b5d, ink3: 0xa0ab9f, out: 0xa8b0a6),
              dark: Tones(palette: [0x2e9a4e, 0x52d662, 0xa3d942, 0xd99b4f, 0x3cbfa6, 0xf5cc33], rose: 0xff5c74,
                          window: 0x111813, card: 0x18221b, ink: 0xe8f0e6, ink2: 0x98a899, ink3: 0x5c6b5e, out: 0x5e6b60)),
        Theme(id: "sunset", name: "Sunset",
              light: Tones(palette: [0xff6b1a, 0xff3d5e, 0xd63fae, 0x9b4dff, 0xffa91f, 0xffd84a], rose: 0xb0002f,
                           window: 0xfbf3ee, card: 0xffffff, ink: 0x2d1b16, ink2: 0x7a6259, ink3: 0xb3a097, out: 0xb5a7a0),
              dark: Tones(palette: [0xff7d33, 0xff5470, 0xe85ac4, 0xae6bff, 0xffb83d, 0xffe066], rose: 0xff2e55,
                          window: 0x1a1213, card: 0x241a1c, ink: 0xf8ece6, ink2: 0xb09c96, ink3: 0x6e5c58, out: 0x6e5f5b)),
        Theme(id: "nordic", name: "Nordic",
              light: Tones(palette: [0x2e4a85, 0x5ba8c4, 0x6f7fd0, 0x8aa2c8, 0x4c6a9c, 0xb48ead], rose: 0xbf616a,
                           window: 0xeceff4, card: 0xffffff, ink: 0x2e3440, ink2: 0x5f6b80, ink3: 0xa0a9b8, out: 0xa7afbd),
              dark: Tones(palette: [0x5e81ac, 0x88c0d0, 0x8f9bec, 0xb5c7e0, 0x81a1c1, 0xc39fbc], rose: 0xd27a83,
                          window: 0x2e3440, card: 0x3b4252, ink: 0xeceff4, ink2: 0xa3abbd, ink3: 0x6b7489, out: 0x6b7489)),
        Theme(id: "pastel", name: "Pastel",
              light: Tones(palette: [0x86b2ff, 0x8edcaa, 0xc4a3ff, 0xffa98a, 0x86dbe6, 0xffdc7a], rose: 0xf2668b,
                           window: 0xf7f5fb, card: 0xffffff, ink: 0x2b2838, ink2: 0x6f6a80, ink3: 0xaaa5b8, out: 0xbdb8c8),
              dark: Tones(palette: [0x9cc0ff, 0x9fe8b8, 0xd2b6ff, 0xffbba1, 0x9de8f0, 0xffe594], rose: 0xff86a3,
                          window: 0x1d1b24, card: 0x26232f, ink: 0xf3f0fa, ink2: 0xa9a3b8, ink3: 0x6b6578, out: 0x6b6578)),
        Theme(id: "neon", name: "Neon Slate",
              light: Tones(palette: [0x7b2bff, 0x1f6bff, 0x00c8e6, 0xff2bc8, 0x1fd65a, 0xc2e600], rose: 0xff1f5a,
                           window: 0xf1f3f7, card: 0xffffff, ink: 0x141821, ink2: 0x5a6273, ink3: 0x9aa1af, out: 0xa3a9b5),
              dark: Tones(palette: [0x9a5cff, 0x3d82ff, 0x00e5ff, 0xff4fdc, 0x39ff7a, 0xd8ff1f], rose: 0xff3d73,
                          window: 0x0d1016, card: 0x161a22, ink: 0xeef1f7, ink2: 0x98a0b0, ink3: 0x5a6273, out: 0x5a6273)),
    ]

    /// The theme in use; read when a color is drawn, so it must be quick.
    private(set) static var current = load()

    private static func load() -> Theme {
        let id = UserDefaults.standard.string(forKey: "theme") ?? "alive"
        return all.first { $0.id == id } ?? all[0]
    }

    /// Makes `id` the theme in use, for every color drawn from now on.
    static func use(_ id: String) {
        UserDefaults.standard.set(id, forKey: "theme")
        current = load()
    }

    /// Automatic (follow macOS), light or dark: the graphs window's appearance.
    static var appearanceName: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "appearance") }
    }

    static var appearance: NSAppearance? {
        switch appearanceName {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// A row of the theme's first five colors, for its menu item.
    func swatch(dark: Bool) -> NSImage {
        let tones = dark ? self.dark : light
        let d = 10.0, gap = 3.0
        return NSImage(size: NSSize(width: 5 * d + 4 * gap, height: d), flipped: false) { _ in
            for (i, v) in tones.palette.prefix(5).enumerated() {
                Theme.nsColor(v).setFill()
                NSBezierPath(ovalIn: NSRect(x: Double(i) * (d + gap), y: 0, width: d, height: d)).fill()
            }
            return true
        }
    }

    static func nsColor(_ v: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255, alpha: alpha)
    }
}
