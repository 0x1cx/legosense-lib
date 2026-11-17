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
    Icon     = nil,        -- logo: nil -> drawn "ls" mark, "game" -> this game's icon, asset id (number), image url (string),
                           -- or an embedded picture "data:image/png;base64,..." (nothing to host). Any aspect; fit into a 32 px slot
    Home     = { Discord = "discord.gg/x", NewsSource = "UI", Quick = { "flag", ... } },
    PreviewOnly = false, -- true disables anti-AFK, rejoin and server-hop behavior for UI previews
    Intro    = true,       -- false: skip the opening animation for this script
    FileSettings = {
        ConfigFolder = "nil" -- config subfolder. nil -> "configs"
    },
})
```

- All fields optional; `nil` keeps the default.
- Disk layout: `LegoSense/ui.json` holds the look and every Settings-page option, shared by every script (loading a config never changes the look). Each script keeps its own options in `<Title>/settings.json`, configs in `<Title>/<ConfigFolder>/name.json`, `<Title>/autoload.txt`. Image caches live in `LegoSense/_cache/`. `Title` is sanitized to `[%w_%-]`.
- Returns the library (chainable). `CreateWindow` builds, loads persisted config, and shows the window.

## Tabs & Sections

```lua
local tab = Window:CreateTab("Aim", "crosshair")   -- name, lucide icon name
local sec = tab:CreateSection("Aimbot", "left")    -- title, side: "left" | "right"
```

- Tab icons are [lucide](https://lucide.dev) names (e.g. `"crosshair"`, `"eye"`, `"home"`).
- Settings is always present as the last tab (gear); new tabs slot in before it.
- `Window:CreateGroupbox` is an alias for `CreateSection`.
- Table form: `tab:CreateSection({ Title = "Log", Side = "left", MaxHeight = 170 })`: the card stops growing at
  `MaxHeight` px and the rest scrolls inside it (mouse wheel or its thumb). Home's What's new uses this
  (`Home = { ChangelogHeight = n }`, default 170).
  All scrollable pages, capped/resized cards (including What's new), and dropdowns use one shared Drawing
  scrollbar implementation. They share the theme, thumb style, glow setting, scroll-speed setting, clipped
  hit area, and grab-point-preserving dragging. Cards and pages also share smooth scrolling; dropdowns
  keep whole-option steps. At a card's scroll boundary, further wheel movement scrolls the surrounding page.
- Grab an existing tab by name/index: `Library:Tab("Settings")` or `Library:Tab(1)`.

### Card layout editor

The pencil left of the search bar toggles edit mode. Cards keep the normal two-column layout: while editing, drag a card to any spot in either column (it floats under the mouse, the others make room, and it glides into place on release), and drag the grip on its bottom-right corner to make it taller or shorter. A card shorter than its content scrolls inside with the wheel. Everything animates (instant with Animations off). "Reset" puts the tab back to the script's own layout. Layouts are saved per tab with the UI state and matched by card title, so keep titles unique within a tab.

### Home tab

`CreateWindow` adds a Home tab first in the sidebar (turn it off with `Home = false`): a greeting with your avatar and session time, **What's new** (`Changelog` lines), **Community** (a Discord card for `Discord`: banner, icon, online / member counts, Join server), **Favorites** (controls pinned from their right-click menu, or the flags in `Quick`) and **Status** (FPS, ping, players, session; a Server sub-tab).

**Compact news log:** `Home.Changelog` accepts release groups such as `{ Date = "2026-11-16", Changes = { "Your change", "Another change" } }`, or `{ "date", { "change" } }`. Existing flat date/bullet/blank-line lists remain supported; wrapped continuation lines are joined before laying them out. Release dates, a Latest badge, compact bullet spacing and subtle release separators are rendered by the shared Drawing engine. `Section:CreateChangelog(entries)` uses the same component and returns the section. Long lines rewrap to the card width. Full original dates remain available as hover tips.

There are two news choices, configured by the owner in code:

```lua
Home = { NewsSource = "UI" } -- default: only the library's UI release notes
Home = { NewsSource = "Script", Changelog = {
    { Date = "2026-11-16", Changes = { "Your own release note" } },
} } -- complete replacement; UI notes are never merged into this log
```

For compatibility, supplying `Changelog` without `NewsSource` selects the script log. An empty script log stays empty. Without an override, the UI-owned `S.UI_NEWS` list is used. Live previews use real UI release notes, not invented script releases or wrapping test fixtures.

**UI-only preview:** use `CreateWindow{ PreviewOnly = true, Folder = "SterlingUiPreview", ... }` and supply presentation-only callbacks. The library disables its anti-AFK action, rejoin and server-hop routines in this mode. The local `_vbl_ui_test.lua` preview fetches the latest library from GitHub main with a cache-busting URL on each run; it never loads the actual VBL script. Its controls update preview UI state only. For local development, set `getgenv().LS_UI_PREVIEW_LOCAL_FILE = "ls_dev.lua"` explicitly; clear it to return to GitHub main.

### Page sub-tabs

```lua
local st = tab:CreateSubTabs({ "Aim", "Visuals" })   -- or { Title = "COMBAT", Names = { ... } }
local sec = st.Aim:CreateSection("Aimbot", "left")
tab:SelectSubTab("Visuals")
```

A strip under the top bar switches between groups of cards on one tab.

### Sub-tabs inside a card

```lua
local st = sec:CreateSubTabs({ "Aimbot", "Prediction", "FOV" })
st.Aimbot:CreateToggle{ Text="Enabled", Flag="aim_on" }   -- each handle has every Create* method
st.FOV:CreateSlider{ Text="Radius", Min=2, Max=300, Flag="aim_fov" }
```

- Adds a tab strip to the card; only the selected sub-tab's rows show (the card resizes smoothly).
- Controls made on `sec` itself stay visible on every sub-tab.
- The selected sub-tab is saved with the UI state; search results switch to the right sub-tab.

### Card extras

```lua
sec:SetVisible(false)                                -- hide / show the whole card
sec:CreateDiscord("discord.gg/x")                    -- Discord card (cached; counts refresh every 5 min)
local t = sec:CreateTiles{ Columns = 2, Tiles = {
    { Title = "FPS", Sub = "60", Live = true },       -- Live: value updates without a flash
    { Title = "Rejoin", Sub = "", Callback = function() end }, -- clickable tile
} }
t:SetTile(1, nil, "144")                             -- (index, title, sub, on)
local h = sec:CreateHero{ Title = "Hello", Sub = "subtitle" }  -- h:Set(title, sub)
```

## Controls

All take an options table and return a **row handle** (see below). `Text`/`Name` interchangeable. `Flag` makes the value persist in configs. `Tip` shows a hover tooltip.

```lua
sec:CreateToggle{  Text="Enabled", Default=false, Flag="aim_on", Callback=function(v) end }
sec:CreateSlider{  Text="FOV", Min=10, Max=400, Default=120, Suffix=" px", Flag="aim_fov", Callback=function(v) end }
sec:CreateDropdown{ Text="Mode", Options={"Head","Torso"}, Default="Head", Flag="aim_mode", Callback=function(v) end }
sec:CreateDropdown{ Text="Show", Options={"A","B","C"}, Multi=true, Default={"A"}, Flag="show", Callback=function(picked) end } -- multi-select: value is an array of picked options; the popout stays open while picking
sec:CreateButton{  Text="Panic", Callback=function() end }
sec:CreateButtonRow{ { label="Save", cb=function() end }, { label="Load", cb=function() end } }
sec:CreateColor{   Text="ESP color", Default=Color3.fromRGB(255,0,0), Flag="esp_col", Callback=function(c) end } -- alias: CreateColorpicker
sec:CreateKeybind{ Text="Aim key", Default=0x02, Flag="aim_key", Callback=function(vk) end } -- vk = virtual-key code, -2 = MB2
sec:CreateTextbox{ Text="Webhook", Default="", Flag="hook", Callback=function(s) end }
sec:CreateDivider("Misc")
sec:CreateNote("Read-only line of text")   -- alias: CreateLabel
```

### More controls

```lua
sec:CreateSlider{ Text="Smooth", Min=0, Max=1, Increment=0.05, Default=0.5, Flag="smooth" } -- Increment sets the snap and the shown decimals
sec:CreateKeybind{ Text="Aim key", Default=0x46, Mode="Toggle", Toggle=aimToggle, OnKey=function(on) end } -- Mode: "Toggle" | "Hold" | "Always"; Toggle = a toggle handle it drives
sec:CreateTextbox{ Text="Amount", Numeric=true, Finished=true, Callback=function(s) end } -- digits only; Callback on Enter / click-away
sec:CreateDropdown{ Text="Target", SpecialType="Player", ExcludeLocal=true } -- live player list
sec:CreateProgress{ Text="Loading", Value=0.4 }        -- handle:Set(0..1)
sec:CreateParagraph{ Title="Info", Content="Longer wrapped text" } -- returns { Title, Content, Set(title, content) }
sec:CreateImage{ Image="https://..." or 123456, Height=120 }
sec:CreateColor{ Text="Fill", Default=Color3.new(0,0.6,1), Alpha=0.5, Flag="fill", Callback=function(c, alpha) end } -- adds an alpha bar; Get() returns color, alpha; saved in configs
```

Dropdowns: type while one is open to filter it; Enter picks the top match.

### Spotlight (Ctrl+Space)

Ctrl+Space opens a centred search bar over the game, menu open or closed. Type to find any control in any tab; Up/Down selects. Enter (or a click) opens the menu on that control and pulses it so you see where it is; Shift+Enter (or Shift+click) runs it in place without opening the menu (toggles flip with a toast, buttons fire, other controls open the menu). Esc or a click outside closes. Clicks and keybinds don't reach the menu or the game while it's open.

Every control also takes:
- `DependsOn = "flag"` (shown while that flag is truthy) or `{ "flag", value }` (shown while it equals value)
- `Disabled = true` (greyed, ignores clicks), `Visible = false`

Starlight/Rayfield-style names work too: `Name`, `CurrentValue`, `CurrentOption`, `Range = {min, max}`, `Increment`, and the flag as a 2nd argument: `sec:CreateToggle({ Name = "Fly", CurrentValue = false }, "fly")`. Aliases: `CreateColorPicker`, `CreateBind`, `CreateInput`.

### Notifications and dialogs

```lua
Library:Notify("Title", "Message", 5)                 -- or Notify{ Title=, Content=, Duration= }; themed toast, click to dismiss
Library:Dialog{ Title="Delete config?", Content="This can't be undone.",
    Buttons = { { Text="Delete", Callback=function() end }, { Text="Cancel" } } } -- modal; blocks clicks behind it
