-- FALUI :: STEP 14 -- per-pixel scrollbar glow, wider sidebar, grip lines, darker bars
-- Run standalone in Matcha: loadstring(readfile(FOLDER .. "/step14.lua"))()
if _G.FALUI and _G.FALUI.Unload then pcall(_G.FALUI.Unload) end

local UI = { Objects = {}, Version = "step14", WheelConns = {} }
_G.FALUI = UI

-- disk layout: <FOLDER>/<CFGSUB>/name.json for configs, <FOLDER>/settings.json etc.
-- FOLDER derives from the window Title (CreateWindow), default "Legosense".
local FOLDER = "Legosense"
local CFGSUB = "configs"
local function cfgDir() return FOLDER .. "/" .. CFGSUB end

local function C3(r, g, b) return Color3.fromRGB(r, g, b) end
local BaseC1 = C3(229, 151, 95)
local BaseC2 = C3(240, 201, 121)
local Theme = {
    Dark = C3(18, 14, 11), Bg = C3(44, 38, 33), Panel = C3(52, 45, 38), PanelHov = C3(60, 52, 44),
    Control = C3(62, 54, 45), Track = C3(82, 72, 61), C1 = BaseC1, C2 = BaseC2,
    Header = C3(196, 152, 110), Text = C3(219, 225, 211), Dim = C3(130, 137, 118),
    Knob = C3(245, 248, 240), White = C3(255, 255, 255),
}
local ALPHA_BG = 0.52
local ALPHA_BAR = 0.52
local ALPHA_CARD = 0.6
local ALPHA_CTRL = 0.6
local WAIFU_RATIO = 0.5625

local FS = 13
local TB = 36
local MIN_W, MIN_H = 480, 320
local SB_MIN = 56
local ITEM_H = 38
local CHAR_W = 7
local CHAR_WB = 9 -- for the larger sidebar/topbar text
local PAD = 16
local GRAD_SEGS = 6
local SNOW_N = 35

local Cfg = {
    animations = true, hoverFx = true, opacity = 1.0,
    rainbow = false, rainbowSpeed = 100,
    checkbox = false, collapseSidebar = false, inlineDropdowns = false,
    tabLayout = "Sidebar", search = "Bar", font = "UI",
    notifyTime = 5, menuKey = 0x24, keybindOverlay = false,
    cardGlow = 60, bgFx = "Snow", border = 0, frost = 0, cornerRadius = 100,
    perfMode = false, smartFps = false, preset = "Ember",
    autoSave = true, autoLoad = "none", fxColor = BaseC1,
}
local FontIds = { UI = 0, System = 1, SystemBold = 2, Minecraft = 4, Monospace = 5, Pixel = 7 }

local Win = { x = 380, y = 140, w = 820, h = 620, visible = true, dirty = true }
local Sb  = { cur = SB_MIN, target = SB_MIN, max = 220 }
local hue = 0.28

-- no built-in feature tabs: everything except the always-present Settings page comes from
-- the public API (Library:CreateTab). Settings starts at index 1 and shifts up as tabs are added.
local Tabs = {}
local SETTINGS_TAB = 1
local activeTab = SETTINGS_TAB
local hiliteY = 0

local Bases = {}
local TextObjs = {}
local Shapes = {}

local FADE_N = 32

local function itemsTop()
    local expandT = (Sb.cur - SB_MIN) / math.max(1, Sb.max - SB_MIN)
    return Win.y + 50 + math.floor(6 * expandT + 0.5)
end

local function New(t, props)
    local ok, o = pcall(Drawing.new, t)
    if not ok then print("FALUI|create fail " .. t .. ": " .. tostring(o)) return nil end
    for k, v in pairs(props) do
        local okP, e = pcall(function() o[k] = v end)
        if not okP then print("FALUI|" .. t .. "." .. k .. " set fail: " .. tostring(e)) end
    end
    if t == "Text" and props.Outline == nil then
        pcall(function() o.Outline = false end)
    end
    Bases[o] = props.Transparency or 1
    Shapes[o] = t
    if t == "Text" then table.insert(TextObjs, o) end
    table.insert(UI.Objects, o)
    return o
end

local function NewFadeSegs(z, color)
    local segs = {}
    for i = 1, FADE_N do
        segs[i] = New("Square", { Filled = true, Color = color or Theme.C1, Transparency = 0, ZIndex = z or 33, Visible = false })
    end
    return segs
end

-- peak: "center" | "left" | "right"; alpha profile fades to 0 away from peak
local function layoutFade(segs, x1, x2, yy, peak, baseA, visible)
    local span = x2 - x1
    if span < 8 or not visible then
        for i = 1, FADE_N do segs[i].Visible = false end
        return
    end
    local segW = span / FADE_N
    for i = 1, FADE_N do
        local xA = math.floor(x1 + (i - 1) * segW + 0.5)
        local xB = math.floor(x1 + i * segW + 0.5)
        local o = segs[i]
        if xB - xA >= 1 then
            local t = (i - 0.5) / FADE_N
            local a
            if peak == "center" then
                a = math.sin(t * math.pi)
            elseif peak == "left" then
                a = 1 - t
            else
                a = t
            end
            a = a * a -- gamma: smoother perceptual dissolve
            o.Visible = true
            o.Position = Vector2.new(xA, yy)
            o.Size = Vector2.new(xB - xA, 1)
            o.Color = Theme.C1
            o.Transparency = baseA * a * Cfg.opacity
        else
            o.Visible = false
        end
    end
end

local function truncate(label, availPx)
    local maxChars = math.floor(availPx / CHAR_W)
    if maxChars <= 0 then return "" end
    if #label <= maxChars then return label end
    if maxChars <= 2 then return string.rep(".", math.max(0, maxChars)) end
    return label:sub(1, maxChars - 2) .. ".."
end

local function truncateB(label, availPx)
    local maxChars = math.floor(availPx / CHAR_WB)
    if maxChars <= 0 then return "" end
    if #label <= maxChars then return label end
    if maxChars <= 2 then return string.rep(".", math.max(0, maxChars)) end
    return label:sub(1, maxChars - 2) .. ".."
end

local function lerp(a, b, t) return a + (b - a) * t end
local function lerpColor(a, b, t)
    return C3(
        math.floor(lerp(a.R * 255, b.R * 255, t) + 0.5),
        math.floor(lerp(a.G * 255, b.G * 255, t) + 0.5),
        math.floor(lerp(a.B * 255, b.B * 255, t) + 0.5)
    )
end

local function hsv2rgb(h, s, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p, q, t2 = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    if i == 0 then r, g, b = v, t2, p elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t2 elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t2, p, v else r, g, b = v, p, q end
    return C3(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local function rgb2hsv(c)
    local r, g, b = c.R, c.G, c.B
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h / 6
    end
    local s = mx == 0 and 0 or d / mx
    return h, s, mx
end

local function hexOf(c)
    return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function inRect(px, py, rx, ry, rw, rh)
    return px >= rx and px <= rx + rw and py >= ry and py <= ry + rh
end

local function CR(px) return math.max(0, math.floor(px * Cfg.cornerRadius / 100 + 0.5)) end

local function setOpacity(f)
    Cfg.opacity = f
    for _, o in ipairs(UI.Objects) do
        local b = Bases[o]
        if b then pcall(function() o.Transparency = b * f end) end
    end
end

local function applyFont(name)
    local id = FontIds[name]
    if not id then return end
    Cfg.font = name
    for _, t in ipairs(TextObjs) do pcall(function() t.Font = id end) end
end

local KEYNAMES = { [0x08] = "Bksp", [0x09] = "Tab", [0x0D] = "Enter", [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt",
    [0x1B] = "Esc", [0x20] = "Space", [0x21] = "PgUp", [0x22] = "PgDn", [0x23] = "End", [0x24] = "Home",
    [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down", [0x2D] = "Ins", [0x2E] = "Del", [-2] = "MB2" }
for i = 0x30, 0x39 do KEYNAMES[i] = string.char(i) end
for i = 0x41, 0x5A do KEYNAMES[i] = string.char(i) end
for i = 0x70, 0x7B do KEYNAMES[i] = "F" .. (i - 0x6F) end
local function keyName(vk) return KEYNAMES[vk] or ("K" .. tostring(vk)) end

local ICON_URL = "https://raw.githubusercontent.com/latte-soft/lucide-roblox/master/icons/compiled/48px/"
local function loadIcon(name, applyFn)
    task.spawn(function()
        local path = FOLDER .. "/icons48/" .. name .. ".txt"
        local data = nil
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 100 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return game:HttpGet(ICON_URL .. name .. ".png") end)
            if ok and d and #d > 100 then
                data = d
                if not isfolder(FOLDER) then pcall(makefolder, FOLDER) end
                if not isfolder(FOLDER .. "/icons48") then pcall(makefolder, FOLDER .. "/icons48") end
                pcall(writefile, path, d)
            end
        end
        if data and applyFn then pcall(applyFn, data) end
    end)
end

local function loadAvatar(applyFn)
    task.spawn(function()
        local path = FOLDER .. "/avatar.txt"
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 100 then pcall(applyFn, d) return end
        end
        local okId, uid = pcall(function() return game:GetService("Players").LocalPlayer.UserId end)
        if not okId then return end
        local okJ, j = pcall(function()
            return game:HttpGet("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. tostring(uid) .. "&size=48x48&format=Png&isCircular=false")
        end)
        if not okJ or not j then return end
        local url = tostring(j):match('"imageUrl"%s*:%s*"([^"]+)"')
        if not url then return end
        local okP, png = pcall(function() return game:HttpGet(url) end)
        if okP and png and #png > 100 then
            pcall(writefile, path, png)
            pcall(applyFn, png)
        end
    end)
end

-- ========== shell ==========
local D = {}
D.main    = New("Square", { Filled = true, Color = Theme.Bg, Transparency = ALPHA_BG, ZIndex = 30, Corner = 8, Visible = true })
D.waifu   = New("Image",  { Transparency = 0.5, ZIndex = 29, Visible = true })
D.topbar  = New("Square", { Filled = true, Color = Theme.Dark, Transparency = ALPHA_BAR, ZIndex = 31, Corner = 8, Visible = true })
D.sidebar = New("Square", { Filled = true, Color = Theme.Dark, Transparency = ALPHA_BAR, ZIndex = 32, Corner = 8, Visible = true })
D.seam    = New("Square", { Filled = true, Color = Theme.Dark, Transparency = ALPHA_BAR, ZIndex = 33, Corner = 0, Visible = true })
D.logo    = New("Square", { Filled = true, Color = Theme.C1, Transparency = 1, ZIndex = 34, Corner = 6, Visible = true, Size = Vector2.new(32, 32) })
D.logoTxt = New("Text",   { Text = "LS", Color = Theme.Dark, Transparency = 1, ZIndex = 35, Font = 0, Size = 14, Visible = true })
D.logoTxt2= New("Text",   { Text = "LS", Color = Theme.Dark, Transparency = 1, ZIndex = 35, Font = 0, Size = 14, Visible = true })
D.logoImg = New("Image",  { Transparency = 1, ZIndex = 36, Visible = false, Size = Vector2.new(32, 32), Rounding = 0 })
D.brand   = New("Text",   { Text = "", Color = Theme.C1, Transparency = 1, ZIndex = 33, Font = 0, Size = FS + 4, Visible = true })
D.brandSub= New("Text",   { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = true })
D.title   = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS + 4, Visible = true })
D.searchGlow = New("Square", { Filled = false, Color = Theme.C1, Transparency = 0, ZIndex = 32, Corner = 8, Visible = false })
D.search  = New("Square", { Filled = true, Color = Theme.Panel, Transparency = ALPHA_BG, ZIndex = 32, Corner = 8, Visible = true })
D.searchT = New("Text",   { Text = "Search", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = true })
D.searchIco = New("Image", { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(12, 12), Color = Theme.Dim })
D.close   = New("Text",   { Text = "x", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = 15, Visible = true })
D.gripL1  = New("Line", { Color = Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
D.gripL2  = New("Line", { Color = Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
D.gripL3  = New("Line", { Color = Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
D.hilite  = New("Square", { Filled = true, Color = Theme.Panel, Transparency = 0.5, ZIndex = 32, Corner = 6, Visible = true })
D.hiliteBar = New("Square", { Filled = true, Color = Theme.C1, Transparency = 1, ZIndex = 33, Corner = 2, Visible = true })
D.hiliteEdge= New("Square", { Filled = false, Color = Theme.C1, Transparency = 0.5, ZIndex = 33, Corner = 6, Visible = true })
D.navHover  = New("Square", { Filled = true, Color = Theme.Panel, Transparency = 0.7, ZIndex = 32, Corner = 6, Visible = false })
D.sbDiv1  = NewFadeSegs(33)
D.sbDiv2  = NewFadeSegs(33)
D.avCirc  = New("Circle", { Filled = true, Color = Theme.Control, Transparency = 1, ZIndex = 33, Visible = true, Radius = 18, NumSides = 30 })
D.avatar  = New("Image",  { Transparency = 1, ZIndex = 34, Visible = true, Size = Vector2.new(36, 36), Rounding = 18 })
D.footName= New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS + 1, Visible = true })
D.footSub = New("Text",   { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = true })
D.gear    = New("Image",  { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(18, 18), Color = Theme.Dim })
D.verTag  = New("Text",   { Text = "v1.3", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 2, Visible = false })
D.pageTxt = New("Text",   { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = true })
D.sbTrack = New("Square", { Filled = true, Color = Theme.Panel, Transparency = 0.8, ZIndex = 36, Corner = 2, Visible = false })
D.sbThumb = New("Square", { Filled = true, Color = Theme.Track, Transparency = 1, ZIndex = 37, Corner = 2, Visible = false })
-- per-pixel glow: every segment is exactly 1px tall, so the falloff is truly seamless
local SBGLOW_N = 400
D.sbGlowSegs = {}
for i = 1, SBGLOW_N do
    D.sbGlowSegs[i] = New("Square", { Filled = true, Color = Theme.C1, Transparency = 0, ZIndex = 38, Corner = 0, Visible = false })
end
D.tipBox  = New("Square", { Filled = true, Color = Theme.Control, Transparency = 0.97, ZIndex = 110, Corner = 4, Visible = false })
D.tipL1   = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = FS - 1, Visible = false })
D.tipL2   = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = FS - 1, Visible = false })
D.tipL3   = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = FS - 1, Visible = false })
-- seam wedges: 1px slivers that fill the rounded-corner gaps where sidebar meets topbar.
-- they only cover pixels the bars leave empty, so nothing overlaps and nothing darkens.
local WEDGE_MAX = 20
D.wedges = {}
for i = 1, WEDGE_MAX * 4 do
    D.wedges[i] = New("Square", { Filled = true, Color = Theme.Dark, Transparency = ALPHA_BAR, ZIndex = 31, Corner = 0, Visible = false })
end

local DGroups = { D.sbDiv1, D.sbDiv2, D.sbGlowSegs, D.wedges }
local function isDGroup(o)
    for _, g in ipairs(DGroups) do if g == o then return true end end
    return false
end

local Items = {}
for i, tab in ipairs(Tabs) do
    Items[i] = {
        icon  = New("Image", { Transparency = 1, ZIndex = 33, Visible = true, Size = Vector2.new(15, 15), Color = Theme.Dim }),
        label = New("Text",  { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS + 4, Visible = true }),
    }
    loadIcon(tab.icon, function(data) Items[i].icon.Data = data end)
end
local okName, plrName = pcall(function() return game:GetService("Players").LocalPlayer.Name end)
local playerName = okName and tostring(plrName) or "player"
local okDisp, plrDisp = pcall(function() return game:GetService("Players").LocalPlayer.DisplayName end)
local displayName = (okDisp and plrDisp and #tostring(plrDisp) > 0) and tostring(plrDisp) or playerName

-- window options (CreateWindow overrides; nil keeps the default)
local BRAND = "LegoSense"
local SUBTITLE = nil            -- nil -> use the fetched game name
local VERSION = "v1.0"
local WinIcon = nil             -- nil -> default logo url; string url or numeric asset id
local LOGO_URL = "https://api.alo.ne/file/ngowge"

local GameName = "..."
local assetsStarted = false
local function startAssets()
    if assetsStarted then return end
    assetsStarted = true
    loadIcon("settings", function(data) D.gear.Data = data end)
    loadIcon("search", function(data) D.searchIco.Data = data end)
    loadAvatar(function(data) D.avatar.Data = data end)

    task.spawn(function()
        local ok, info = pcall(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId) end)
        if ok and info and info.Name then GameName = tostring(info.Name) Win.dirty = true return end
        local okU, uj = pcall(function()
            return game:HttpGet("https://apis.roblox.com/universes/v1/places/" .. tostring(game.PlaceId) .. "/universe")
        end)
        local uid = okU and tostring(uj):match('"universeId"%s*:%s*(%d+)') or nil
        if uid then
            local okG, gj = pcall(function() return game:HttpGet("https://games.roblox.com/v1/games?universeIds=" .. uid) end)
            local nm = okG and tostring(gj):match('"name"%s*:%s*"([^"]-)"') or nil
            if nm then GameName = nm Win.dirty = true end
        end
    end)

    task.spawn(function()
        local path = FOLDER .. "/logo2.txt"
        -- resolve the logo source: numeric asset id -> thumbnail url, string -> direct url, else default
        local url = LOGO_URL
        local usingCustom = false
        if type(WinIcon) == "string" and #WinIcon > 0 then url = WinIcon usingCustom = true
        elseif type(WinIcon) == "number" then
            usingCustom = true
            local okT, tj = pcall(function() return game:HttpGet("https://thumbnails.roblox.com/v1/assets?assetIds=" .. tostring(WinIcon) .. "&size=150x150&format=Png&isCircular=false") end)
            url = (okT and tostring(tj):match('"imageUrl"%s*:%s*"([^"]+)"')) or LOGO_URL
        end
        local data = nil
        if not usingCustom and isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 200 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return game:HttpGet(url) end)
            if ok and d and #d > 200 then
                data = d
                if not isfolder(FOLDER) then pcall(makefolder, FOLDER) end
                if not usingCustom then pcall(writefile, path, d) end
            else
                print("FALUI|logo fetch failed, keeping LS text")
            end
        end
        if data then pcall(function() D.logoImg.Data = data end) UI.logoLoaded = true Win.dirty = true end
    end)

    task.spawn(function()
        local path = FOLDER .. "/waifu.txt"
        local data = nil
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 1000 then data = d end
        end
        if not data then
            local ok, d = pcall(function()
                return game:HttpGet("https://raw.githubusercontent.com/nvqren/Matcha-Waifu/refs/heads/main/waifu.png")
            end)
            if ok and d and #d > 1000 then
                data = d
                if not isfolder(FOLDER) then pcall(makefolder, FOLDER) end
                pcall(writefile, path, d)
            end
        end
        if data then pcall(function() D.waifu.Data = data end) end
    end)
