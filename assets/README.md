# cpuq artwork

| file | use |
|---|---|
| `cpuq-icon.svg` | app icon, 1024×1024 on the macOS icon grid (824 pt body) |
| `cpuq-mark.svg` | the mark alone, for light backgrounds |
| `cpuq-mark-dark.svg` | the mark alone, for dark backgrounds |
| `menubar/cpuqTemplate-N.svg` | menu-bar template images, 18×18 pt, N = 0…4 |

The mark is a chip with four cores inside: three held (green) and one free.

## Menu-bar meter

The menu-bar images are macOS template images: black and alpha only, so the
system tints them for light and dark menu bars. They are the app icon's chip
at 18 pt, with its four cores as a meter of the budget in use. Held cells are
solid and free cells are 30% alpha.
Choose N from `cpuq status --json`:

    N = 0                              when no cores are held
    N = min(4, ceil(4 × held / budget))  otherwise

So any work at all shows at least one cell, and N = 4 means the budget is
full.

## Exporting

On macOS, `sips` renders the SVGs and `iconutil` builds an `.icns`. Render at
the target size (set the root `<svg>`'s `width` and `height`) rather than
scaling a small PNG:

    sips -s format png cpuq-icon.svg --out cpuq-icon-1024.png

Template images go into an app as `cpuqTemplate-N.png` (18 px) and
`cpuqTemplate-N@2x.png` (36 px); the `Template` suffix tells AppKit to tint
them.