Library:Dialog{ Icon="alert-triangle", Title="Use at your own risk", Buttons={ { Text="OK" } } }
    -- Icon = lucide name, drawn 28 px above the title; title, text and buttons centre. IconColor = Color3 (default amber)
MyTab:OnOpen(function() end) -- runs each time the tab is opened (and right away if it already is)
```

### UI scale

Settings › Interface › **UI scale** (75-160 %, default 115 %) scales the whole UI. Layout code works in logical px; the Drawing layer multiplies on write and divides mouse/viewport on read.

### Row handle

Every `Create*` control returns:

```lua
local row = sec:CreateToggle{ Text="X", Flag="x" }
row:Set(true)      -- set value (applies + fires Callback)
row:Get()          -- current value (bool / number / string / Color3 / vk)
row:SetTip("...")  -- set/replace tooltip
row:SetText("...") -- change the text of a note / divider / button (Set on those rows does the same)
row:SetOptions({ "A", "B" }) -- dropdowns: replace the options; keeps the value if still listed, else picks the first
row:SetVisible(false)  -- hide / show (card resizes smoothly)
row:SetDisabled(true)  -- grey out + ignore clicks
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

- Presets: `Mono` (default), `Matcha`, `Midnight`, `Ember`, `Blossom` (pink), `Rose` (deeper pink / plum), `Violet`, `Gold`, `Crimson`, `Aqua`, `Rainbow`, `Custom`. Blossom and Rose also set the text colours; the others use the default text colours.
- If a saved preset was removed, its saved colours load as `Custom`; without a saved palette it falls back to `Mono`.
- `Rainbow` cycles the accent + sidebar/topbar over a Mono-white base; a **Rainbow speed** slider appears only while it's selected.

