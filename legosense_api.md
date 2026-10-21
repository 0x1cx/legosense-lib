# LegoSense UI — API

A Drawing-based UI library for Matcha (external Roblox LuaVM). Load it, call `CreateWindow`, then build tabs/sections/controls.

## Loading

The chunk returns the library and also exposes it at `_G.FALUI.Library`.

```lua
-- regular executors
local Library = loadstring(game:HttpGet(URL))()

-- Matcha: loadstring drops a chunk's return values, so read the global instead
loadstring(game:HttpGet(URL))()
local Library = _G.FALUI.Library
```

Nothing is shown and no files are touched until you call `CreateWindow`.

## Environments

- **Matcha** (`identifyexecutor() == "Matcha"`) is the only non-standard runtime; its quirks are handled internally.
- **Anything else** is treated as regular Roblox Luau. Missing executor globals are filled in: `isfile`/`readfile`/etc. become no-ops, `iskeypressed`/`ismouse1pressed`/`ismouse2pressed` fall back to `UserInputService`, HTTP falls back to `httpget`/`request`/`HttpService`.
- **Rendering depends only on `Drawing`.** With a Drawing library the UI renders (Matcha or any executor that has one). Drawing props that only Matcha supports (`Corner`, `Rounding`) are dropped silently on other executors. Without Drawing the library runs **headless**: flags, configs and callbacks work, nothing is drawn.
- Detection results: `_G.FALUI_ENV` → `{ matcha, executor, version, drawing, filesystem, input }`.

## CreateWindow

```lua
local Window = Library:CreateWindow({
    Title    = "nil",  -- brand text + root workspace folder name. nil -> "LegoSense"
    Subtitle = "nil",        -- under the brand. nil -> fetched game name
    Version  = "nil",           -- version tag in the sidebar. nil -> "v1.0"
    Icon     = nil,        -- logo: asset id (number) or image url (string). nil -> default logo
    FileSettings = {
        ConfigFolder = "nil" -- config subfolder. nil -> "configs"
    },
})
```

- All fields optional; `nil` keeps the default.
- Disk layout: `<Title>/<ConfigFolder>/name.json` for configs, plus `<Title>/settings.json`, `<Title>/autoload.txt`, `<Title>/icons48/…`. `Title` is sanitized to `[%w_%-]`.
- Returns the library (chainable). `CreateWindow` builds, loads persisted config, and shows the window.

## Tabs & Sections

```lua
local tab = Window:CreateTab("Aim", "crosshair")   -- name, lucide icon name
local sec = tab:CreateSection("Aimbot", "left")    -- title, side: "left" | "right"
```

- Tab icons are [lucide](https://lucide.dev) names (e.g. `"crosshair"`, `"eye"`, `"home"`).
- Settings is always present as the last tab (gear); new tabs slot in before it.
- `Window:CreateGroupbox` is an alias for `CreateSection`.
- Grab an existing tab by name/index: `Library:Tab("Settings")` or `Library:Tab(1)`.

## Controls

All take an options table and return a **row handle** (see below). `Text`/`Name` interchangeable. `Flag` makes the value persist in configs. `Tip` shows a hover tooltip.

```lua
sec:CreateToggle{  Text="Enabled", Default=false, Flag="aim_on", Callback=function(v) end }
sec:CreateSlider{  Text="FOV", Min=10, Max=400, Default=120, Suffix=" px", Flag="aim_fov", Callback=function(v) end }
sec:CreateDropdown{ Text="Mode", Options={"Head","Torso"}, Default="Head", Flag="aim_mode", Callback=function(v) end }
sec:CreateButton{  Text="Panic", Callback=function() end }
sec:CreateButtonRow{ { label="Save", cb=function() end }, { label="Load", cb=function() end } }
sec:CreateColor{   Text="ESP color", Default=Color3.fromRGB(255,0,0), Flag="esp_col", Callback=function(c) end } -- alias: CreateColorpicker
sec:CreateKeybind{ Text="Aim key", Default=0x02, Flag="aim_key", Callback=function(vk) end } -- vk = virtual-key code, -2 = MB2
sec:CreateTextbox{ Text="Webhook", Default="", Flag="hook", Callback=function(s) end }
sec:CreateDivider("Misc")
sec:CreateNote("Read-only line of text")   -- alias: CreateLabel
```

### Row handle

Every `Create*` control returns:

```lua
local row = sec:CreateToggle{ Text="X", Flag="x" }
row:Set(true)      -- set value (applies + fires Callback)
row:Get()          -- current value (bool / number / string / Color3 / vk)
row:SetTip("...")  -- set/replace tooltip
row:SetText("...") -- change the text of a note / divider / button (Set on those rows does the same)
row:SetOptions({ "A", "B" }) -- dropdowns: replace the options; keeps the value if still listed, else picks the first
```

## Flags & config

- Any control with a `Flag` is saved/restored by the config system and by autosave.
- Saved values apply when a flag is created, so the normal order (`CreateWindow`, then tabs/controls) restores everything; the control's `Callback` fires with the saved value.
- Autosave keeps saved values for flags the current script didn't create.
- Read/write by flag from anywhere:

```lua
Library:GetFlag("aim_fov")        -- -> 120
Library:SetFlag("aim_fov", 90)    -- applies + fires its Callback
Library.Flags                     -- raw table of flag -> row
```

- **Configs** (in the Settings › CONFIGS section): Save/Load/Delete named `.json` configs. Autosave writes to the selected Config → else the Auto-load config → else `settings.json`.
- **Auto-load** pointer lives in its own `autoload.txt`. `none` = load defaults on startup; a config name = load it.
- Config JSON stores every flag, the window geometry (`w/h/x/y`), and the full theme palette — so any theme (preset or custom) restores exactly.

## Theming

- Presets: `Waifu`, `Midnight`, `Ember` (default), `Mono`, `Rainbow`, `Custom`.
- `Rainbow` cycles the accent + sidebar/topbar over a Mono-white base; a **Rainbow speed** slider appears only while it's selected.

```lua
Library:SetPreset("Ember")
```

Fine-grained theme controls (Color 1/2, Background, Text color, Card glow, Corner radius, FX, fonts, etc.) live in the Settings tab.

**Performance mode** (Settings) turns off everything with a per-frame cost: easing animations, hover fades, snow, the Rainbow theme's colour cycling and nyan animation, and the scroll glow.

## Library methods

```lua
Library:CreateWindow(opts)   -- build + show (call once)
Library:CreateTab(name,icon) -- also on the Window handle
Library:Tab(ref)             -- existing tab by name or index
Library:SetPreset(name)
Library:GetFlag(flag) / :SetFlag(flag, v)
Library:Notify(title, message, duration) -- Matcha notify on Matcha, Roblox SendNotification elsewhere; duration defaults to the "Notify time" setting
Library:Show() / :Hide() / :Toggle()
Library:Unload()             -- disconnect, autosave, remove all Drawing objects
Library.Flags                -- flag -> row table
```

## Notes

- Menu toggle key is set in Settings (`Menu key`, default Home). It only works after `CreateWindow`.
- Built on the Drawing library (no Instance GUI in Matcha): custom hit-testing, scrolling with momentum, per-object edge clipping.
- Numeric `Icon` resolves via the Roblox thumbnails API; if that host is blocked it falls back to the default logo.
