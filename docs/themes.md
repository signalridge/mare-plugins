# Themes guide

`mare-plugins` ships 37 theme flavors under [themes/](../themes/) and 8 external `.tmTheme` syntax definitions under [themes/syntax/](../themes/syntax/).

## Loading themes

Themes are package assets, not plugins. Enabling any plugin from `signalridge/mare-plugins` makes all 37 flavors available. To load only the themes without activating any plugins, pass `only = {}`:

```lua
mare.setup {
  flavor = "catppuccin-mocha",
}

mare.plugins.add {
  { "signalridge/mare-plugins", only = {} },
}
```

## Light and dark pairing

Set `flavor = "auto"` with `flavor_dark` and `flavor_light` so Mare chooses based on your terminal background:

```lua
mare.setup {
  flavor = "auto",
  flavor_dark = "gruvbox-dark",
  flavor_light = "gruvbox-light",
}
```

Inside a running session, `/theme` opens an interactive picker with live preview, and `/theme <name>` switches directly.

## Aliases, roles, and contrast checks

- **Aliases**: `one-half-dark` resolves to `one-halfdark`, and `one-half-light` resolves to `one-halflight`.
- **Palette roles (all 37 flavors)**: each flavor defines 18 palette colors: 9 foreground roles (`text`, `muted`, `dim`, `accent`, `accent2`, `green`, `yellow`, `red`, `blue`) plus surface, border, diff, and contrast-companion roles (`subtle`, `border`, `selection`, `code_bg`, `add_bg`, `del_bg`, `add_word`, `del_word`, `on_color`).
- **Contrast checks (`tests/e2e-themes.py`)**: the 9 foreground roles (`text`, `muted`, `dim`, `accent`, `accent2`, `green`, `yellow`, `red`, `blue`) meet `>= 4.5:1` contrast against each flavor's reference background, and `text` over `selection` meets `>= 5:1`. Background, diff, and `on_color` roles (for example `gruvbox-dark`'s `on_color`, which matches its reference background) are outside that `4.5:1` reference-background check.
- **Palette flavors (24)** use these semantic roles for both UI and syntax styling.
- **Syntax flavors (13)** pair a semantic palette with an upstream `.tmTheme` XML scope document (either inline or via `themes/syntax/*.tmTheme`). See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for upstream sources, copyright holders, and license texts.

## Bundled flavors

### Dark flavors (25)

| Flavor | Syntax | Reference background |
| --- | --- | --- |
| `1337` | Embedded tmTheme | `#191919` |
| `catppuccin-frappe` | Palette | `#303446` |
| `catppuccin-macchiato` | Palette | `#24273a` |
| `catppuccin-mocha` | Palette | `#1e1e2e` |
| `coldark-dark` | `syntax/coldark-dark.tmTheme` | `#111b27` |
| `dracula` | Palette | `#282a36` |
| `everforest-dark` | Palette | `#2d353b` |
| `gruvbox-dark` | Palette | `#282828` |
| `kanagawa-dragon` | Palette | `#181616` |
| `kanagawa-wave` | Palette | `#1f1f28` |
| `kimi-dark` | Palette | `#000000` |
| `monokai-extended` | `syntax/monokai-extended.tmTheme` | `#222222` |
| `monokai-extended-bright` | `syntax/monokai-extended-bright.tmTheme` | `#272822` |
| `monokai-extended-origin` | `syntax/monokai-extended-origin.tmTheme` | `#272822` |
| `nord` | Palette | `#2e3440` |
| `one-dark` | Palette | `#282c34` |
| `one-halfdark` | Embedded tmTheme | `#282c34` |
| `rose-pine-main` | Palette | `#191724` |
| `rose-pine-moon` | Palette | `#232136` |
| `solarized-dark` | Palette | `#002b36` |
| `sublime-snazzy` | Embedded tmTheme | `#282a36` |
| `tokyonight-night` | Palette | `#1a1b26` |
| `tokyonight-storm` | Palette | `#24283b` |
| `two-dark` | `syntax/two-dark.tmTheme` | `#282c34` |
| `zenburn` | `syntax/zenburn.tmTheme` | `#393939` |

### Light flavors (12)

| Flavor | Syntax | Reference background |
| --- | --- | --- |
| `catppuccin-latte` | Palette | `#eff1f5` |
| `coldark-cold` | `syntax/coldark-cold.tmTheme` | `#e3eaf2` |
| `everforest-light` | Palette | `#fdf6e3` |
| `github` | Embedded tmTheme | `#ffffff` |
| `gruvbox-light` | Palette | `#fbf1c7` |
| `kanagawa-lotus` | Palette | `#f2ecbc` |
| `kimi-light` | Palette | `#ffffff` |
| `monokai-extended-light` | `syntax/monokai-extended-light.tmTheme` | `#fafafa` |
| `one-halflight` | Embedded tmTheme | `#fafafa` |
| `rose-pine-dawn` | Palette | `#faf4ed` |
| `solarized-light` | Palette | `#fdf6e3` |
| `tokyonight-day` | Palette | `#e1e2e7` |