```lua
Library:SetPreset("Mono")
```

Fine-grained theme controls (Color 1/2, Background, Text color, Corner radius, FX, fonts, etc.) live in the Settings tab.

**Performance mode** (Settings) turns off everything with a per-frame cost: easing animations, hover fades, snow, the Rainbow theme's colour cycling and nyan animation, and the scroll glow.

Under **Settings > Theme > Style**, **Image URL** accepts a direct hosted PNG, JPG, GIF, BMP or WebP image link. Press Enter to apply it. It follows the Theme image toggle and opacity setting, preserves the image's aspect ratio, and is saved with your UI settings and shared theme code. Clear it to restore the preset's image. Theme image blur applies to PNG images.

The **Glows** switch controls control glows, scrollbars, panel halos, notifications and intro effects. Individual glow settings are preserved while the master is off.

## Library methods

```lua
Library:CreateWindow(opts)   -- build + show (call once)
Library:CreateTab(name,icon) -- also on the Window handle
Library:Tab(ref)             -- existing tab by name or index
Library:SetPreset(name)
Library:GetFlag(flag) / :SetFlag(flag, v)
Library:Notify(title, message, duration) -- Matcha notify on Matcha, Roblox SendNotification elsewhere; duration defaults to the "Notify time" setting
Library:Show() / :Hide() / :Toggle()
Library:IsVisible() -- true while the menu is open
Library:PlayIntro() -- replay the opening animation (menu hides, intro plays, menu returns); no-op on Matcha or while one is playing
Library:Unload()             -- disconnect, autosave, remove all Drawing objects
Library:OnUnload(fn) -- fn runs once when the UI unloads by any route (Unload UI button, X, Library:Unload, a re-load); stop your loops/ESP here. Call it as often as you like: every fn runs
Library:CreateOverlay(opts) -- draggable always-on-top panel (see Overlays below)
Library.Flags                -- flag -> row table
```