end

-- ========== snow ==========
-- plain "*" sparkles, no glow. flakes fade in at spawn and fade out near every edge and at
-- the bottom so they never pop; the fall advances in real px/s for a linear, smooth descent.
local Snow = { flakes = {}, hidden = true }
for i = 1, SNOW_N do
    local fs = math.floor((12 + (i % 6)) * 1.3 + 0.5)
    Snow.flakes[i] = {
        obj = New("Text", { Text = "*", Color = BaseC1, Transparency = 0, ZIndex = 32, Font = 0, Size = fs, Visible = false }),
        fs = fs,
        fx = math.random(), fy = math.random(),
        vy = (20 + math.random() * 8) * 1.2,
        amp = 3 + math.random() * 6, freq = 0.3 + math.random() * 0.5,
        ph = math.random() * 6.28, br = math.random(),
    }
end

local function updateSnow(dt, t)
    local on = Win.visible and Cfg.bgFx == "Snow"
    if not on then
        if not Snow.hidden then
            for _, f in ipairs(Snow.flakes) do f.obj.Visible = false end
            Snow.hidden = true
        end
        return
    end
    Snow.hidden = false
    local base = Cfg.fxColor or Theme.C1
    for _, f in ipairs(Snow.flakes) do
        f.py = (f.py or f.fy * Win.h) + f.vy * dt
        if f.py > Win.h + 8 then
            f.py = -8
            f.fx = math.random()
        end
        local px = Win.x + f.fx * Win.w + math.sin(t * f.freq + f.ph) * f.amp
        local py = Win.y + f.py
        local topB = (px < Win.x + Sb.cur) and (Win.y + 4) or (Win.y + TB + 2)
        -- soft distance to the nearest edge; alpha ramps over ~16px so nothing snaps on/off
        local m = math.min(px - (Win.x + 4), (Win.x + Win.w - 10) - px, py - topB, (Win.y + Win.h - 8) - py)
        local edge = math.max(0, math.min(1, m / 16))
        edge = edge * edge * (3 - 2 * edge)
        local shown = m > -f.fs
        f.obj.Visible = shown
        if shown then
            local twinkle = 0.4 + 0.4 * math.abs(math.sin(t * 1.4 + f.ph))
            f.obj.Position = Vector2.new(px - f.fs * 0.28, py - f.fs * 0.55)
            f.obj.Color = lerpColor(base, Theme.White, f.br * 0.4)
            f.obj.Transparency = twinkle * edge * Cfg.opacity
        end
    end
end

-- ========== dropdown popout ==========
local MAXOPT = 7
local Drop = { open = nil, options = {}, hovT = {}, searchBuf = "", scroll = 0, animT = 0, closing = false }
Drop.bg = New("Square", { Filled = true, Color = Theme.Dark, Transparency = 0.985, ZIndex = 100, Corner = 5, Visible = false })
Drop.searchBox = New("Square", { Filled = true, Color = Theme.Control, Transparency = 0.97, ZIndex = 101, Corner = 4, Visible = false })
Drop.searchTxt = New("Text", { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 102, Font = 0, Size = FS - 1, Visible = false })
Drop.sbT = New("Square", { Filled = true, Color = Theme.Track, Transparency = 1, ZIndex = 102, Corner = 1, Visible = false })
-- scaled-down copy of the main scrollbar's per-pixel glow, for the dropdown list scrollbar
local DROPGLOW_N = 140
Drop.glowSegs = {}
for i = 1, DROPGLOW_N do
    Drop.glowSegs[i] = New("Square", { Filled = true, Color = Theme.C1, Transparency = 0, ZIndex = 103, Corner = 0, Visible = false })
end
Drop.rows = {}
for i = 1, MAXOPT do
    Drop.rows[i] = {
        bg  = New("Square", { Filled = true, Color = Theme.Control, Transparency = 0, ZIndex = 101, Corner = 4, Visible = false }),
        txt = New("Text", { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = FS, Visible = false }),
        chk = New("Text", { Text = "+", Color = Theme.C1, Transparency = 1, ZIndex = 102, Font = 0, Size = FS, Visible = false }),
    }
    Drop.hovT[i] = 0
end

local function dropHideObjs()
    Drop.bg.Visible = false
    Drop.searchBox.Visible = false
    Drop.searchTxt.Visible = false
    Drop.sbT.Visible = false
    for i = 1, #Drop.glowSegs do Drop.glowSegs[i].Visible = false end
    for i = 1, MAXOPT do
        Drop.rows[i].bg.Visible = false
        Drop.rows[i].txt.Visible = false
        Drop.rows[i].chk.Visible = false
        Drop.hovT[i] = 0
    end
end

-- immediate teardown (used by the system: menu hide, tab switch, opening the picker)
local function hardCloseDropdown()
    Drop.open = nil
    Drop.closing = false
    Drop.animT = 0
    dropHideObjs()
end

-- user-facing close: play the slide-up/fade-out, real teardown happens when the anim finishes
local function closeDropdown()
    if Drop.open then Drop.closing = true Win.dirty = true else dropHideObjs() end
end

local function openDropdown(row)
    Drop.open = row
    Drop.options = row.options or {}
    Drop.searchBuf = ""
    Drop.scroll = 0
    Drop.closing = false
    Drop.animT = 0            -- grows to 1 -> slides down + fades in
end

local function dropFiltered()
    local out = {}
    local q = Drop.searchBuf:lower()
    for _, o in ipairs(Drop.options) do
        if q == "" or tostring(o):lower():find(q, 1, true) then
            table.insert(out, tostring(o))
        end
    end
    return out
end

-- ========== color picker (smooth grid) ==========
local SV_COLS, SV_ROWS, SV_CELL = 66, 42, 2.34
local HUE_SEGS = 72
local Pick = { open = nil, h = 0.3, s = 0.6, v = 0.8, hexFocus = false, hexBuf = "" }
Pick.bg   = New("Square", { Filled = true, Color = C3(14, 17, 11), Transparency = 0.985, ZIndex = 100, Corner = 6, Visible = false })
Pick.sv = {}
for r = 1, SV_ROWS do
    Pick.sv[r] = {}
    for c = 1, SV_COLS do
        Pick.sv[r][c] = New("Square", { Filled = true, Color = Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false, Size = Vector2.new(math.ceil(SV_CELL), math.ceil(SV_CELL)) })
    end
end
Pick.svCur = New("Square", { Filled = false, Color = Theme.White, Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(8, 8) })
Pick.hueSegs = {}
for i = 1, HUE_SEGS do
    Pick.hueSegs[i] = New("Square", { Filled = true, Color = Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false })