## Overlays

Small always-on-top panels that stay up with the menu closed (keybinds, staff lists, timers, ...). Drag one by its title while the menu is open; its position is saved with the settings.

```lua
local ov = Library:CreateOverlay{ Id = "staff", Title = "Staff Online", EmptyText = "No staff detected", Visible = true, MinWidth = 160 }
ov:SetRows({
    { "SomeMod", "Game Moderator  42m", Color3.fromRGB(255, 90, 90) }, -- left, right, leftColor?, rightColor?
    { Left = "Other", Right = "far" }, -- named form works too
})
ov:SetTitle("Staff (2)")
ov:SetVisible(false)
ov:IsVisible()
```

Only text that changed is rewritten, so calling `SetRows` every tick is fine. Give a row `Key = "..."` when its left text changes every update (a counter, fps): rows animate in when their key is new, and the key defaults to the left text. `Id` keys the saved position; give each overlay its own.

The built-in **Keybind overlay** (UI Settings, Interface) lists every keybind control with its key and lights a row up while its key is held.

## UI performance diagnostics

Diagnostics belong to LegoSense and its UI owner. Consumers do not configure a destination: the old `CreateWindow.Telemetry` option is ignored. The webhook belongs in a separate, privately deployed Luarmor UI-owner sender, never in public UI source or a consumer script.

The private sender registers `getgenv().__LEGOSENSE_UI_TELEMETRY_SEND = function(reportJson) ... return trueOrFalse end`. It can be run by the UI owner's private bootstrap, or the UI owner can set the non-secret public Luarmor loader URL in `S.UI_TELEMETRY.LoaderUrl`. After executor detection and restoration of the saved sharing preference, the library starts loading the sender in the background. The UI opens normally while it waits for either a returned sender function or explicit registration. `LoadTimeout` defaults to 10 seconds (bounded to 0.1–30 seconds). A pending report waits for readiness within that load attempt's deadline; a failed or timed-out attempt does not repeatedly reload on every report. Switching sharing off cancels pending work; switching it on can start a fresh attempt. The UI source is configured with the owner-supplied public Luarmor loader URL. Protected loading and real webhook delivery have not been exercised by the local wiring checks. Private helper source is kept outside this public repository. Luarmor keeps the webhook out of GitHub, but a client-sent destination can still be recovered at runtime; use a server relay if the webhook must remain a server-side secret.

Outside Matcha, the collector records frame intervals by phase (load, intro, settle, open, closed, Spotlight), sample count, average/worst milliseconds, frames above 8.33/16.7ms, timing buckets, startup marks, executor/version, graphics-quality setting, screen size, UI scale, total Roblox memory, render CPU/GPU timings, Drawing count and UI-effect settings. Reports contain a random persistent installation ID, uptime, a summary (average FPS, average/worst frame time, share of frames over 16.7ms, average while the menu is open), the Roblox username, display name, user ID and account age, and the place ID, universe ID, server job ID and script title. They do not include HWID, IP, Discord ID or gameplay state. Frame intervals and renderer timings describe the whole client; they do not isolate the UI's execution cost.

The global Settings › Interface › **Share performance data** switch controls outbound reports to the UI owner. The scheduled report runs after about 60 seconds; up to three attempts are allowed per library instance. Concurrent reports share one pending delivery. Consent and the attempt cap are checked again immediately before calling the sender. Unload cancels pending loading/report work and can dispatch a final snapshot only through an already-ready sender, in a separate task so cleanup does not wait for HTTP. A request already started cannot be recalled. Local diagnostics are still written to `LegoSense/perf.json` when sharing is off. `LegoSense/perf_id.txt` stores the installation ID, and `Library:PerfReport()` returns a diagnostic table. Automatic collection is disabled on Matcha. The private sender's boolean result is tracked as a delivery count; delivery retries and true UI-only cost profiling are not implemented. The private template sends full JSON as an attachment rather than truncating it into a message.

## Notes

- Menu toggle key is set in Settings (`Menu key`, default Home). It only works after `CreateWindow`.
- Background blur (Settings › Effects › BLUR): per-place switches, strength, and **Window blur area**: `Window` (glass behind the menu) or `Full screen` (grows from the menu over the whole game, like Spotlight). Overlays keep their own blur.
- Anti-AFK is built in (Settings › Interface › MENU, on by default, saved in `ui.json` for every script): no idle kick after 20 min.
- Built on the Drawing library (no Instance GUI in Matcha): custom hit-testing, scrolling with momentum, per-object edge clipping.
  Layout and control writes are buffered until clipping is complete, then committed with visibility last.
  Scrollbar widths snap to physical pixels so fractional UI scaling does not thicken individual bars.

Hidden text-measurement probes bypass the visual write buffer so tooltip wrapping and alignment use the current label. Long tokens wrap, and tooltip panels stay within viewport bounds.

Only `legosense_ui_src.lua` and this README are published. The separate API document was identical and has been consolidated here. Developer tools, regression tests, UI-only examples and ignore rules remain local.
- Numeric `Icon` resolves via the Roblox thumbnails API; if that host is blocked it falls back to the default logo.