end
Pick.hueCur = New("Square", { Filled = false, Color = Theme.White, Transparency = 1, ZIndex = 102, Visible = false })
Pick.prev   = New("Square", { Filled = true, Color = Theme.C1, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
Pick.hexBox = New("Square", { Filled = true, Color = Theme.Control, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
Pick.hexTxt = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = FS - 1, Visible = false })

-- ========== search popup ==========
local SEARCH_MAX = 8
local Search = { active = false, buf = "", results = {}, hovT = {}, focus = nil, rect = nil, geom = nil }
Search.bg = New("Square", { Filled = true, Color = Theme.Dark, Transparency = 0.985, ZIndex = 100, Corner = 5, Visible = false })
Search.rows = {}
for i = 1, SEARCH_MAX do
    Search.rows[i] = {
        bg   = New("Square", { Filled = true, Color = Theme.Control, Transparency = 0, ZIndex = 101, Corner = 4, Visible = false }),
        txt  = New("Text",   { Text = "", Color = Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = FS, Visible = false }),
        icon = New("Image",  { Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(13, 13), Color = Theme.Dim }),
        tab  = New("Text",   { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 102, Font = 0, Size = FS - 1, Visible = false }),
    }
    Search.hovT[i] = 0
end
loadIcon("move-up-right", function(data)
    for i = 1, SEARCH_MAX do Search.rows[i].icon.Data = data end
end)

local function closeSearch()
    Search.active = false
    Search.buf = ""
    Search.bg.Visible = false
    for i = 1, SEARCH_MAX do
        local r = Search.rows[i]
        r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
        Search.hovT[i] = 0
    end
    Search.geom = nil
end

local function pickObjsVisible(v)
    Pick.bg.Visible = v
    for r = 1, SV_ROWS do for c = 1, SV_COLS do Pick.sv[r][c].Visible = v end end
    Pick.svCur.Visible = v
    for i = 1, HUE_SEGS do Pick.hueSegs[i].Visible = v end
    Pick.hueCur.Visible = v
    Pick.prev.Visible = v
    Pick.hexBox.Visible = v
    Pick.hexTxt.Visible = v
end

local function closePicker()
    Pick.open = nil
    Pick.hexFocus = false
    pickObjsVisible(false)
end

local function pickerColor() return hsv2rgb(Pick.h, Pick.s, Pick.v) end

local function pickerApply()
    if not Pick.open then return end
    local c = pickerColor()
    Pick.open.color = c
    if Pick.open.onChange then pcall(Pick.open.onChange, c) end
end

local function openPicker(row)
    hardCloseDropdown()
    Pick.open = row
    local h, s, v = rgb2hsv(row.color or Theme.C1)
    Pick.h, Pick.s, Pick.v = h, s, v
    Pick.hexFocus = false
    pickObjsVisible(true)
end

local Capture = { row = nil }
local Focus = { row = nil }
local keyStates = {}

-- ========== components ==========
local Pages = {}
local FlagRows = {}

local function addSection(tabIdx, title, side)
    Pages[tabIdx] = Pages[tabIdx] or { sections = {}, scrollY = 0, scrollCur = 0, contentH = 0, maxScroll = 0 }
    local sec = {
        title = title, side = side, rows = {}, hovT = 0, vis = true,
        hdr  = New("Text", { Text = title, Color = Theme.Header, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = false }),
        hsegs= NewFadeSegs(33),
        panel= New("Square", { Filled = true, Color = Theme.Panel, Transparency = ALPHA_CARD, ZIndex = 31, Corner = 6, Visible = false }),
        glow = New("Square", { Filled = false, Color = Theme.C1, Transparency = 0, ZIndex = 32, Corner = 6, Visible = false }),
    }
    table.insert(Pages[tabIdx].sections, sec)
    return sec
end

local function regFlag(row, flag)
    if flag then row.flag = flag FlagRows[flag] = row end
    return row
end

local function addToggle(sec, label, default, flag, onChange)
    local row = {
        kind = "toggle", label = label, value = default and true or false, onChange = onChange,
        knobT = default and 1 or 0, hovT = 0, vis = true, h = 34,
        lbl   = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = false }),
        track = New("Square", { Filled = true, Color = Theme.Track, Transparency = 1, ZIndex = 33, Corner = 6, Visible = false, Size = Vector2.new(34, 18) }),
        oline = New("Square", { Filled = false, Color = Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 6, Visible = false, Size = Vector2.new(34, 18) }),
        knob  = New("Square", { Filled = true, Color = Theme.Knob, Transparency = 1, ZIndex = 35, Corner = 5, Visible = false, Size = Vector2.new(14, 14) }),
    }
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addSlider(sec, label, min, max, default, suffix, flag, onChange)
    local row = {
        kind = "slider", label = label, min = min, max = max, value = default, suffix = suffix or "", onChange = onChange,
        hovT = 0, vis = true, h = 44,
        lbl   = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = false }),
        chip  = New("Square", { Filled = true, Color = Theme.Control, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(52, 17) }),
        chipT = New("Text", { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = FS - 1, Visible = false }),
        track = New("Square", { Filled = true, Color = Theme.Track, Transparency = 1, ZIndex = 33, Corner = 1, Visible = false }),
        segs  = {},
        knob  = New("Circle", { Filled = true, Color = Theme.Knob, Transparency = 1, ZIndex = 35, Visible = false, Radius = 5, NumSides = 16 }),
    }
    for i = 1, GRAD_SEGS do
        row.segs[i] = New("Square", { Filled = true, Color = Theme.C1, Transparency = 1, ZIndex = 34, Visible = false })
    end
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addButton(sec, label, onClick)
    local row = {
        kind = "button", label = label, onClick = onClick, hovT = 0, vis = true, h = 32,
        box = New("Square", { Filled = true, Color = Theme.Control, Transparency = ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = New("Square", { Filled = false, Color = Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        lbl = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = FS, Visible = false }),
    }
    table.insert(sec.rows, row)
    return row
end

local function addButtonRow(sec, defs)
    local row = { kind = "buttonrow", defs = defs, hovT = 0, vis = true, hovTs = {}, h = 32, boxes = {}, lbls = {} }
    row.olines = {}
    for i, d in ipairs(defs) do
        row.boxes[i] = New("Square", { Filled = true, Color = Theme.Control, Transparency = ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false })
        row.olines[i] = New("Square", { Filled = false, Color = Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false })
        row.lbls[i]  = New("Text", { Text = d.label, Color = Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = FS, Visible = false })
        row.hovTs[i] = 0
    end
    table.insert(sec.rows, row)
    return row
end

local function addDropdown(sec, label, options, default, flag, onChange)
    local row = {
        kind = "dropdown", label = label, options = options, value = default, onChange = onChange,
        hovT = 0, vis = true, h = 34,
        lbl = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = false }),
        box = New("Square", { Filled = true, Color = Theme.Control, Transparency = ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = New("Square", { Filled = false, Color = Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        val = New("Text", { Text = default, Color = Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = FS, Visible = false }),
        arr = New("Text", { Text = "v", Color = Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addColor(sec, label, default, flag, onChange)
    local row = {
        kind = "color", label = label, color = default, onChange = onChange, hovT = 0, vis = true, h = 34,
        lbl = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = false }),
        sw  = New("Square", { Filled = true, Color = default, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(16, 16) }),
    }
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addKeybind(sec, label, defaultVk, flag, onChange)
    local row = {
        kind = "keybind", label = label, vk = defaultVk, onChange = onChange, hovT = 0, vis = true, h = 34,
        lbl  = New("Text", { Text = label, Color = Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = FS, Visible = false }),
        chip = New("Square", { Filled = true, Color = Theme.Control, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(44, 17) }),
        chipT= New("Text", { Text = keyName(defaultVk), Color = Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addTextbox(sec, label, default, flag, onChange)
    local row = {
        kind = "textbox", label = label, value = default or "", onChange = onChange, hovT = 0, vis = true, h = 48,
        lbl = New("Text", { Text = label, Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = false }),
        box = New("Square", { Filled = true, Color = Theme.Control, Transparency = ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = New("Square", { Filled = false, Color = Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        txt = New("Text", { Text = default or "", Color = Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = FS, Visible = false }),
    }
    table.insert(sec.rows, row)
    return regFlag(row, flag)
end

local function addDivider(sec, label)
    local row = { kind = "divider", label = label, hovT = 0, vis = true, h = 20,
        lbl = New("Text", { Text = label, Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = false }),
        segsL = NewFadeSegs(33),
        segsR = NewFadeSegs(33) }
    table.insert(sec.rows, row)
    return row
end

local function addNote(sec, label)
    local row = { kind = "note", label = label, hovT = 0, vis = true, h = 24,
        lbl = New("Text", { Text = label, Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS - 1, Visible = false }) }
    table.insert(sec.rows, row)
    return row
end

local function rowObjs(row)
    local t = {}
    for _, key in ipairs({"lbl", "track", "knob", "chip", "chipT", "box", "val", "arr", "sw", "txt", "oline"}) do
        if row[key] then table.insert(t, row[key]) end
    end
    if row.segs then for _, s in ipairs(row.segs) do table.insert(t, s) end end
    if row.boxes then for _, b in ipairs(row.boxes) do table.insert(t, b) end end
    if row.olines then for _, b in ipairs(row.olines) do table.insert(t, b) end end
    if row.segsL then for _, b in ipairs(row.segsL) do table.insert(t, b) end end
    if row.segsR then for _, b in ipairs(row.segsR) do table.insert(t, b) end end
    if row.lbls then for _, l in ipairs(row.lbls) do table.insert(t, l) end end
    return t
end

local function setPageVisible(tabIdx, v)
    local page = Pages[tabIdx]
    if not page then return end
    for _, sec in ipairs(page.sections) do
        sec.hdr.Visible = v
        for _, s in ipairs(sec.hsegs) do s.Visible = false end
        sec.panel.Visible = v
        sec.glow.Visible = false
        for _, row in ipairs(sec.rows) do
            for _, o in ipairs(rowObjs(row)) do o.Visible = v end
        end
    end
    if not v then hardCloseDropdown() closePicker() end
end

-- ========== config system (clean, sorted JSON) ==========
local HttpService = game:GetService("HttpService")

-- hand-rolled JSON encoder: keys sorted alphabetically so files are stable and human-readable
local function jsonEsc(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\'
        elseif c == '\n' then return '\\n' elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t' else return string.format('\\u%04x', string.byte(c)) end
    end))
end
local function jsonEnc(v)
    local t = type(v)
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    end
    if t == "string" then return '"' .. jsonEsc(v) .. '"' end
    if t == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i = 1, #v do parts[i] = jsonEnc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. jsonEsc(tostring(k)) .. '":' .. jsonEnc(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end
-- self-contained JSON parser (no HttpService dependency, so loads work on any executor)
local function jsonParse(s)
    local i, n = 1, #s
    local function skip() while i <= n do local c = s:sub(i, i) if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end end end
    local parseVal
    local function parseStr()
        i = i + 1
        local buf = {}
        while i <= n do
            local c = s:sub(i, i)
            if c == '"' then i = i + 1 return table.concat(buf) end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                if e == "n" then buf[#buf + 1] = "\n" elseif e == "t" then buf[#buf + 1] = "\t"
                elseif e == "r" then buf[#buf + 1] = "\r" elseif e == "u" then
                    local hx = s:sub(i + 2, i + 5); local cp = tonumber(hx, 16) or 63
                    buf[#buf + 1] = (cp < 128) and string.char(cp) or "?"; i = i + 4
                else buf[#buf + 1] = e end
                i = i + 2
            else buf[#buf + 1] = c i = i + 1 end
        end
        return table.concat(buf)
    end
    parseVal = function()
        skip()
        local c = s:sub(i, i)
        if c == '"' then return parseStr()
        elseif c == "{" then
            local o = {}; i = i + 1; skip()
            if s:sub(i, i) == "}" then i = i + 1 return o end
            while i <= n do
                skip() local k = parseStr() skip() i = i + 1 -- skip ':'
                o[k] = parseVal() skip()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then break end
            end
            return o
        elseif c == "[" then
            local a = {}; i = i + 1; skip()
            if s:sub(i, i) == "]" then i = i + 1 return a end
            while i <= n do
                a[#a + 1] = parseVal() skip()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then break end
            end
            return a
        elseif c == "t" then i = i + 4 return true
        elseif c == "f" then i = i + 5 return false
        elseif c == "n" then i = i + 4 return nil
        else
            local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
            if num then i = i + #num return tonumber(num) end
            i = i + 1 return nil
        end
    end
    local ok, r = pcall(parseVal)
    if ok and type(r) == "table" then return r end
    return nil
end
local function jsonDecode(txt)
    if type(txt) ~= "string" or #txt == 0 then return nil end
    if txt:match("^%s*return") then -- legacy Lua configs still load
        local ok, chunk = pcall(loadstring, txt)
        if ok and chunk then local ok2, d = pcall(chunk) if ok2 and type(d) == "table" then return d end end
        return nil
    end
    return jsonParse(txt)
end

local function flagValue(row)
    if row.kind == "color" then
        local c = row.color
        return { c.R, c.G, c.B }
    elseif row.kind == "keybind" then return row.vk
    else return row.value end
end

local function arr2c(a)
    if type(a) ~= "table" or not a[1] then return nil end
    local r, g, b = a[1], a[2] or 0, a[3] or 0
    if r <= 1 and g <= 1 and b <= 1 then r, g, b = r * 255, g * 255, b * 255 end
    return C3(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end

-- every surface colour saved explicitly, so any theme (preset OR custom) restores exactly
local THEME_KEYS = { "Dark", "Bg", "Panel", "PanelHov", "Control", "Track", "Header", "C1", "C2", "Text" }
local function snapshot()
    local t = { w = Win.w, h = Win.h, x = Win.x, y = Win.y }
    for flag, row in pairs(FlagRows) do
        local v = flagValue(row)
        if v ~= nil then t[flag] = v end
    end
    local th = {}
    for _, k in ipairs(THEME_KEYS) do local c = Theme[k] th[k] = { c.R, c.G, c.B } end
    t.theme = th
    return jsonEnc(t)
end

local function applyRow(row, v)
    if row.kind == "toggle" and type(v) == "boolean" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "slider" and type(v) == "number" then
        row.value = math.max(row.min, math.min(row.max, v))
        if row.onChange then pcall(row.onChange, row.value) end
    elseif row.kind == "dropdown" and type(v) == "string" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "color" and type(v) == "table" and v[1] then
        -- accept 0-1 floats (current) or legacy 0-255 ints
        local r, g, b = v[1], v[2] or 0, v[3] or 0
        if r <= 1 and g <= 1 and b <= 1 then r, g, b = r * 255, g * 255, b * 255 end
        row.color = C3(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
        if row.onChange then pcall(row.onChange, row.color) end
    elseif row.kind == "keybind" and type(v) == "number" then
        row.vk = v
        row.chipT.Text = keyName(v)
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "textbox" and type(v) == "string" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    end
end

-- flags applied in a fixed order: "preset" first (it retints the theme and overwrites the
-- colour swatches), then the colours (so a saved Custom colour wins), then everything else.
local LOAD_ORDER = { preset = 1, color1 = 2, color2 = 2 }
local function loadSnapshot(txt)
    local data = jsonDecode(txt)
    if type(data) ~= "table" then return false end
    -- window geometry
    if type(data.w) == "number" and type(data.h) == "number" then
        Win.w = math.max(MIN_W, data.w)
        Win.h = math.max(MIN_H, data.h)
    end
    if type(data.x) == "number" then Win.x = data.x end
    if type(data.y) == "number" then Win.y = data.y end
    local ordered = {}
    for flag, v in pairs(data) do
        if FlagRows[flag] then table.insert(ordered, flag) end
    end
    table.sort(ordered, function(a, b)
        return (LOAD_ORDER[a] or 9) < (LOAD_ORDER[b] or 9)
    end)
    for _, flag in ipairs(ordered) do
        applyRow(FlagRows[flag], data[flag])
    end
    -- explicit theme palette applied last -> exact surface colours regardless of preset/custom
    if type(data.theme) == "table" then
        for _, k in ipairs(THEME_KEYS) do
            local c = arr2c(data.theme[k])
            if c then Theme[k] = c end
        end
    end
    Win.dirty = true
    return true
end

local cfgDirty = false
local function markChanged() cfgDirty = true end

local function configList()
    local names = {}
    if isfile(cfgDir() .. "/_index.txt") then
        local ok, txt = pcall(readfile, cfgDir() .. "/_index.txt")
        if ok and txt then
            for line in txt:gmatch("[^\r\n]+") do
                if #line > 0 then table.insert(names, line) end
            end
        end
    end
    return names
end

local function writeIndex(names)
    pcall(writefile, cfgDir() .. "/_index.txt", table.concat(names, "\n"))
end

local function ensureCfgDir()
    if not isfolder(FOLDER) then pcall(makefolder, FOLDER) end
    if not isfolder(cfgDir()) then pcall(makefolder, cfgDir()) end
end

-- the auto-load choice lives in its own tiny file, separate from any config's data, so the
-- "which config loads on startup" pointer stays clear and never gets tangled in the saved state.
local function writeAutoload(name)
    ensureCfgDir()
    if not name or name == "" or name == "none" then
        pcall(function() if isfile(FOLDER .. "/autoload.txt") then delfile(FOLDER .. "/autoload.txt") end end)
    else
        pcall(writefile, FOLDER .. "/autoload.txt", name)
    end
end
local function readAutoload()
    if isfile(FOLDER .. "/autoload.txt") then
        local ok, txt = pcall(readfile, FOLDER .. "/autoload.txt")
        if ok and txt then
            local nm = txt:gsub("[\r\n]", "")
            if #nm > 0 then return nm end
        end
    end
    return "none"
end

-- ========== settings page ==========
local Presets = {
    Waifu = { c1 = BaseC1, c2 = BaseC2,
        Dark = C3(14, 18, 11), Bg = C3(38, 44, 35), Panel = C3(42, 46, 37), PanelHov = C3(50, 54, 44),
        Control = C3(52, 57, 46), Track = C3(70, 74, 64), Header = C3(150, 172, 116) },
    Midnight = { c1 = C3(127, 178, 229), c2 = C3(156, 214, 240),
        Dark = C3(11, 14, 18), Bg = C3(33, 38, 46), Panel = C3(40, 46, 55), PanelHov = C3(47, 54, 64),
        Control = C3(48, 56, 66), Track = C3(64, 72, 84), Header = C3(122, 158, 198) },
    Ember = { c1 = C3(229, 151, 95), c2 = C3(240, 201, 121),
        Dark = C3(18, 14, 11), Bg = C3(44, 38, 33), Panel = C3(52, 45, 38), PanelHov = C3(60, 52, 44),
        Control = C3(62, 54, 45), Track = C3(82, 72, 61), Header = C3(196, 152, 110) },
    Mono = { c1 = C3(228, 230, 234), c2 = C3(176, 180, 188),
        Dark = C3(13, 14, 16), Bg = C3(34, 35, 38), Panel = C3(43, 44, 48), PanelHov = C3(52, 53, 58),
        Control = C3(54, 55, 60), Track = C3(78, 80, 86), Header = C3(190, 193, 200) },
    -- Rainbow uses Mono's light surfaces; the frame loop cycles the accent + sidebar/topbar hue
    Rainbow = { c1 = C3(228, 230, 234), c2 = C3(176, 180, 188),
        Dark = C3(30, 24, 40), Bg = C3(34, 35, 38), Panel = C3(43, 44, 48), PanelHov = C3(52, 53, 58),
        Control = C3(54, 55, 60), Track = C3(78, 80, 86), Header = C3(190, 193, 200) },
    Custom = nil,
}

local function applyPreset(name)
    local p = Presets[name]
    if not p then return end
    Theme.C1 = p.c1
    Theme.C2 = p.c2
    Theme.Dark = p.Dark
    Theme.Bg = p.Bg
    Theme.Panel = p.Panel
    Theme.PanelHov = p.PanelHov
    Theme.Control = p.Control
    Theme.Track = p.Track
    Theme.Header = p.Header
    Win.dirty = true
end
local rColor1, rColor2, rConfigDrop, rAutoLoad, rName

local function applyAccent(c1, c2)
    Theme.C1 = c1
    Theme.C2 = c2
    Win.dirty = true
end

do
    local sTheme = addSection(SETTINGS_TAB, "THEME", "left")
    addDropdown(sTheme, "Preset", { "Waifu", "Midnight", "Ember", "Mono", "Rainbow", "Custom" }, "Ember", "preset", function(v)
        Cfg.preset = v
        local p = Presets[v]
        if p then
            applyPreset(v)
            if rColor1 then rColor1.color = p.c1 end
            if rColor2 then rColor2.color = p.c2 end
        end
        markChanged()
    end).tip = "Pick a look, Rainbow to cycle, or Custom for your own colours"
    rColor1 = addColor(sTheme, "Color 1", BaseC1, "color1", function(c) Theme.C1 = c Cfg.preset = "Custom" Win.dirty = true markChanged() end)
    rColor2 = addColor(sTheme, "Color 2", BaseC2, "color2", function(c) Theme.C2 = c Cfg.preset = "Custom" Win.dirty = true markChanged() end)
    local rSpeed = addSlider(sTheme, "Rainbow speed", 10, 300, 100, " %", "rainbowSpeed", function(v) Cfg.rainbowSpeed = v markChanged() end)
    rSpeed.showIf = "Rainbow"          -- only present while the Rainbow theme is active
    rSpeed.showT = (Cfg.preset == "Rainbow") and 1 or 0

    local sApp = addSection(SETTINGS_TAB, "APPEARANCE", "left")
    addColor(sApp, "Background", Theme.Bg, "bgColor", function(c) Theme.Bg = c Win.dirty = true markChanged() end)
    addColor(sApp, "Text color", Theme.Text, "textColor", function(c) Theme.Text = c Win.dirty = true markChanged() end)
    addSlider(sApp, "Card glow", 0, 200, 60, " %", "cardGlow", function(v) Cfg.cardGlow = v markChanged() end).tip = "Accent glow around section cards"
    addDropdown(sApp, "Background FX", { "Off", "Snow" }, "Snow", "bgFx", function(v) Cfg.bgFx = v markChanged() end).tip = "Sparkles drifting inside the menu"
    addColor(sApp, "FX colour", BaseC1, "fxColor", function(c) Cfg.fxColor = c markChanged() end)
    addSlider(sApp, "Corner radius", 0, 200, 100, " %", "cornerRadius", function(v) Cfg.cornerRadius = v Win.dirty = true markChanged() end)
    addDivider(sApp, "Misc")
    addToggle(sApp, "Performance mode", false, "perfMode", function(v) Cfg.perfMode = v markChanged() end)
    addToggle(sApp, "Smart FPS", false, "smartFps", function(v) Cfg.smartFps = v markChanged() end)

    local sIface = addSection(SETTINGS_TAB, "INTERFACE", "right")
    addKeybind(sIface, "Menu key", 0x24, "menuKey", function(vk) Cfg.menuKey = vk markChanged() end)
    addToggle(sIface, "Keybind overlay", false, "keybindOverlay", function(v) Cfg.keybindOverlay = v markChanged() end)
    addToggle(sIface, "Hover effects", true, "hoverFx", function(v) Cfg.hoverFx = v markChanged() end)
    addToggle(sIface, "Checkbox style", false, "checkbox", function(v) Cfg.checkbox = v Win.dirty = true markChanged() end).tip = "Square checkboxes instead of pills"
    addToggle(sIface, "Collapse sidebar", false, "collapseSidebar", function(v) Cfg.collapseSidebar = v markChanged() end).tip = "Pin the sidebar closed (no hover expand)"
    addToggle(sIface, "Inline dropdowns", false, "inlineDropdowns", function(v) Cfg.inlineDropdowns = v markChanged() end).tip = "Coming soon: expand in place instead of popout"
    addDropdown(sIface, "Tab layout", { "Sidebar" }, "Sidebar", "tabLayout", function(v) Cfg.tabLayout = v markChanged() end)
    addDropdown(sIface, "Search", { "Bar", "Off" }, "Bar", "search", function(v) Cfg.search = v Win.dirty = true markChanged() end)
    addDropdown(sIface, "Font", { "UI", "System", "SystemBold", "Minecraft", "Monospace", "Pixel" }, "UI", "font", function(v) applyFont(v) markChanged() end)
    addSlider(sIface, "Menu opacity", 30, 100, 100, " %", "opacity", function(v) setOpacity(v / 100) markChanged() end)
    addToggle(sIface, "Animations", true, "animations", function(v) Cfg.animations = v markChanged() end)
    addSlider(sIface, "Notify time", 1, 15, 5, " s", "notifyTime", function(v) Cfg.notifyTime = v markChanged() end)

    local sCfgS = addSection(SETTINGS_TAB, "CONFIGS", "right")
    rName = addTextbox(sCfgS, "Name", "MyConfig", nil, nil)
    addButtonRow(sCfgS, {
        { label = "Save", cb = function()
            local nm = rName.value:gsub("[^%w_%-]", "")
            if #nm == 0 then return end
            ensureCfgDir()
            pcall(writefile, cfgDir() .. "/" .. nm .. ".json", snapshot())
            local names = configList()
            local found = false
            for _, n in ipairs(names) do if n == nm then found = true end end
            if not found then table.insert(names, nm) writeIndex(names) end
            if rConfigDrop then rConfigDrop.options = configList() end
            if rAutoLoad then
                local o = { "none" }
                for _, n in ipairs(configList()) do table.insert(o, n) end
                rAutoLoad.options = o
            end
        end },
        { label = "Load", cb = function()
            local nm = (rConfigDrop and rConfigDrop.value) or ""
            if nm ~= "" and nm ~= "none" then
                local path = cfgDir() .. "/" .. nm .. ".json"
                if not isfile(path) and isfile(cfgDir() .. "/" .. nm .. ".lua") then path = cfgDir() .. "/" .. nm .. ".lua" end
                if isfile(path) then
                    local ok, txt = pcall(readfile, path)
                    if ok and txt then loadSnapshot(txt) end
                end
            end
        end },
        { label = "Delete", cb = function()
            local nm = (rConfigDrop and rConfigDrop.value) or ""
            if nm ~= "" and nm ~= "none" then
                pcall(function() if isfile(cfgDir() .. "/" .. nm .. ".json") then delfile(cfgDir() .. "/" .. nm .. ".json") end end)
                pcall(function() if isfile(cfgDir() .. "/" .. nm .. ".lua") then delfile(cfgDir() .. "/" .. nm .. ".lua") end end)
                local names = configList()
                for i = #names, 1, -1 do if names[i] == nm then table.remove(names, i) end end
                writeIndex(names)
                if rConfigDrop then rConfigDrop.options = names rConfigDrop.value = names[1] or "none" end
                if rAutoLoad then
                    local o = { "none" }
                    for _, n in ipairs(names) do table.insert(o, n) end
                    rAutoLoad.options = o
                end
            end
        end },
    })
    rConfigDrop = addDropdown(sCfgS, "Config", configList(), "none", nil, nil)
    addToggle(sCfgS, "Auto-save", true, "autoSave", function(v) Cfg.autoSave = v markChanged() end).tip = "Persist settings to disk automatically"
    local alOpts = { "none" }
    for _, n in ipairs(configList()) do table.insert(alOpts, n) end
    rAutoLoad = addDropdown(sCfgS, "Auto-load", alOpts, "none", nil, function(v) Cfg.autoLoad = v writeAutoload(v) end)

    local sSys = addSection(SETTINGS_TAB, "SYSTEM", "right")
    addButton(sSys, "Re-center window", function()
        local ok, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
        if ok and vp then
            Win.x = math.floor((vp.X - Win.w) / 2)
            Win.y = math.floor((vp.Y - Win.h) / 2)
            Win.dirty = true
        end
    end)
    addButton(sSys, "Minimize", function() end)
    addButton(sSys, "Unload UI", function() UI.Unload() end)
end

-- effective row height: conditional rows (row.showT) collapse to 0 so the card resizes smoothly
local function rowEffH(row)
    local t = row.showT
    if t == nil then return row.h end
    t = t * t * (3 - 2 * t)
    return row.h * t
end

-- ========== layout (with scroll + culling) ==========
local function relayoutRaw()
    local x, y, w, h = Win.x, Win.y, Win.w, Win.h
    local sw = math.floor(Sb.cur + 0.5)
    local expandT = (Sb.cur - SB_MIN) / math.max(1, Sb.max - SB_MIN)

    D.main.Position = Vector2.new(x, y)
    D.main.Size = Vector2.new(w, h)
    D.main.Color = Theme.Bg
    D.main.Corner = CR(8)
    -- topbar tucks well under the opaque sidebar so its rounded-left seam is hidden
    -- topbar butts against the sidebar (no overlap -> no double-transparency darkening)
    D.topbar.Position = Vector2.new(x + sw, y)
    D.topbar.Size = Vector2.new(w - sw, TB)
    D.topbar.Corner = CR(6)
    D.seam.Visible = false
    -- fill the rounded-corner gaps at the sidebar/topbar seam with 1px slivers.
    -- each sliver lands only on pixels the bars round away, so nothing overlaps -> no darkening.
    do
        local seamX = x + sw
        local rt = CR(6) -- topbar corner radius
        local rs = CR(8) -- sidebar corner radius
        local wi = 0
        local function inset(r, j) -- px cut from the flush edge on row offset j
            local dy = r - j - 0.5
            local k = r * r - dy * dy
            if k <= 0 then return 0 end
            return r - math.sqrt(k)
        end
        -- widths rounded UP (ceil) so the sliver covers the fractional edge pixel the arc
        -- leaves behind; a <1px overshoot into the bar is invisible, a <1px gap shows bg.
        local function sliver(px, py, wpx, hpx)
            wpx = math.ceil(wpx)
            if wpx < 1 then return end
            wi = wi + 1
            local o = D.wedges[wi]
            if not o then return end
            o.Visible = Win.visible
            o.Position = Vector2.new(px, py)
            o.Size = Vector2.new(wpx, hpx or 1)
            o.Color = Theme.Dark
        end
        -- topbar top-left corner: empty pixels sit right of the seam, near the top
        for j = 0, rt - 1 do sliver(seamX, y + j, inset(rt, j)) end
        -- topbar bottom-left corner: empty pixels right of the seam, near topbar bottom
        for j = 0, rt - 1 do sliver(seamX, y + TB - 1 - j, inset(rt, j)) end
        -- sidebar top-right corner: empty pixels left of the seam, near the top
        for j = 0, rs - 1 do
            local w = math.ceil(inset(rs, j))
            sliver(seamX - w, y + j, w)
        end
        for i = wi + 1, #D.wedges do D.wedges[i].Visible = false end
    end
    D.sidebar.Position = Vector2.new(x, y)
    D.sidebar.Size = Vector2.new(sw, h)
    D.sidebar.Corner = CR(8)

    D.sidebar.Color = Theme.Dark
    D.topbar.Color = Theme.Dark
    D.search.Color = Theme.Panel
    D.avCirc.Color = Theme.Control
    D.logo.Position = Vector2.new(x + 12, y + 6)
    D.logo.Color = Theme.C1
    D.logo.Corner = CR(7)
    D.logo.Visible = Win.visible and not UI.logoLoaded
    D.logoTxt.Visible = Win.visible and not UI.logoLoaded
    D.logoTxt2.Visible = Win.visible and not UI.logoLoaded
    D.logoImg.Visible = Win.visible and UI.logoLoaded and true or false
    D.logoImg.Position = Vector2.new(x + 12, y + 6)
    local lsX = x + 12 + math.floor((32 - 2 * CHAR_W) / 2) - 1
    D.logoTxt.Position = Vector2.new(lsX, y + 17)
    D.logoTxt2.Position = Vector2.new(lsX + 1, y + 17)
    D.brand.Position = Vector2.new(x + 52, y + 8)
    D.brand.Color = Theme.C1
    D.brand.Text = expandT > 0.05 and truncateB(BRAND, sw - 52 - 8) or ""
    D.brandSub.Position = Vector2.new(x + 52, y + 28)
    D.brandSub.Text = expandT > 0.05 and truncate(SUBTITLE or GameName, sw - 52 - 8) or ""

    -- sidebar dividers: centered fades that grow from the middle as the sidebar opens
    local divA = expandT
    local midX = x + sw / 2
    local halfSpan = (sw / 2 - 10) * divA
    layoutFade(D.sbDiv1, midX - halfSpan, midX + halfSpan, y + 47, "center", 0.5 * divA, Win.visible and divA > 0.08)
    layoutFade(D.sbDiv2, midX - halfSpan, midX + halfSpan, y + h - 66, "center", 0.5 * divA, Win.visible and divA > 0.08)

    local titleName = (activeTab == SETTINGS_TAB) and "Settings" or Tabs[activeTab].name
    D.title.Position = Vector2.new(x + sw + 16, y + 9)
    D.title.Color = Theme.Text
    local searchW = (Cfg.search == "Bar") and math.min(180, math.max(0, w - sw - 220)) or 0
    D.search.Visible = Win.visible and searchW > 40
    D.searchT.Visible = D.search.Visible
    D.searchIco.Visible = D.search.Visible
    D.searchGlow.Visible = D.search.Visible
    if searchW > 40 then
        local sX = x + w - 36 - searchW
        D.search.Position = Vector2.new(sX, y + 8)
        D.search.Size = Vector2.new(searchW, 20)
        D.search.Corner = CR(8)
        -- card-style glow around the field, driven by the same "Card glow" slider
        local sGlowA = math.min(1, 0.14 + 0.12 * Cfg.cardGlow / 100 + (Search.active and 0.4 or 0)) * Cfg.opacity
        D.searchGlow.Position = Vector2.new(sX - 1, y + 7)
        D.searchGlow.Size = Vector2.new(searchW + 2, 22)
        D.searchGlow.Corner = CR(8)
        D.searchGlow.Color = Theme.C1
        D.searchGlow.Transparency = sGlowA
        -- magnifier icon on the right, text to its left
        D.searchIco.Position = Vector2.new(sX + searchW - 18, y + 12)
        D.searchIco.Color = Search.active and Theme.C1 or Theme.Dim
        D.searchT.Position = Vector2.new(sX + 10, y + 12)
        if Search.active then
            D.searchT.Text = truncate((#Search.buf > 0 and Search.buf or "") .. "_", searchW - 30)
            D.searchT.Color = Theme.Text
        else
            D.searchT.Text = truncate("Search", searchW - 30)
            D.searchT.Color = Theme.Dim
        end
        Search.rect = { x = sX, y = y + 8, w = searchW, h = 20 }
    else
        Search.rect = nil
        if Search.active then closeSearch() end
    end
    D.title.Text = truncateB(titleName, w - sw - 16 - 50 - searchW)
    D.close.Position = Vector2.new(x + w - 20, y + 9)
    do
        local gx, gy = x + w - 6, y + h - 6
        local lens = { 12, 8, 4 }
        local ls = { D.gripL1, D.gripL2, D.gripL3 }
        for i = 1, 3 do
            local L = lens[i]
            ls[i].From = Vector2.new(gx - L, gy)
            ls[i].To = Vector2.new(gx, gy - L)
            ls[i].Color = Theme.Dim
        end
    end

    local iy = itemsTop()
    for i, it in ipairs(Items) do
        local top = iy + (i - 1) * ITEM_H
        it.icon.Position = Vector2.new(x + 20, top + 10)
        it.label.Position = Vector2.new(x + 52, top + 9)
        it.label.Text = expandT > 0.05 and truncateB(Tabs[i].name, sw - 52 - 8) or ""
        it.icon.Color = (i == activeTab) and Theme.C1 or Theme.Dim
        it.label.Color = (i == activeTab) and Theme.C1 or Theme.Dim
    end
    local selShown = Win.visible and activeTab ~= SETTINGS_TAB
    D.hilite.Visible = selShown
    D.hiliteBar.Visible = selShown
    D.hiliteEdge.Visible = selShown
    local selX, selW = x + 6, math.max(8, sw - 12)
    local selY = itemsTop() + hiliteY + 2
    D.hilite.Position = Vector2.new(selX, selY)
    D.hilite.Size = Vector2.new(selW, ITEM_H - 8)
    D.hilite.Corner = CR(6)
    D.hilite.Color = lerpColor(Theme.Panel, Theme.C1, 0.18)
    D.hiliteEdge.Position = Vector2.new(selX, selY)
    D.hiliteEdge.Size = Vector2.new(selW, ITEM_H - 8)
    D.hiliteEdge.Corner = CR(6)
    D.hiliteEdge.Color = Theme.C1
    D.hiliteBar.Position = Vector2.new(selX, selY + 4)
    D.hiliteBar.Size = Vector2.new(3, ITEM_H - 16)
    D.hiliteBar.Color = Theme.C1

    D.avCirc.Position = Vector2.new(x + 28, y + h - 36)
    D.avatar.Position = Vector2.new(x + 10, y + h - 54)
    local nameAvail = sw - 52 - 34
    D.footName.Position = Vector2.new(x + 52, y + h - 46)
    D.footName.Color = Theme.Text
    D.footName.Text = expandT > 0.05 and truncateB(displayName, nameAvail) or ""
    D.footSub.Position = Vector2.new(x + 52, y + h - 30)
    D.footSub.Text = expandT > 0.05 and truncate("@" .. playerName, nameAvail) or ""
    D.gear.Visible = Win.visible and expandT > 0.6
    D.gear.Position = Vector2.new(x + sw - 30, y + h - 44)
    D.gear.Color = (activeTab == SETTINGS_TAB) and Theme.C1 or Theme.Dim
    D.verTag.Visible = Win.visible
    D.verTag.Text = VERSION
    D.verTag.Position = Vector2.new(x + 14, y + h - 78)
    D.verTag.Color = Theme.Dim

    local cx = x + sw + PAD
    local cw = w - sw - PAD * 2 - 8
    -- waifu art: bounded by sidebar + topbar, centered in content
    do
        local artH = h - TB - 4
        local artW = math.floor(artH * WAIFU_RATIO)
        if artW > cw then
            artW = cw
            artH = math.floor(artW / WAIFU_RATIO)
        end
        D.waifu.Visible = Win.visible and Cfg.preset == "Waifu"
        D.waifu.Position = Vector2.new(cx + math.floor((cw - artW) / 2), y + TB + 2)
        D.waifu.Size = Vector2.new(artW, artH)
    end
    local page = Pages[activeTab]

    if not page then
        D.pageTxt.Position = Vector2.new(cx, y + TB + 20)
        D.pageTxt.Text = truncate(Tabs[activeTab].name .. " page -- components arrive soon", cw)
        D.sbTrack.Visible = false
        D.sbThumb.Visible = false
    else
        D.pageTxt.Text = ""
        local visTop = y + TB + 2
        local visBot = y + h - 6
        local viewH = visBot - visTop
        -- clamp target using last known extent, before laying out
        local preMax = page.maxScroll or 0
        if page.scrollY < 0 then page.scrollY = 0 end
        if page.scrollY > preMax then page.scrollY = preMax end
        local startY = y + TB + 16 - page.scrollCur
        local colGap = 12
        local colW = math.floor((cw - colGap) / 2)
        local colX = { left = cx, right = cx + colW + colGap }
        local colY = { left = startY, right = startY }

        for _, sec in ipairs(page.sections) do
            local sx = colX[sec.side] or cx
            local sy = colY[sec.side] or startY
            local swid = colW

            local hdrVis = sy >= visTop - 2 and sy <= visBot - 12
            sec.hdr.Visible = Win.visible and hdrVis
            sec.hdr.Position = Vector2.new(sx + 2, sy)
            sec.hdr.Color = Theme.Header
            sec.hdr.Text = truncate(sec.title, swid - 4)
            local hlx = sx + 2 + #sec.hdr.Text * CHAR_W + 6
            layoutFade(sec.hsegs, math.min(hlx, sx + swid), sx + swid, sy + 7, "left", 0.55, Win.visible and hdrVis)

            local py = sy + 18
            local innerX = sx + 12
            local innerW = swid - 24

            local totalH = 8
            for _, row in ipairs(sec.rows) do totalH = totalH + rowEffH(row) end
            local panelH = totalH + 6
            local pTop = math.max(py, visTop)
            local pBot = math.min(py + panelH, visBot)
            local panelShown = pBot - pTop > 3
            sec.vis = panelShown
            sec.panel.Visible = Win.visible and panelShown
            sec.glow.Visible = false
            if panelShown then
                sec.panel.Position = Vector2.new(sx, pTop)
                sec.panel.Size = Vector2.new(swid, pBot - pTop)
                sec.panel.Corner = CR(6)
                sec.glow.Position = Vector2.new(sx - 1, pTop - 1)
                sec.glow.Size = Vector2.new(swid + 2, pBot - pTop + 2)
                sec.glow.Corner = CR(6)
            end
            sec.rect = { x = sx, y = pTop, w = swid, h = math.max(0, pBot - pTop) }

            local ry = py + 8
            for _, row in ipairs(sec.rows) do
                -- render any row that overlaps the viewport at full opacity; the clip pass
                -- (clipRows, run each frame) trims each object to the exact viewport edge so the
                -- part outside is invisible and the part inside stays crisp, revealed pixel by pixel.
                -- lay out (and keep Visible) a generous margin past the edge so nothing toggles
                -- Visible right at the boundary; clipRows does the exact hide/fade -> no 3px pop.
                local rvis = (ry + row.h > visTop) and (ry < visBot)
                local shownEnough = (row.showT == nil) or (row.showT > 0.02)
                local rlive = shownEnough and (ry + row.h > visTop - 60) and (ry < visBot + 60)
                row.vis = rvis and shownEnough
                row.live = rlive
                row.rect = { x = sx, y = ry, w = swid, h = row.h }
                for _, o in ipairs(rowObjs(row)) do
                    o.Visible = Win.visible and rlive
                    o.Transparency = (Bases[o] or 1) * Cfg.opacity
                end
                if rlive then
                    if row.kind == "toggle" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        row.lbl.Text = truncate(row.label, innerW - 44)
                        if Cfg.checkbox then
                            row.track.Size = Vector2.new(18, 18)
                            row.track.Corner = CR(3)
                            row.track.Position = Vector2.new(sx + swid - 12 - 18, ry + 8)
                            row.trackX = sx + swid - 12 - 18
                            row.oline.Size = Vector2.new(18, 18)
                            row.oline.Corner = CR(3)
                            row.oline.Position = Vector2.new(sx + swid - 12 - 18, ry + 8)
                            row.knob.Size = Vector2.new(8, 8)
                            row.knob.Corner = CR(2)
                        else
                            row.track.Size = Vector2.new(34, 18)
                            row.track.Corner = CR(6)
                            row.track.Position = Vector2.new(sx + swid - 12 - 34, ry + 8)
                            row.trackX = sx + swid - 12 - 34
                            row.oline.Size = Vector2.new(34, 18)
                            row.oline.Corner = CR(6)
                            row.oline.Position = Vector2.new(sx + swid - 12 - 34, ry + 8)
                            row.knob.Size = Vector2.new(14, 14)
                            row.knob.Corner = CR(5)
                        end
                        row.trackY = ry + 8
                    elseif row.kind == "slider" then
                        row.lbl.Position = Vector2.new(innerX, ry + 6)
                        row.lbl.Text = truncate(row.label, innerW - 62)
                        row.chip.Position = Vector2.new(sx + swid - 12 - 52, ry + 4)
                        row.chip.Corner = CR(3)
                        row.chipRect = { x = sx + swid - 12 - 52, y = ry + 4, w = 52, h = 17 }
                        row.chipT.Position = Vector2.new(sx + swid - 12 - 26, ry + 6)
                        row.barX = innerX
                        row.barY = ry + 28
                        row.barW = innerW
                        row.track.Position = Vector2.new(row.barX, row.barY)
                        row.track.Size = Vector2.new(row.barW, 3)
                    elseif row.kind == "button" then
                        row.box.Position = Vector2.new(innerX, ry + 4)
                        row.box.Size = Vector2.new(innerW, row.h - 8)
                        row.box.Corner = CR(4)
                        row.oline.Position = Vector2.new(innerX, ry + 4)
                        row.oline.Size = Vector2.new(innerW, row.h - 8)
                        row.oline.Corner = CR(4)
                        local btxt = truncate(row.label, innerW - 8)
                        row.lbl.Text = btxt
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - #btxt * CHAR_W) / 2), ry + 5 + math.floor((row.h - 8 - FS) / 2))
                    elseif row.kind == "buttonrow" then
                        local n = #row.defs
                        local gap = 8
                        local bw = math.floor((innerW - gap * (n - 1)) / n)
                        row.bw = bw
                        for i = 1, n do
                            local bx = innerX + (i - 1) * (bw + gap)
                            row.boxes[i].Position = Vector2.new(bx, ry + 4)
                            row.boxes[i].Size = Vector2.new(bw, row.h - 8)
                            row.boxes[i].Corner = CR(4)
                            row.olines[i].Position = Vector2.new(bx, ry + 4)
                            row.olines[i].Size = Vector2.new(bw, row.h - 8)
                            row.olines[i].Corner = CR(4)
                            local bt = truncate(row.defs[i].label, bw - 6)
                            row.lbls[i].Text = bt
                            row.lbls[i].Position = Vector2.new(bx + math.floor((bw - #bt * CHAR_W) / 2), ry + 5 + math.floor((row.h - 8 - FS) / 2))
                        end
                    elseif row.kind == "dropdown" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        local boxW = math.max(90, math.floor(innerW * 0.45))
                        row.boxW = boxW
                        row.lbl.Text = truncate(row.label, innerW - boxW - 10)
                        row.box.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.box.Size = Vector2.new(boxW, 22)
                        row.box.Corner = CR(4)
                        row.oline.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.oline.Size = Vector2.new(boxW, 22)
                        row.oline.Corner = CR(4)
                        row.val.Position = Vector2.new(sx + swid - 12 - boxW + 8, ry + 10)
                        row.val.Text = truncate(tostring(row.value), boxW - 28)
                        row.arr.Position = Vector2.new(sx + swid - 12 - 14, ry + 10)
                    elseif row.kind == "color" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        row.lbl.Text = truncate(row.label, innerW - 28)
                        row.sw.Position = Vector2.new(sx + swid - 12 - 16, ry + 9)
                        row.sw.Corner = CR(3)
                        row.sw.Color = row.color
                    elseif row.kind == "keybind" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        local kw = math.max(34, #keyName(row.vk) * CHAR_W + 14)
                        row.kw = kw
                        row.lbl.Text = truncate(row.label, innerW - kw - 10)
                        row.chip.Position = Vector2.new(sx + swid - 12 - kw, ry + 8)
                        row.chip.Size = Vector2.new(kw, 17)
                        row.chip.Corner = CR(3)
                        row.chipX = sx + swid - 12 - kw
                        row.chipY = ry + 8
                    elseif row.kind == "textbox" then
                        row.lbl.Position = Vector2.new(innerX, ry + 3)
                        row.lbl.Text = truncate(row.label, innerW)
                        row.box.Position = Vector2.new(innerX, ry + 18)
                        row.box.Size = Vector2.new(innerW, 24)
                        row.box.Corner = CR(4)
                        row.oline.Position = Vector2.new(innerX, ry + 18)
                        row.oline.Size = Vector2.new(innerW, 24)
                        row.oline.Corner = CR(4)
                        row.txt.Position = Vector2.new(innerX + 8, ry + 23)
                    elseif row.kind == "divider" then
                        local dtxt = truncate(row.label, innerW - 60)
                        row.lbl.Text = dtxt
                        local tw = #dtxt * CHAR_W
                        local mid = innerX + innerW / 2
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - tw) / 2), ry + 6)
                        local gap = 8
                        layoutFade(row.segsL, innerX, mid - tw / 2 - gap, ry + 12, "right", 0.5, Win.visible and rvis)
                        layoutFade(row.segsR, mid + tw / 2 + gap, innerX + innerW, ry + 12, "left", 0.5, Win.visible and rvis)
                    elseif row.kind == "note" then
                        row.lbl.Position = Vector2.new(innerX, ry + 5)
                        row.lbl.Text = truncate(row.label, innerW)
                    end
                end
                ry = ry + rowEffH(row)
            end
            colY[sec.side] = ry + 18
        end

        -- scroll bookkeeping
        local contentH = math.max(colY.left, colY.right) - startY
        page.contentH = contentH
        UI.viewH = viewH
        local maxScroll = math.max(0, contentH - viewH + 14)
        page.maxScroll = maxScroll
        if page.scrollY > maxScroll then page.scrollY = maxScroll end
        if page.scrollY < 0 then page.scrollY = 0 end

        -- scrollbar
        if contentH > viewH then
            local trackX = x + w - 7
            local trackY = visTop + 2
            local trackH = viewH - 4
            local thumbH = math.max(24, math.floor(trackH * viewH / contentH))
            local tRange = trackH - thumbH
            local tY = trackY + (maxScroll > 0 and (math.max(0, math.min(maxScroll, page.scrollCur)) / maxScroll) * tRange or 0)
            D.sbTrack.Visible = Win.visible
            D.sbTrack.Position = Vector2.new(trackX + 1, trackY)
            D.sbTrack.Size = Vector2.new(2, trackH)
            D.sbThumb.Visible = Win.visible
            D.sbThumb.Position = Vector2.new(trackX + 1, tY)
            D.sbThumb.Size = Vector2.new(2, thumbH)
            D.sbThumb.Color = Theme.Track
            UI.sbRect = { x = trackX - 3, y = trackY, w = 10, h = trackH, thumbH = thumbH, maxScroll = maxScroll }
        else
            D.sbTrack.Visible = false
            D.sbThumb.Visible = false
            for i = 1, #D.sbGlowSegs do D.sbGlowSegs[i].Visible = false end
            UI.sbRect = nil
        end
    end

    -- popouts follow anchors (close if anchor culled)
    if Drop.open and (not Drop.open.vis) then hardCloseDropdown() end
    if Pick.open and (not Pick.open.vis) then closePicker() end

    if Drop.open and Drop.open.rect then
        local row = Drop.open
        local bw = row.boxW or 100
        local bx = row.rect.x + row.rect.w - 12 - bw
        local by = row.rect.y + 30
        local filtered = dropFiltered()
        local total = #filtered
        local visN = math.min(total, MAXOPT)
        local maxSc = math.max(0, total - MAXOPT)
        if Drop.scroll > maxSc then Drop.scroll = maxSc end
        if Drop.scroll < 0 then Drop.scroll = 0 end
        Drop.bg.Visible = true
        Drop.bg.Color = Theme.Dark
        Drop.searchBox.Color = Theme.Control
        Drop.bg.Position = Vector2.new(bx, by)
        Drop.bg.Size = Vector2.new(bw, 28 + visN * 24 + 6)
        Drop.bg.Corner = CR(5)
        Drop.searchBox.Visible = true
        Drop.searchBox.Position = Vector2.new(bx + 4, by + 4)
        Drop.searchBox.Size = Vector2.new(bw - 8, 20)
        Drop.searchBox.Corner = CR(4)
        Drop.searchTxt.Visible = true
        Drop.searchTxt.Position = Vector2.new(bx + 10, by + 8)
        Drop.searchTxt.Text = truncate((#Drop.searchBuf > 0 and Drop.searchBuf or "Search") .. "_", bw - 24)
        Drop.searchTxt.Color = #Drop.searchBuf > 0 and Theme.Text or Theme.Dim
        local oy = by + 28
        for i = 1, MAXOPT do
            local r = Drop.rows[i]
            local idx = i + Drop.scroll
            if i <= visN and filtered[idx] then
                r.bg.Position = Vector2.new(bx + 4, oy + (i - 1) * 24)
                r.bg.Size = Vector2.new(bw - 8 - (total > MAXOPT and 6 or 0), 22)
                r.bg.Corner = CR(4)
                r.bg.Visible = true
                r.txt.Position = Vector2.new(bx + 12, oy + 4 + (i - 1) * 24)
                r.txt.Text = truncate(filtered[idx], bw - 44)
                r.txt.Visible = true
                r.chk.Position = Vector2.new(bx + bw - 18 - (total > MAXOPT and 6 or 0), oy + 4 + (i - 1) * 24)
                r.chk.Visible = filtered[idx] == tostring(row.value)
                r.chk.Color = Theme.C1
            else
                r.bg.Visible = false
                r.txt.Visible = false
                r.chk.Visible = false
            end
        end
        if total > MAXOPT then
            local listH = visN * 24
            local thH = math.max(16, math.floor(listH * MAXOPT / total))
            local thY = oy + (maxSc > 0 and (Drop.scroll / maxSc) * (listH - thH) or 0)
            Drop.sbT.Visible = true
            Drop.sbT.Position = Vector2.new(bx + bw - 7, thY)
            Drop.sbT.Size = Vector2.new(4, thH)
            Drop.sbT.Color = lerpColor(Theme.Track, Theme.C1, 0.4)
            Drop.dropSb = { x = bx + bw - 10, y = oy, w = 10, h = listH, thH = thH, maxSc = maxSc }
        else
            Drop.sbT.Visible = false
            Drop.dropSb = nil
        end
        Drop.geom = { bx = bx, by = by, bw = bw, oy = oy, visN = visN }

        -- open/close transform: slide down from a few px up + fade the whole popout in/out.
        -- the list also collapses toward the top (bg height scales) so rows fold into nothing.
        local aT = Drop.animT or 1
        aT = aT * aT * (3 - 2 * aT)
        if aT < 0.999 then
            local yoff = (1 - aT) * -12
            local baseY = by
            local applyAnim = function(o)
                if not o or not o.Visible then return end
                o.Position = Vector2.new(o.Position.X, o.Position.Y + yoff)
                o.Transparency = o.Transparency * aT
            end
            -- collapse the list height; rows past the shrinking edge fold away
            local fullH = Drop.bg.Size.Y
            local collapsedH = math.max(6, fullH * (0.25 + 0.75 * aT))
            for i = 1, MAXOPT do
                local r = Drop.rows[i]
                if r.bg.Visible and (r.bg.Position.Y + r.bg.Size.Y) > (baseY + collapsedH) then
                    r.bg.Visible = false r.txt.Visible = false r.chk.Visible = false
                end
            end
            applyAnim(Drop.bg)
            Drop.bg.Size = Vector2.new(Drop.bg.Size.X, collapsedH)
            applyAnim(Drop.searchBox)
            applyAnim(Drop.searchTxt)
            applyAnim(Drop.sbT)
            for i = 1, MAXOPT do
                applyAnim(Drop.rows[i].bg)
                applyAnim(Drop.rows[i].txt)
                applyAnim(Drop.rows[i].chk)
            end
        end
    end

    if Pick.open and Pick.open.rect then
        local row = Pick.open
        local pw = SV_COLS * SV_CELL + 24
        local ph = SV_ROWS * SV_CELL + 24 + 20 + 32
        local px = row.rect.x + row.rect.w - pw - 4
        local pyy = math.min(row.rect.y + 30, Win.y + Win.h - ph - 6)
        Pick.bg.Position = Vector2.new(px, pyy)
        Pick.bg.Size = Vector2.new(pw, ph)
        Pick.bg.Corner = CR(6)
        Pick.gx = px + 12
        Pick.gy = pyy + 12
        for r = 1, SV_ROWS do
            local yA = math.floor(Pick.gy + (r - 1) * SV_CELL)
            local yB = math.floor(Pick.gy + r * SV_CELL)
            local hgt = math.max(1, yB - yA + 1)
            for c = 1, SV_COLS do
                local xA = math.floor(Pick.gx + (c - 1) * SV_CELL)
                local xB = math.floor(Pick.gx + c * SV_CELL)
                local cell = Pick.sv[r][c]
                cell.Position = Vector2.new(xA, yA)
                cell.Size = Vector2.new(math.max(1, xB - xA + 1), hgt)
                cell.Color = hsv2rgb(Pick.h, (c - 1) / (SV_COLS - 1), 1 - (r - 1) / (SV_ROWS - 1))
            end
        end
        local gridW = SV_COLS * SV_CELL
        Pick.svCur.Position = Vector2.new(Pick.gx + Pick.s * gridW - 4, Pick.gy + (1 - Pick.v) * (SV_ROWS * SV_CELL) - 4)
        Pick.hy = Pick.gy + SV_ROWS * SV_CELL + 8
        local hw = gridW / HUE_SEGS
        for i = 1, HUE_SEGS do
            local xA = math.floor(Pick.gx + (i - 1) * hw)
            local xB = math.floor(Pick.gx + i * hw)
            Pick.hueSegs[i].Position = Vector2.new(xA, Pick.hy)
            Pick.hueSegs[i].Size = Vector2.new(math.max(1, xB - xA + 1), 12)
            Pick.hueSegs[i].Color = hsv2rgb((i - 1) / (HUE_SEGS - 1), 0.92, 0.95)
        end
        Pick.hueCur.Position = Vector2.new(Pick.gx + Pick.h * gridW - 2, Pick.hy - 2)
        Pick.hueCur.Size = Vector2.new(5, 16)
        local rowY = Pick.hy + 20
        Pick.prev.Position = Vector2.new(Pick.gx, rowY)
        Pick.prev.Size = Vector2.new(30, 20)
        Pick.prev.Corner = CR(3)
        Pick.prev.Color = pickerColor()
        Pick.hexBox.Position = Vector2.new(Pick.gx + 38, rowY)
        Pick.hexBox.Size = Vector2.new(gridW - 38, 20)
        Pick.hexBox.Corner = CR(3)
        Pick.hexTxt.Position = Vector2.new(Pick.gx + 46, rowY + 4)
        Pick.hexTxt.Text = Pick.hexFocus and (Pick.hexBuf .. "_") or hexOf(pickerColor())
        Pick.hexRowY = rowY
    end

    -- search results popout, anchored under the search field
    if Search.active and Search.rect and #Search.results > 0 then
        local n = #Search.results
        local rowH = 26
        local pw = math.max(Search.rect.w, 268)
        local px = Search.rect.x + Search.rect.w - pw
        local py = Search.rect.y + Search.rect.h + 4
        local ph = n * rowH + 8
        Search.bg.Visible = true
        Search.bg.Color = Theme.Dark
        Search.bg.Position = Vector2.new(px, py)
        Search.bg.Size = Vector2.new(pw, ph)
        Search.bg.Corner = CR(5)
        for i = 1, SEARCH_MAX do
            local r = Search.rows[i]
            local res = Search.results[i]
            if res then
                local ry = py + 4 + (i - 1) * rowH
                r.bg.Position = Vector2.new(px + 4, ry)
                r.bg.Size = Vector2.new(pw - 8, rowH - 2)
                r.bg.Corner = CR(4)
                r.bg.Visible = true
                local tabW = #res.tab * CHAR_W
                local tabX = px + pw - 10 - tabW
                local iconX = tabX - 6 - 13
                r.tab.Text = res.tab
                r.tab.Position = Vector2.new(tabX, ry + 5)
                r.tab.Color = Theme.Dim
                r.tab.Visible = true
                r.icon.Position = Vector2.new(iconX, ry + 5)
                r.icon.Color = Theme.C1
                r.icon.Visible = true
                r.txt.Text = truncate(res.label, (iconX - 8) - (px + 12))
                r.txt.Position = Vector2.new(px + 12, ry + 5)
                r.txt.Visible = true
            else
                r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
            end
        end
        Search.geom = { px = px, py = py, pw = pw, rowH = rowH, n = n }
    else
        Search.bg.Visible = false
        for i = 1, SEARCH_MAX do
            local r = Search.rows[i]
            r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
        end
        Search.geom = nil
    end

    Win.dirty = false
end

local function relayout()
    local ok, e = pcall(relayoutRaw)
    if not ok then print("FALUI|relayout ERROR: " .. tostring(e)) end
end

-- ========== per-frame updates ==========
local hoveredRow, hoverT = nil, 0
local navHovT, navHovIdx = 0, 0
local animClock = 0

local function hideTip()
    D.tipBox.Visible = false
    D.tipL1.Visible = false
    D.tipL2.Visible = false
    D.tipL3.Visible = false
end

local function wrapText(s, maxChars)
    local lines, cur = {}, ""
    for word in tostring(s):gmatch("%S+") do
        if #cur == 0 then cur = word
        elseif #cur + 1 + #word <= maxChars then cur = cur .. " " .. word
        else table.insert(lines, cur) cur = word if #lines >= 3 then break end end
    end
    if #cur > 0 and #lines < 3 then table.insert(lines, cur) end
    return lines
end

local function updateControls(dt, mx, my)
    animClock = animClock + dt
    local page = Pages[activeTab]
    local newHovered = nil
    local aeF = Cfg.animations and (1 - (0.000001 ^ dt)) or 1
    local blockRows = Drop.open ~= nil or Pick.open ~= nil
    if page then
        for _, sec in ipairs(page.sections) do
            -- animate conditional rows (show/hide slider) -> drives fade + smooth card resize
            for _, row in ipairs(sec.rows) do
                if row.showIf then
                    local target = (Cfg.preset == row.showIf) and 1 or 0
                    if row.showT ~= target then
                        row.showT = row.showT + (target - row.showT) * aeF
                        if math.abs(row.showT - target) < 0.004 then row.showT = target end
                        Win.dirty = true
                    end
                end
            end
            local secHov = Cfg.hoverFx and not blockRows and sec.vis and sec.rect and inRect(mx, my, sec.rect.x, sec.rect.y, sec.rect.w, sec.rect.h) and mx > (Win.x + Sb.cur)
            sec.hovT = sec.hovT + ((secHov and 1 or 0) - sec.hovT) * aeF
            sec.panel.Color = lerpColor(Theme.Panel, Theme.PanelHov, sec.hovT)
            local glowA = math.min(1, 0.16 + (0.10 * Cfg.cardGlow / 100) + 0.5 * sec.hovT) * Cfg.opacity
            sec.glow.Color = Theme.C1
            sec.glow.Transparency = glowA
            sec.glow.Visible = Win.visible and sec.vis and glowA > 0.03
            for _, row in ipairs(sec.rows) do
                if row.vis then
                    local r = row.rect
                    local hov = not blockRows and r and inRect(mx, my, r.x, r.y, r.w, r.h) and mx > (Win.x + Sb.cur)
                    local hovTarget = (Cfg.hoverFx and hov) and 1 or 0
                    row.hovT = row.hovT + (hovTarget - row.hovT) * aeF
                    if hov and row.tip then newHovered = row end
                    if row.kind == "toggle" then
                        local target = row.value and 1 or 0
                        row.knobT = row.knobT + (target - row.knobT) * aeF
                        if math.abs(row.knobT - target) < 0.01 then row.knobT = target end
                        local baseTrack = lerpColor(Theme.Track, Theme.C1, row.knobT)
                        if Cfg.checkbox then
                            row.knob.Position = Vector2.new(row.trackX + 5, row.trackY + 5)
                            row.knob.Visible = Win.visible and row.vis and row.knobT > 0.1
                        else
                            row.knob.Visible = Win.visible and row.vis
                            row.knob.Position = Vector2.new(row.trackX + 2 + row.knobT * (34 - 4 - 14), row.trackY + 2)
                        end
                        row.track.Color = lerpColor(baseTrack, Theme.White, 0.10 * row.hovT)
                        row.oline.Color = lerpColor(Theme.Track, Theme.C1, row.hovT)
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                    elseif row.kind == "slider" then
                        local t = (row.value - row.min) / (row.max - row.min)
                        local fw = row.barW * t
                        local segW = fw / GRAD_SEGS
                        for i = 1, GRAD_SEGS do
                            local seg = row.segs[i]
                            if segW > 0.5 then
                                seg.Visible = Win.visible
                                seg.Position = Vector2.new(row.barX + (i - 1) * segW, row.barY)
                                seg.Size = Vector2.new(math.max(1, math.ceil(segW)), 3)
                                seg.Color = lerpColor(Theme.C1, Theme.C2, (i - 1) / math.max(1, GRAD_SEGS - 1))
                            else
                                seg.Visible = false
                            end
                        end
                        row.knob.Position = Vector2.new(row.barX + fw, row.barY + 1)
                        row.knobX = row.barX + fw
                        if Focus.row == row then
                            row.chipT.Text = (row.buf or "") .. "_"
                        else
                            row.chipT.Text = tostring(math.floor(row.value + 0.5)) .. row.suffix
                        end
                        if row.chipRect then
                            row.chipT.Position = Vector2.new(row.chipRect.x + math.floor((row.chipRect.w - #row.chipT.Text * (CHAR_W - 1)) / 2), row.chipRect.y + 2)
                        end
                        row.chip.Color = Theme.Control
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                    elseif row.kind == "button" then
                        row.box.Color = lerpColor(Theme.Control, lerpColor(Theme.Control, Theme.White, 0.12), row.hovT)
                        row.oline.Color = lerpColor(Theme.Track, Theme.C1, row.hovT)
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                    elseif row.kind == "buttonrow" then
                        for i = 1, #row.defs do
                            local bw = row.bw or 60
                            local bx = row.rect.x + 12 + (i - 1) * (bw + 8)
                            local bHov = not blockRows and inRect(mx, my, bx, row.rect.y + 4, bw, row.h - 8)
                            row.hovTs[i] = row.hovTs[i] + (((Cfg.hoverFx and bHov) and 1 or 0) - row.hovTs[i]) * aeF
                            row.boxes[i].Color = lerpColor(Theme.Control, lerpColor(Theme.Control, Theme.White, 0.12), row.hovTs[i])
                            row.olines[i].Color = lerpColor(Theme.Track, Theme.C1, row.hovTs[i])
                            row.lbls[i].Color = lerpColor(Theme.Text, Theme.White, row.hovTs[i])
                        end
                    elseif row.kind == "dropdown" then
                        row.box.Color = lerpColor(Theme.Control, lerpColor(Theme.Control, Theme.White, 0.12), row.hovT)
                        row.oline.Color = lerpColor(Theme.Track, Theme.C1, row.hovT)
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                    elseif row.kind == "color" then
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                        row.sw.Color = row.color
                    elseif row.kind == "keybind" then
                        row.lbl.Color = lerpColor(Theme.Text, Theme.White, row.hovT)
                        row.chipT.Text = (Capture.row == row) and "..." or keyName(row.vk)
                        if row.chipX then
                            row.chipT.Position = Vector2.new(row.chipX + math.floor(((row.kw or 34) - #row.chipT.Text * (CHAR_W - 1)) / 2), row.chipY + 2)
                        end
                        row.chip.Color = (Capture.row == row) and lerpColor(Theme.Control, Theme.C1, 0.3) or Theme.Control
                    elseif row.kind == "textbox" then
                        row.box.Color = (Focus.row == row) and lerpColor(Theme.Control, Theme.White, 0.08) or Theme.Control
                        row.oline.Color = (Focus.row == row) and Theme.C1 or lerpColor(Theme.Track, Theme.C1, row.hovT)
                        row.txt.Text = truncate(row.value .. ((Focus.row == row) and "_" or ""), (row.rect.w - 24 - 16))
                    end
                end
            end
        end
    end

    if Drop.open and Drop.geom then
        local g = Drop.geom
        for i = 1, g.visN do
            local hov = inRect(mx, my, g.bx + 4, g.oy + (i - 1) * 24, g.bw - 8, 22)
            Drop.hovT[i] = Drop.hovT[i] + (((Cfg.hoverFx and hov) and 1 or 0) - Drop.hovT[i]) * aeF
            Drop.rows[i].bg.Transparency = 0.85 * Drop.hovT[i] * Cfg.opacity
            Drop.rows[i].txt.Color = lerpColor(Theme.Text, Theme.White, Drop.hovT[i])
        end
    end

    if Search.active and Search.geom then
        local g = Search.geom
        for i = 1, g.n do
            local r = Search.rows[i]
            local hov = inRect(mx, my, g.px + 4, g.py + 4 + (i - 1) * g.rowH, g.pw - 8, g.rowH - 2)
            Search.hovT[i] = Search.hovT[i] + (((Cfg.hoverFx and hov) and 1 or 0) - Search.hovT[i]) * aeF
            r.bg.Transparency = 0.85 * Search.hovT[i] * Cfg.opacity
            r.txt.Color = lerpColor(Theme.Text, Theme.White, Search.hovT[i])
        end
    end

    -- sidebar item hover (softer fill, img4 bottom)
    do
        local hitIdx = 0
        local iy = itemsTop()
        if mx > Win.x and mx < Win.x + Sb.cur and not blockRows then
            for i = 1, #Tabs do
                if inRect(mx, my, Win.x, iy + (i - 1) * ITEM_H, Sb.cur, ITEM_H) then hitIdx = i break end
            end
        end
        if hitIdx ~= 0 and hitIdx ~= activeTab then navHovIdx = hitIdx end
        local want = (hitIdx ~= 0 and hitIdx ~= activeTab and Cfg.hoverFx) and 1 or 0
        navHovT = navHovT + (want - navHovT) * aeF
        if navHovIdx ~= 0 and navHovT > 0.02 and Win.visible then
            D.navHover.Visible = true
            D.navHover.Position = Vector2.new(Win.x + 6, iy + (navHovIdx - 1) * ITEM_H + 2)
            D.navHover.Size = Vector2.new(math.max(8, Sb.cur - 12), ITEM_H - 8)
            D.navHover.Corner = CR(6)
            D.navHover.Color = lerpColor(Theme.Panel, Theme.PanelHov, navHovT)
            D.navHover.Transparency = (0.72 - 0.35 * navHovT) * Cfg.opacity
        else
            D.navHover.Visible = false
        end
    end

    if newHovered ~= hoveredRow then
        hoveredRow = newHovered
        hoverT = 0
        hideTip()
    elseif hoveredRow and hoveredRow.tip then
        hoverT = hoverT + dt
        if hoverT > 0.4 then
            local lines = wrapText(hoveredRow.tip, 30)
            local maxLen = 0
            for _, l in ipairs(lines) do maxLen = math.max(maxLen, #l) end
            local tw = maxLen * CHAR_W + 16
            local th = #lines * 15 + 10
            local tx = mx + 14
            local ty = my + 18
            if tx + tw > Win.x + Win.w then tx = mx - tw - 6 end
            D.tipBox.Position = Vector2.new(tx, ty)
            D.tipBox.Size = Vector2.new(tw, th)
            D.tipBox.Color = Theme.Control
            D.tipBox.Visible = true
            local ls = { D.tipL1, D.tipL2, D.tipL3 }
            for i = 1, 3 do
                ls[i].Text = lines[i] or ""
                ls[i].Position = Vector2.new(tx + 8, ty + 5 + (i - 1) * 15)
                ls[i].Visible = lines[i] ~= nil
            end
        end
    end
end

-- ========== visibility ==========
local function setVisible(v)
    Win.visible = v
    for _, o in pairs(D) do
        if isDGroup(o) then
            for _, s in ipairs(o) do s.Visible = false end
        else
            o.Visible = v
        end
    end
    for _, it in ipairs(Items) do
        it.icon.Visible = v
        it.label.Visible = v
    end
    for idx = 1, SETTINGS_TAB do setPageVisible(idx, false) end
    if v then setPageVisible(activeTab, true) end
    hardCloseDropdown()
    closePicker()
    closeSearch()
    hideTip()
    Capture.row = nil
    Focus.row = nil
    if not v then
        for _, f in ipairs(Snow.flakes) do f.obj.Visible = false end
        Snow.hidden = true
    end
    if v then
        D.gear.Visible = false
        D.verTag.Visible = false
        D.search.Visible = false
        D.searchT.Visible = false
        D.sbTrack.Visible = false
        D.sbThumb.Visible = false
        for i = 1, #D.sbGlowSegs do D.sbGlowSegs[i].Visible = false end
        D.navHover.Visible = false
        Win.dirty = true
    end
    pcall(setrobloxinput, not v)
end

for _, sec in ipairs(Pages[SETTINGS_TAB].sections) do
    for _, row in ipairs(sec.rows) do
        if row.kind == "button" and row.label == "Minimize" then
            row.onClick = function() setVisible(false) end
        end
    end
end

local function switchTab(i)
    if i == activeTab then return end
    setPageVisible(activeTab, false)
    activeTab = i
    setPageVisible(activeTab, true)
    hideTip()
    Win.dirty = true
end

-- ========== search logic ==========
local SEARCHABLE = { toggle = true, slider = true, dropdown = true, button = true, color = true, keybind = true, textbox = true }
-- score: lower is better. exact-ish substring beats a fuzzy subsequence match; earlier match wins.
local function searchScore(label, q)
    if q == "" then return nil end
    local L = label:lower()
    local s = L:find(q, 1, true)
    if s then return (s - 1) + math.abs(#L - #q) * 0.05 end
    local qi, li, first, last, gaps = 1, 1, nil, nil, 0
    while qi <= #q and li <= #L do
        if L:sub(li, li) == q:sub(qi, qi) then
            if not first then first = li end
            if last then gaps = gaps + (li - last - 1) end
            last = li qi = qi + 1
        end
        li = li + 1
    end
    if qi > #q then return 200 + (first or 0) + gaps end
    return nil
end

local function tabNameOf(idx)
    if idx == SETTINGS_TAB then return "Settings" end
    return (Tabs[idx] and Tabs[idx].name) or ("Tab " .. idx)
end

local function buildSearch()
    local q = Search.buf:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local scored = {}
    if q ~= "" then
        for idx = 1, SETTINGS_TAB do
            local page = Pages[idx]
            if page then
                for _, sec in ipairs(page.sections) do
                    for _, row in ipairs(sec.rows) do
                        if SEARCHABLE[row.kind] and type(row.label) == "string" and #row.label > 0 then
                            local sc = searchScore(row.label, q)
                            if sc then
                                table.insert(scored, { label = row.label, tabIdx = idx, tab = tabNameOf(idx), row = row, sec = sec, score = sc })
                            end
                        end
                    end
                end
            end
        end
        table.sort(scored, function(a, b)
            if a.score == b.score then return a.label < b.label end
            return a.score < b.score
        end)
    end
    Search.results = {}
    for i = 1, math.min(SEARCH_MAX, #scored) do Search.results[i] = scored[i] end
end

local function gotoResult(res)
    if not res then return end
    switchTab(res.tabIdx)
    Search.focus = res              -- one-shot: scroll the row into view once it's laid out
    closeSearch()
    Win.dirty = true
end

-- ========== typing ==========
local function edgeKey(vk)
    local down = iskeypressed(vk)
    local was = keyStates[vk]
    keyStates[vk] = down
    return down and not was
end

local function pollTyping(applyChar, applyBksp, applyDone)
    local shift = iskeypressed(0x10)
    if edgeKey(0x08) then applyBksp() end
    if edgeKey(0x0D) or edgeKey(0x1B) then applyDone() return end
    if edgeKey(0x20) then applyChar(" ") end
    for vk = 0x30, 0x39 do
        if edgeKey(vk) then applyChar(string.char(vk)) end
    end
    for vk = 0x41, 0x5A do
        if edgeKey(vk) then
            local ch = string.char(vk)
            if not shift then ch = ch:lower() end
            applyChar(ch)
        end
    end
    if edgeKey(0xBD) then applyChar(shift and "_" or "-") end
    if edgeKey(0xBE) then applyChar(".") end
    if edgeKey(0xDE) or edgeKey(0xBF) then applyChar("#") end
end

-- where autosave (and save-on-unload) writes:
--   1. the config currently selected in the "Config" dropdown, if any
--   2. otherwise the auto-load config, if one is set
--   3. otherwise the default settings.json
local function saveTargetPath()
    -- live dropdown values are the source of truth; both "none" -> default settings.json
    local sel = rConfigDrop and rConfigDrop.value
    if sel and sel ~= "" and sel ~= "none" then
        return cfgDir() .. "/" .. sel .. ".json"
    end
    local al = rAutoLoad and rAutoLoad.value
    if al and al ~= "" and al ~= "none" then
        return cfgDir() .. "/" .. al .. ".json"
    end
    return FOLDER .. "/settings.json"
end

local function saveSettings()
    ensureCfgDir()
    pcall(writefile, saveTargetPath(), snapshot())
end

-- ========== main loop ==========
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local mouse = Players.LocalPlayer:GetMouse()

local In = { x = 0, y = 0, down = false, wasDown = false, pressed = false, released = false }
local Drag = { mode = nil, ox = 0, oy = 0, row = nil, sy = 0, startScroll = 0, pendIdx = 0, startDropScroll = 0 }
local scrollGlowT = 0
local dropGlowT = 0
local wheelPulse = 0
local keyWas = false
local errCount = 0
local lastClock = os.clock()
local runT = 0
local saveTimer = 0

local function curPage() return Pages[activeTab] end

local function doScroll(d)
    local page = curPage()
    if page and Win.visible then
        page.scrollY = math.max(0, math.min((page.maxScroll or 0), page.scrollY + d))
        wheelPulse = 0.45
        Win.dirty = true
    end
end

pcall(function() table.insert(UI.WheelConns, mouse.WheelForward:Connect(function() doScroll(-34) end)) end)
pcall(function() table.insert(UI.WheelConns, mouse.WheelBackward:Connect(function() doScroll(34) end)) end)
pcall(function()
    local uis = game:GetService("UserInputService")
    table.insert(UI.WheelConns, uis.InputChanged:Connect(function(io)
        pcall(function()
            if tostring(io.UserInputType):find("MouseWheel") then
                local z = io.Position.Z
                if z ~= 0 then doScroll(z > 0 and -34 or 34) end
            end
        end)
    end))
end)

local function sliderFromMouse(row)
    local t = math.max(0, math.min(1, (In.x - row.barX) / row.barW))
    local v = math.floor(row.min + t * (row.max - row.min) + 0.5)
    if v ~= row.value then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
        if row.flag then markChanged() end
    end
end

-- trim one object to the vertical viewport [top,bot]. rectangles are physically cut (position
-- + height shrunk, rounding preserved) so the part outside the UI is truly gone; glyphs/knobs
-- can't be cut, so they fade by the fraction inside. `mul` is an extra alpha (row show/hide fade).
local function clipObj(o, top, bot, mul)
    if not o or not o.Visible then return end
    mul = mul or 1
    local s = Shapes[o]
    if s == "Square" then
        local p, sz = o.Position, o.Size
        local y0, y1 = p.Y, p.Y + sz.Y
        if y1 <= top or y0 >= bot then o.Visible = false return end
        local ny0, ny1 = math.max(y0, top), math.min(y1, bot)
        if ny0 > y0 or ny1 < y1 then
            o.Position = Vector2.new(p.X, ny0)
            o.Size = Vector2.new(sz.X, ny1 - ny0)
        end
        o.Transparency = (Bases[o] or 1) * Cfg.opacity * mul
    elseif s == "Text" then
        local p = o.Position
        local hgt = tonumber(o.Size) or FS
        local vis = math.min(p.Y + hgt, bot) - math.max(p.Y, top)
        if vis <= 0 then o.Visible = false return end
        local frac = math.max(0, math.min(1, vis / hgt))
        o.Transparency = (Bases[o] or 1) * Cfg.opacity * frac * mul
    elseif s == "Circle" then
        local p = o.Position
        local r = tonumber(o.Radius) or 5
        local vis = math.min(p.Y + r, bot) - math.max(p.Y - r, top)
        if vis <= 0 then o.Visible = false return end
        local frac = math.max(0, math.min(1, vis / (2 * r)))
        o.Transparency = (Bases[o] or 1) * Cfg.opacity * frac * mul
    end
end

local function clipRows()
    local page = Pages[activeTab]
    if not page or not Win.visible then return end
    local top = Win.y + TB + 2
    local bot = Win.y + Win.h - 6
    for _, sec in ipairs(page.sections) do
        clipObj(sec.hdr, top, bot)
        for _, row in ipairs(sec.rows) do
            if row.live then
                local mul = row.showT ~= nil and (row.showT * row.showT * (3 - 2 * row.showT)) or 1
                for _, o in ipairs(rowObjs(row)) do clipObj(o, top, bot, mul) end
            end
        end
    end
end

local function frame()
    local now = os.clock()
    local dt = math.min(now - lastClock, 0.1)
    lastClock = now
    runT = runT + dt

    In.x, In.y = mouse.X, mouse.Y
    In.wasDown = In.down
    In.down = ismouse1pressed()
    In.pressed = In.down and not In.wasDown
    In.released = (not In.down) and In.wasDown

    if UI.created and not Capture.row and not Focus.row and not Pick.hexFocus and not Drop.open and not Search.active then
        local k = iskeypressed(Cfg.menuKey)
        if k and not keyWas then setVisible(not Win.visible) end
        keyWas = k
    end

    updateSnow(dt, runT)

    if not Win.visible then return end

    local x, y, w, h = Win.x, Win.y, Win.w, Win.h
    Sb.max = math.max(140, math.min(380, math.floor(w * 0.29)))

    if Cfg.preset == "Rainbow" then
        hue = (hue + dt * (Cfg.rainbowSpeed / 100) * 0.15) % 1
        Theme.C1 = hsv2rgb(hue, 0.5, 0.85)
        Theme.C2 = hsv2rgb((hue + 0.08) % 1, 0.55, 0.9)
        Theme.Dark = hsv2rgb(hue, 0.55, 0.32)   -- sidebar + topbar cycle too; light Mono bg stays
        Win.dirty = true
    end

    -- dropdown open/close animation (slide + fade); teardown happens when the close anim finishes
    if Drop.open then
        local target = Drop.closing and 0 or 1
        local dE = Cfg.animations and (1 - (0.00003 ^ dt)) or 1
        Drop.animT = Drop.animT + (target - Drop.animT) * dE
        if Drop.closing and Drop.animT < 0.03 then
            hardCloseDropdown()
        else
            if not Drop.closing and math.abs(Drop.animT - 1) < 0.004 then Drop.animT = 1 end
            Win.dirty = true
        end
    end

    if Search.active and not Capture.row and not Focus.row and not Pick.hexFocus and not Drop.open then
        pollTyping(
            function(ch) Search.buf = Search.buf .. ch buildSearch() Win.dirty = true end,
            function() Search.buf = Search.buf:sub(1, -2) buildSearch() Win.dirty = true end,
            function()
                if Search.results[1] then gotoResult(Search.results[1]) else closeSearch() Win.dirty = true end
            end
        )
    end

    if Drop.open and not Capture.row and not Focus.row and not Pick.hexFocus then
        pollTyping(
            function(ch) Drop.searchBuf = Drop.searchBuf .. ch Drop.scroll = 0 Win.dirty = true end,
            function() Drop.searchBuf = Drop.searchBuf:sub(1, -2) Drop.scroll = 0 Win.dirty = true end,
            function()
                local f = dropFiltered()
                if #Drop.searchBuf > 0 and f[1] then
                    Drop.open.value = f[1]
                    if Drop.open.onChange then pcall(Drop.open.onChange, Drop.open.value) end
                    if Drop.open.flag then markChanged() end
                end
                closeDropdown()
                Win.dirty = true
            end
        )
    end

    if Capture.row then
        if ismouse2pressed() then
            Capture.row.vk = -2
            if Capture.row.onChange then pcall(Capture.row.onChange, -2) end
            if Capture.row.flag then markChanged() end
            Capture.row = nil
        else
            for vk = 8, 222 do
                if vk ~= 0x01 and edgeKey(vk) then
                    if vk == 0x1B then
                        Capture.row = nil
                    else
                        Capture.row.vk = vk
                        if Capture.row.onChange then pcall(Capture.row.onChange, vk) end
                        if Capture.row.flag then markChanged() end
                        Capture.row = nil
                    end
                    break
                end
            end
        end
        if In.pressed then Capture.row = nil end
        Win.dirty = true
    elseif Focus.row then
        local row = Focus.row
        if row.kind == "slider" then
            pollTyping(
                function(ch)
                    if ch:match("%d") and #(row.buf or "") < 6 then row.buf = (row.buf or "") .. ch end
                end,
                function() row.buf = (row.buf or ""):sub(1, -2) end,
                function()
                    local v = tonumber(row.buf)
                    if v then
                        v = math.floor(math.max(row.min, math.min(row.max, v)) + 0.5)
                        row.value = v
                        if row.onChange then pcall(row.onChange, v) end
                        if row.flag then markChanged() end
                    end
                    Focus.row = nil
                end
            )
            if In.pressed and row.chipRect and not inRect(In.x, In.y, row.chipRect.x, row.chipRect.y, row.chipRect.w, row.chipRect.h) then
                Focus.row = nil
            end
        else
            pollTyping(
                function(ch) row.value = row.value .. ch if row.onChange then pcall(row.onChange, row.value) end if row.flag then markChanged() end end,
                function() row.value = row.value:sub(1, -2) if row.onChange then pcall(row.onChange, row.value) end if row.flag then markChanged() end end,
                function() Focus.row = nil end
            )
            if In.pressed and row.rect and not inRect(In.x, In.y, row.rect.x, row.rect.y, row.rect.w, row.rect.h) then
                Focus.row = nil
            end
        end
    elseif Pick.hexFocus then
        pollTyping(
            function(ch)
                ch = ch:upper()
                if ch:match("[%dA-F#]") and #Pick.hexBuf < 7 then Pick.hexBuf = Pick.hexBuf .. ch end
            end,
            function() Pick.hexBuf = Pick.hexBuf:sub(1, -2) end,
            function()
                local hx = Pick.hexBuf:gsub("#", "")
                if #hx == 6 then
                    local r = tonumber(hx:sub(1, 2), 16)
                    local g = tonumber(hx:sub(3, 4), 16)
                    local b = tonumber(hx:sub(5, 6), 16)
                    if r and g and b then
                        local hh, ss, vv = rgb2hsv(C3(r, g, b))
                        Pick.h, Pick.s, Pick.v = hh, ss, vv
                        pickerApply()
                    end
                end
                Pick.hexFocus = false
                Win.dirty = true
            end
        )
        Win.dirty = true
    end

    local overSidebar = inRect(In.x, In.y, x, y, math.max(Sb.cur, SB_MIN), h) and Drag.mode == nil and not Drop.open and not Pick.open
    Sb.target = (overSidebar and not Cfg.collapseSidebar) and Sb.max or SB_MIN
    local ease = Cfg.animations and (1 - (0.0000001 ^ dt)) or 1
    -- gentler ease for the sidebar so it glides open/closed instead of snapping
    local sbEase = Cfg.animations and (1 - (0.0006 ^ dt)) or 1
    local newCur = Sb.cur + (Sb.target - Sb.cur) * sbEase
    if math.abs(newCur - Sb.cur) > 0.1 then
        Sb.cur = newCur
        Win.dirty = true
    elseif math.abs(Sb.target - Sb.cur) > 0.1 then
        Sb.cur = Sb.target
        Win.dirty = true
    end

    local targetHY = (activeTab <= #Tabs) and (activeTab - 1) * ITEM_H or hiliteY
    local newHY = hiliteY + (targetHY - hiliteY) * ease
    if math.abs(newHY - hiliteY) > 0.1 then
        hiliteY = newHY
        Win.dirty = true
    end

    if In.pressed and not Capture.row then
        local consumed = false
        do local p = curPage() if p then p.momentum = 0 end end

        -- search field + results popout take clicks first
        if not consumed and Search.rect and inRect(In.x, In.y, Search.rect.x, Search.rect.y, Search.rect.w, Search.rect.h) then
            closeDropdown() closePicker()
            Search.active = true
            buildSearch()
            Win.dirty = true
            consumed = true
        elseif Search.active and Search.geom then
            local g = Search.geom
            if inRect(In.x, In.y, g.px, g.py, g.pw, g.n * g.rowH + 8) then
                local i = math.floor((In.y - (g.py + 4)) / g.rowH) + 1
                if Search.results[i] then gotoResult(Search.results[i]) end
                consumed = true
            else
                closeSearch()
                Win.dirty = true
            end
        end

        if not consumed and Pick.open then
            local gx, gy = Pick.gx or 0, Pick.gy or 0
            local gridW, gridH = SV_COLS * SV_CELL, SV_ROWS * SV_CELL
            if inRect(In.x, In.y, gx, gy, gridW, gridH) then
                Pick.s = math.max(0, math.min(1, (In.x - gx) / gridW))
                Pick.v = 1 - math.max(0, math.min(1, (In.y - gy) / gridH))
                pickerApply()
                Win.dirty = true
                consumed = true
                Drag.mode = "picksv"
            elseif inRect(In.x, In.y, gx, Pick.hy or 0, gridW, 14) then
                Pick.h = math.max(0, math.min(1, (In.x - gx) / gridW))
                pickerApply()
                Win.dirty = true
                consumed = true
                Drag.mode = "pickhue"
            elseif inRect(In.x, In.y, gx + 38, Pick.hexRowY or 0, gridW - 38, 20) then
                Pick.hexFocus = true
                Pick.hexBuf = ""
                Win.dirty = true
                consumed = true
            elseif inRect(In.x, In.y, Pick.bg.Position.X, Pick.bg.Position.Y, Pick.bg.Size.X, Pick.bg.Size.Y) then
                consumed = true
            else
                closePicker()
                consumed = true
            end
        end

        if not consumed and Drop.open and Drop.geom then
            local g = Drop.geom
            if Drop.dropSb and inRect(In.x, In.y, Drop.dropSb.x, Drop.dropSb.y, Drop.dropSb.w, Drop.dropSb.h) then
                Drag.mode = "dropsbar"
                consumed = true
            elseif inRect(In.x, In.y, g.bx + 4, g.by + 4, g.bw - 8, 20) then
                consumed = true -- search field, typing already active
            elseif inRect(In.x, In.y, g.bx, g.oy, g.bw, g.visN * 24) then
                local i = math.floor((In.y - g.oy) / 24) + 1
                if i >= 1 and i <= g.visN then
                    Drag.mode = "droppend"
                    Drag.pendIdx = i + Drop.scroll
                    Drag.sy = In.y
                    Drag.startDropScroll = Drop.scroll
                end
                consumed = true
            elseif inRect(In.x, In.y, Drop.bg.Position.X, Drop.bg.Position.Y, Drop.bg.Size.X, Drop.bg.Size.Y) then
                consumed = true
            else
                closeDropdown()
                Win.dirty = true
                consumed = true
            end
        end

        if not consumed then
            if inRect(In.x, In.y, x + w - 24, y + 4, 22, 26) then
                UI.Unload()
                return
            elseif inRect(In.x, In.y, x + w - 24, y + h - 24, 26, 26) then
                Drag.mode = "resize"
            elseif UI.sbRect and inRect(In.x, In.y, UI.sbRect.x, UI.sbRect.y, UI.sbRect.w, UI.sbRect.h) then
                Drag.mode = "sbar"
            elseif inRect(In.x, In.y, x, y, Sb.cur, h) then
                if D.gear.Visible and inRect(In.x, In.y, x + Sb.cur - 34, y + h - 40, 26, 26) then
                    switchTab(SETTINGS_TAB)
                else
                    local iy = itemsTop()
                    for i = 1, #Tabs do
                        if inRect(In.x, In.y, x, iy + (i - 1) * ITEM_H, Sb.cur, ITEM_H) then
                            switchTab(i)
                            break
                        end
                    end
                end
            else
                local handled = false
                local page = Pages[activeTab]
                if page then
                    for _, sec in ipairs(page.sections) do
                        for _, row in ipairs(sec.rows) do
                            local r = row.rect
                            if row.vis and r and In.y > y + TB and In.y < y + h - 4 and inRect(In.x, In.y, r.x, r.y, r.w, r.h) then
                                local rowPass = false
                                if row.kind == "toggle" then
                                    row.value = not row.value
                                    if row.onChange then pcall(row.onChange, row.value) end
                                    if row.flag then markChanged() end
                                elseif row.kind == "button" then
                                    if row.onClick then pcall(row.onClick) end
                                    if #UI.Objects == 0 then return end
                                elseif row.kind == "buttonrow" then
                                    local bw = row.bw or 60
                                    for i = 1, #row.defs do
                                        local bx2 = r.x + 12 + (i - 1) * (bw + 8)
                                        if inRect(In.x, In.y, bx2, r.y + 4, bw, row.h - 8) then
                                            pcall(row.defs[i].cb)
                                            break
                                        end
                                    end
                                elseif row.kind == "slider" then
                                    local t = (row.value - row.min) / math.max(0.0001, row.max - row.min)
                                    local kx = row.knobX or (row.barX + row.barW * t)
                                    if row.chipRect and inRect(In.x, In.y, row.chipRect.x, row.chipRect.y, row.chipRect.w, row.chipRect.h) then
                                        Focus.row = row
                                        row.buf = tostring(math.floor(row.value + 0.5))
                                    elseif inRect(In.x, In.y, kx - 9, row.barY - 9, 18, 20) then
                                        Drag.mode = "slider"
                                        Drag.row = row
                                    else
                                        rowPass = true
                                    end
                                elseif row.kind == "dropdown" then
                                    openDropdown(row)
                                    Win.dirty = true
                                elseif row.kind == "color" then
                                    openPicker(row)
                                    Win.dirty = true
                                elseif row.kind == "keybind" then
                                    Capture.row = row
                                elseif row.kind == "textbox" then
                                    Focus.row = row
                                elseif row.kind == "divider" or row.kind == "note" then
                                    rowPass = true
                                end
                                if not rowPass then
                                    handled = true
                                    break
                                end
                            end
                        end
                        if handled then break end
                    end
                end
                if not handled then
                    if inRect(In.x, In.y, x + Sb.cur, y, w - Sb.cur, TB) then
                        Drag.mode = "move"
                        Drag.ox, Drag.oy = In.x - x, In.y - y
                    elseif inRect(In.x, In.y, x + Sb.cur, y + TB, w - Sb.cur, h - TB) then
                        local page2 = curPage()
                        if page2 then
                            Drag.mode = "scrollpend"
                            Drag.sy = In.y
                            Drag.startScroll = page2.scrollY
                        end
                    end
                end
            end
        end
    end
    if In.released then
        if Drag.mode == "droppend" and Drop.open then
            local f = dropFiltered()
            local pick = f[Drag.pendIdx]
            if pick then
                Drop.open.value = pick
                if Drop.open.onChange then pcall(Drop.open.onChange, pick) end
                if Drop.open.flag then markChanged() end
            end
            closeDropdown()
            Win.dirty = true
        elseif Drag.mode == "scroll" then
            -- release a flick: hand the tracked velocity to the momentum integrator
            local page = curPage()
            if page then page.momentum = Drag.vel or 0 end
        end
        Drag.mode = nil
        Drag.row = nil
        Drag.vel = 0
    end

    if Drag.mode == "move" then
        Win.x, Win.y = In.x - Drag.ox, In.y - Drag.oy
        Win.dirty = true
    elseif Drag.mode == "resize" then
        local newW = math.max(MIN_W, In.x - Win.x + 8)
        local newH = math.max(MIN_H, In.y - Win.y + 8)
        if newW ~= Win.w or newH ~= Win.h then
            Win.w, Win.h = newW, newH
            Win.dirty = true
        end
    elseif Drag.mode == "slider" and Drag.row then
        sliderFromMouse(Drag.row)
    elseif Drag.mode == "picksv" and Pick.open then
        local gx, gy = Pick.gx or 0, Pick.gy or 0
        Pick.s = math.max(0, math.min(1, (In.x - gx) / (SV_COLS * SV_CELL)))
        Pick.v = 1 - math.max(0, math.min(1, (In.y - gy) / (SV_ROWS * SV_CELL)))
        pickerApply()
        Win.dirty = true
    elseif Drag.mode == "pickhue" and Pick.open then
        local gx = Pick.gx or 0
        Pick.h = math.max(0, math.min(1, (In.x - gx) / (SV_COLS * SV_CELL)))
        pickerApply()
        Win.dirty = true
    elseif Drag.mode == "droppend" then
        if math.abs(In.y - Drag.sy) > 6 then Drag.mode = "dropscroll" end
    elseif Drag.mode == "dropscroll" then
        Drop.scroll = Drag.startDropScroll + math.floor((Drag.sy - In.y) / 24 + 0.5)
        Win.dirty = true
    elseif Drag.mode == "dropsbar" and Drop.dropSb then
        local sb = Drop.dropSb
        if sb.maxSc > 0 then
            local ratio = (In.y - sb.y - sb.thH / 2) / math.max(1, sb.h - sb.thH)
            Drop.scroll = math.floor(math.max(0, math.min(sb.maxSc, ratio * sb.maxSc)) + 0.5)
            Win.dirty = true
        end
    elseif Drag.mode == "scrollpend" then
        if math.abs(In.y - Drag.sy) > 6 then Drag.mode = "scroll" end
    elseif Drag.mode == "scroll" then
        local page = curPage()
        if page then
            local newScroll = math.max(0, math.min((page.maxScroll or 0), Drag.startScroll - (In.y - Drag.sy)))
            -- track a smoothed scroll velocity (px/s) so a flick release carries momentum
            local inst = (newScroll - page.scrollY) / math.max(dt, 1e-4)
            Drag.vel = (Drag.vel or 0) * 0.6 + inst * 0.4
            page.scrollY = newScroll
            Win.dirty = true
        end
    elseif Drag.mode == "sbar" and UI.sbRect then
        local sb = UI.sbRect
        local page = curPage()
        if page and sb.maxScroll > 0 then
            local ratio = (In.y - sb.y - sb.thumbH / 2) / math.max(1, sb.h - sb.thumbH)
            page.scrollY = math.max(0, math.min(sb.maxScroll, ratio * sb.maxScroll))
            Win.dirty = true
        end
    end

    -- momentum: after a flick release the page keeps gliding, velocity decaying by friction,
    -- and stops when it slows below a threshold or hits either scroll bound (mobile-style)
    do
        local page = curPage()
        if page and Drag.mode == nil and page.momentum and math.abs(page.momentum) > 8 then
            page.scrollY = page.scrollY + page.momentum * dt
            page.momentum = page.momentum * (0.1 ^ dt)
            if page.scrollY <= 0 then page.scrollY = 0 page.momentum = 0 end
            if page.scrollY >= (page.maxScroll or 0) then page.scrollY = page.maxScroll or 0 page.momentum = 0 end
            wheelPulse = math.max(wheelPulse, 0.1)
            Win.dirty = true
        elseif page and page.momentum and math.abs(page.momentum) <= 8 then
            page.momentum = 0
        end
    end

    -- smooth scroll toward target
    do
        local page = curPage()
        if page then
            local sEase = Cfg.animations and (1 - (0.000001 ^ dt)) or 1
            local nc = page.scrollCur + (page.scrollY - page.scrollCur) * sEase
            if math.abs(nc - page.scrollCur) > 0.4 then
                page.scrollCur = nc
                Win.dirty = true
            elseif math.abs(page.scrollY - page.scrollCur) > 0.4 then
                page.scrollCur = page.scrollY
                Win.dirty = true
            end
        end
    end

    -- scrollbar glow while scrolling by any means
    wheelPulse = math.max(0, wheelPulse - dt)
    local scrolling = Drag.mode == "scroll" or Drag.mode == "sbar" or wheelPulse > 0
    local gEase = Cfg.animations and (1 - (0.00001 ^ dt)) or 1
    scrollGlowT = scrollGlowT + ((scrolling and 1 or 0) - scrollGlowT) * gEase
    if D.sbThumb.Visible then
        D.sbThumb.Color = lerpColor(Theme.Track, lerpColor(Theme.Track, Theme.C1, 0.5), scrollGlowT)
        local tp, ts = D.sbThumb.Position, D.sbThumb.Size
        local show = scrollGlowT > 0.02
        local N = #D.sbGlowSegs
        -- glow spans ~70% of the whole scrollbar track, centered on the thumb, brightest in the middle
        local trackH = (UI.sbRect and UI.sbRect.h) or ts.Y
        local total = math.floor(trackH * 0.7)
        local used = math.max(1, math.min(total, N))
        local center = tp.Y + ts.Y / 2
        local y0 = math.floor(center - used / 2)
        local coreC = lerpColor(Theme.C1, Theme.White, 0.55) -- brighter green core
        local halfW = ts.X / 2 + 2
        for i = 1, N do
            local o = D.sbGlowSegs[i]
            if show and i <= used then
                local yy = y0 + (i - 1)                 -- exactly 1px per segment
                local cy = (i - 0.5) / used             -- 0..1 down the glow
                local d = math.abs(cy - 0.5) * 2        -- 0 center, 1 ends
                local a = 1 - d
                a = a * a                                -- gentle falloff so the long glow still reaches the ends
                o.Visible = true
                o.Position = Vector2.new(tp.X - 2, yy)
                o.Size = Vector2.new(math.max(1, math.floor(halfW * 2)), 1)
                o.Color = lerpColor(Theme.C1, coreC, a) -- fade to the brighter core at the middle
                o.Transparency = (0.85 * a * scrollGlowT) * Cfg.opacity
            else
                o.Visible = false
            end
        end
    else
        for i = 1, #D.sbGlowSegs do D.sbGlowSegs[i].Visible = false end
    end

    -- dropdown scrollbar: same per-pixel glow, scaled to the smaller thumb/track
    local dropScrolling = Drag.mode == "dropscroll" or Drag.mode == "dropsbar"
    dropGlowT = dropGlowT + ((dropScrolling and 1 or 0) - dropGlowT) * gEase
    if Drop.open and Drop.sbT.Visible and Drop.dropSb then
        local tp, ts = Drop.sbT.Position, Drop.sbT.Size
        local show = dropGlowT > 0.02
        local N = #Drop.glowSegs
        local total = math.floor(Drop.dropSb.h * 0.7)
        local used = math.max(1, math.min(total, N))
        local center = tp.Y + ts.Y / 2
        local y0 = math.floor(center - used / 2)
        local coreC = lerpColor(Theme.C1, Theme.White, 0.55)
        local halfW = ts.X / 2 + 1.5
        for i = 1, N do
            local o = Drop.glowSegs[i]
            if show and i <= used then
                local yy = y0 + (i - 1)
                local cy = (i - 0.5) / used
                local a = 1 - math.abs(cy - 0.5) * 2
                a = a * a
                o.Visible = true
                o.Position = Vector2.new(tp.X - 1.5, yy)
                o.Size = Vector2.new(math.max(1, math.floor(halfW * 2)), 1)
                o.Color = lerpColor(Theme.C1, coreC, a)
                o.Transparency = (0.85 * a * dropGlowT) * Cfg.opacity
            else
                o.Visible = false
            end
        end
    else
        for i = 1, #Drop.glowSegs do Drop.glowSegs[i].Visible = false end
    end

    if cfgDirty and Cfg.autoSave then
        saveTimer = saveTimer + dt
        if saveTimer > 1.5 then
            saveTimer = 0
            cfgDirty = false
            saveSettings()
        end
    else
        saveTimer = 0
    end

    if Win.dirty then relayout() end
    -- one-shot: after jumping to a searched feature's tab, scroll it near the top
    if Search.focus and Search.focus.row and Search.focus.row.rect then
        local page = Pages[activeTab]
        if page and Search.focus.tabIdx == activeTab and (page.maxScroll or 0) > 0 then
            local targetY = Win.y + TB + 40
            page.scrollY = math.max(0, math.min(page.maxScroll or 0, page.scrollY + (Search.focus.row.rect.y - targetY)))
            Win.dirty = true
            relayout()
        end
        Search.focus = nil
    end
    updateControls(dt, In.x, In.y)
    clipRows()
end

UI.Conn = RunService.RenderStepped:Connect(function()
    local ok, e = pcall(frame)
    if not ok then
        errCount = errCount + 1
        if errCount <= 3 or errCount % 300 == 0 then
            print("FALUI|frame ERROR (" .. errCount .. "): " .. tostring(e))
        end
    end
end)

function UI.Unload()
    if UI.Conn then pcall(function() UI.Conn:Disconnect() end) end
    for _, c in ipairs(UI.WheelConns) do pcall(function() c:Disconnect() end) end
    if Cfg.autoSave then pcall(saveSettings) end
    for _, o in ipairs(UI.Objects) do pcall(function() o:Remove() end) end
    UI.Objects = {}
    pcall(setrobloxinput, true)
    print("unloaded")
end

-- ========== public API ==========
-- everything above is the engine; this is the surface external scripts talk to.
-- usage:
--   local Lib = _G.FALUI.Library
--   local tab = Lib:CreateTab("Aim", "crosshair")          -- or reuse a built-in: Lib:Tab("Home")
--   local sec = tab:CreateSection("Aimbot", "left")
--   sec:CreateToggle{ Text = "Enabled", Default = false, Flag = "aim_on", Callback = print }
--   sec:CreateSlider{ Text = "FOV", Min = 10, Max = 400, Default = 120, Suffix = " px", Flag = "aim_fov" }
local function resolveSide(side)
    side = tostring(side or "left"):lower()
    return (side == "right") and "right" or "left"
end

local function newTabIndex(name, icon)
    -- the new sidebar tab takes the slot Settings currently occupies; Settings shifts up one,
    -- keeping it the last (gear) page and its section data intact under the new index.
    local newIdx = SETTINGS_TAB
    Pages[SETTINGS_TAB + 1] = Pages[SETTINGS_TAB]
    Pages[SETTINGS_TAB] = nil
    if activeTab == SETTINGS_TAB then activeTab = SETTINGS_TAB + 1 end
    SETTINGS_TAB = SETTINGS_TAB + 1
    Tabs[newIdx] = { name = name, icon = icon or "circle" }
    Items[newIdx] = {
        icon  = New("Image", { Transparency = 1, ZIndex = 33, Visible = Win.visible, Size = Vector2.new(15, 15), Color = Theme.Dim }),
        label = New("Text",  { Text = "", Color = Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = FS + 4, Visible = Win.visible }),
    }
    loadIcon(Tabs[newIdx].icon, function(data) Items[newIdx].icon.Data = data end)
    Win.dirty = true
    return newIdx
end

local function wrapRow(row)
    return {
        row = row,
        SetTip = function(self, tip) row.tip = tip return self end,
        Set = function(self, v) applyRow(row, v) Win.dirty = true return self end,
        Get = function() if row.color ~= nil then return row.color elseif row.vk ~= nil then return row.vk else return row.value end end,
    }
end

local function wrapSection(sec, tabIdx)
    local function refresh()
        if tabIdx == activeTab then setPageVisible(activeTab, true) end
        Win.dirty = true
    end
    local S = { section = sec }
    function S:CreateToggle(o)
        o = o or {}
        local r = addToggle(sec, o.Text or o.Name or "Toggle", o.Default, o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateSlider(o)
        o = o or {}
        local r = addSlider(sec, o.Text or o.Name or "Slider", o.Min or 0, o.Max or 100, o.Default or o.Min or 0, o.Suffix, o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateDropdown(o)
        o = o or {}
        local r = addDropdown(sec, o.Text or o.Name or "Dropdown", o.Options or {}, o.Default or (o.Options and o.Options[1]) or "", o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateButton(o)
        o = o or {}
        local r = addButton(sec, o.Text or o.Name or "Button", o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateButtonRow(defs)
        local r = addButtonRow(sec, defs or {}) refresh() return wrapRow(r)
    end
    function S:CreateColor(o)
        o = o or {}
        local r = addColor(sec, o.Text or o.Name or "Color", o.Default or Theme.C1, o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    S.CreateColorpicker = S.CreateColor
    function S:CreateKeybind(o)
        o = o or {}
        local r = addKeybind(sec, o.Text or o.Name or "Keybind", o.Default or 0x24, o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateTextbox(o)
        o = o or {}
        local r = addTextbox(sec, o.Text or o.Name or "Textbox", o.Default, o.Flag, o.Callback)
        r.tip = o.Tip refresh() return wrapRow(r)
    end
    function S:CreateDivider(text) local r = addDivider(sec, text or "") refresh() return wrapRow(r) end
    function S:CreateNote(text) local r = addNote(sec, text or "") refresh() return wrapRow(r) end
    S.CreateLabel = S.CreateNote
    return S
end

local function wrapTab(tabIdx)
    local T = { index = tabIdx }
    function T:CreateSection(title, side)
        local sec = addSection(tabIdx, title or "Section", resolveSide(side))
        if tabIdx == activeTab then setPageVisible(activeTab, true) end
        Win.dirty = true
        return wrapSection(sec, tabIdx)
    end
    T.CreateGroupbox = T.CreateSection
    return T
end

local Library = {}
UI.Library = Library
Library.Flags = FlagRows

function Library:CreateTab(name, icon)
    return wrapTab(newTabIndex(name or "Tab", icon))
end

-- grab a built-in tab (Home/Visuals/Aim/Modifiers/Farm) or Settings, by name or index
function Library:Tab(ref)
    local idx = ref
    if type(ref) == "string" then
        if ref:lower() == "settings" then
            idx = SETTINGS_TAB
        else
            for i, t in ipairs(Tabs) do if t.name:lower() == ref:lower() then idx = i break end end
        end
    end
    if type(idx) ~= "number" or not Tabs[idx] and idx ~= SETTINGS_TAB then return nil end
    return wrapTab(idx)
end

function Library:SetPreset(name) applyPreset(name) Win.dirty = true end
function Library:GetFlag(flag)
    local r = FlagRows[flag]
    if not r then return nil end
    return r.color or r.vk or r.value
end
function Library:SetFlag(flag, v)
    local r = FlagRows[flag]
    if r then applyRow(r, v) Win.dirty = true return true end
    return false
end
function Library:Show() setVisible(true) end
function Library:Hide() setVisible(false) end
function Library:Toggle() setVisible(not Win.visible) end
function Library:Unload() UI.Unload() end

-- load persisted state from disk (runs once FOLDER/CFGSUB are known, i.e. inside CreateWindow)
local function loadPersisted()
    Cfg.autoLoad = readAutoload()   -- autoload pointer is the source of truth
    if rAutoLoad then rAutoLoad.value = Cfg.autoLoad end
    local sp = isfile(FOLDER .. "/settings.json") and FOLDER .. "/settings.json" or (isfile(FOLDER .. "/settings.lua") and FOLDER .. "/settings.lua" or nil)
    if sp then
        local ok, txt = pcall(readfile, sp)
        if ok and txt then loadSnapshot(txt) end
    end
    if Cfg.autoLoad and Cfg.autoLoad ~= "none" then
        local cp = isfile(cfgDir() .. "/" .. Cfg.autoLoad .. ".json") and cfgDir() .. "/" .. Cfg.autoLoad .. ".json"
            or (isfile(cfgDir() .. "/" .. Cfg.autoLoad .. ".lua") and cfgDir() .. "/" .. Cfg.autoLoad .. ".lua" or nil)
        if cp then
            local ok, txt = pcall(readfile, cp)
            if ok and txt then loadSnapshot(txt) end
        end
        if rAutoLoad then rAutoLoad.value = Cfg.autoLoad end
    end
end

local function sanitizeName(s) return (tostring(s):gsub("[^%w_%-]", "")) end

-- the window is only built/shown when the consumer calls this (nothing on disk is touched
-- and nothing is shown until then). all fields optional; nil keeps the default.
function Library:CreateWindow(opts)
    opts = opts or {}
    if opts.Title ~= nil then
        BRAND = tostring(opts.Title)
        local f = sanitizeName(opts.Title)
        if #f > 0 then FOLDER = f end
    end
    if opts.Subtitle ~= nil then SUBTITLE = tostring(opts.Subtitle) end
    if opts.Version ~= nil then VERSION = tostring(opts.Version) end
    if opts.Icon ~= nil then WinIcon = opts.Icon end
    if type(opts.FileSettings) == "table" and opts.FileSettings.ConfigFolder then
        local c = sanitizeName(opts.FileSettings.ConfigFolder)
        if #c > 0 then CFGSUB = c end
    end
    startAssets()
    loadPersisted()
    UI.created = true
    setVisible(true)
    relayout()
    return Library
end

setVisible(false)   -- stay hidden and untouched until CreateWindow is called
relayout()

-- the chunk returns the library directly, so: local Lib = loadstring(...)()  then  Lib:CreateWindow{...}
return Library