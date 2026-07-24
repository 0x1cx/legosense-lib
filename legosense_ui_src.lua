-- FALUI :: STEP 14 -- per-pixel scrollbar glow, wider sidebar, grip lines, darker bars
-- Run standalone in Matcha: loadstring(readfile(FOLDER .. "/step14.lua"))()
if _G.FALUI and _G.FALUI.Unload then pcall(_G.FALUI.Unload) end

local S = {}

local UI = { Objects = {}, Version = "step14", WheelConns = {} }
_G.FALUI = UI

-- disk layout: <FOLDER>/<CFGSUB>/name.json for configs, <FOLDER>/settings.json etc.
-- FOLDER derives from the window Title (CreateWindow), default "Legosense".
S.FOLDER = "Legosense"
S.CFGSUB = "configs"
function S.cfgDir() return S.FOLDER .. "/" .. S.CFGSUB end

-- numeric/config constants live here (own table, kept out of the ~200 local-register budget)
S.Const = {}

function S.C3(r, g, b) return Color3.fromRGB(r, g, b) end
S.BaseC1 = S.C3(229, 151, 95)
S.BaseC2 = S.C3(240, 201, 121)
S.Theme = {
    Dark = S.C3(18, 14, 11), Bg = S.C3(44, 38, 33), Panel = S.C3(52, 45, 38), PanelHov = S.C3(60, 52, 44),
    Control = S.C3(62, 54, 45), Track = S.C3(82, 72, 61), C1 = S.BaseC1, C2 = S.BaseC2,
    Header = S.C3(196, 152, 110), Text = S.C3(219, 225, 211), Dim = S.C3(130, 137, 118),
    Knob = S.C3(245, 248, 240), White = S.C3(255, 255, 255),
}
S.Const.ALPHA_BG = 0.72
S.Const.ALPHA_BAR = 0.72
S.Const.ALPHA_CARD = 0.6
S.Const.ALPHA_CTRL = 0.6
S.Const.IMG_RATIO = 0.5625
-- nyan-cat background for the Rainbow theme. paste split-frame PNG urls (ezgif.com/split) into
-- Const.NYAN_FRAMES to animate; with a single url it shows a static image. cached to disk per frame.
S.Const.NYAN_URL = "https://api.alo.ne/file/f5g8xf"   -- source gif (fallback single frame)
S.Const.NYAN_FRAMES = {
    "https://api.alo.ne/file/30ulqs", "https://api.alo.ne/file/h9jgyj",
    "https://api.alo.ne/file/n33p2a", "https://api.alo.ne/file/81w28n",
    "https://api.alo.ne/file/3n4rk4", "https://api.alo.ne/file/4u4qem",
    "https://api.alo.ne/file/fb8h1k", "https://api.alo.ne/file/qa10ou",
    "https://api.alo.ne/file/7lyc7z", "https://api.alo.ne/file/doibkh",
    "https://api.alo.ne/file/9znsku", "https://api.alo.ne/file/px1mia",
}
S.Const.NYAN_FPS = 12

S.FS = 13
S.TB = 36
S.Const.MIN_W, S.Const.MIN_H = 480, 320
S.Const.SB_MIN = 56
S.Const.ITEM_H = 38
S.CHAR_W = 7
S.CHAR_WB = 9 -- for the larger sidebar/topbar text
S.PAD = 16
S.Const.GRAD_SEGS = 6
S.Const.SNOW_N = 35

S.Cfg = {
    animations = true, hoverFx = true, opacity = 1.0,
    rainbow = false, rainbowSpeed = 100,
    checkbox = false, collapseSidebar = false, inlineDropdowns = false,
    tabLayout = "Sidebar", search = "Bar", font = "UI",
    notifyTime = 5, menuKey = 0x24, keybindOverlay = false,
    cardGlow = 60, bgFx = "Snow", border = 0, frost = 0, cornerRadius = 100,
    perfMode = false, smartFps = false, preset = "Ember",
    autoSave = true, autoLoad = "none", fxColor = S.BaseC1,
}
S.FontIds = { UI = 0, System = 1, SystemBold = 2, Minecraft = 4, Monospace = 5, Pixel = 7 }

S.Win = { x = 380, y = 140, w = 820, h = 620, visible = true, dirty = true }
S.Sb  = { cur = S.Const.SB_MIN, target = S.Const.SB_MIN, max = 220 }
S.hue = 0.28

-- no built-in feature tabs: everything except the always-present Settings page comes from
-- the public API (Library:CreateTab). Settings starts at index 1 and shifts up as tabs are added.
S.Tabs = {}
S.SETTINGS_TAB = 1
S.activeTab = S.SETTINGS_TAB
S.hiliteY = 0

S.Bases = {}
S.TextObjs = {}
S.Shapes = {}

S.Const.FADE_N = 32

function S.itemsTop()
    local expandT = (S.Sb.cur - S.Const.SB_MIN) / math.max(1, S.Sb.max - S.Const.SB_MIN)
    return S.Win.y + 50 + math.floor(6 * expandT + 0.5)
end

function S.New(t, props)
    local ok, o = pcall(Drawing.new, t)
    if not ok then print("FALUI|create fail " .. t .. ": " .. tostring(o)) return nil end
    for k, v in pairs(props) do
        local okP, e = pcall(function() o[k] = v end)
        if not okP then print("FALUI|" .. t .. "." .. k .. " set fail: " .. tostring(e)) end
    end
    if t == "Text" and props.Outline == nil then
        pcall(function() o.Outline = false end)
    end
    S.Bases[o] = props.Transparency or 1
    S.Shapes[o] = t
    if t == "Text" then table.insert(S.TextObjs, o) end
    table.insert(UI.Objects, o)
    return o
end

function S.NewFadeSegs(z, color)
    local segs = {}
    for i = 1, S.Const.FADE_N do
        segs[i] = S.New("Square", { Filled = true, Color = color or S.Theme.C1, Transparency = 0, ZIndex = z or 33, Visible = false })
    end
    return segs
end

-- peak: "center" | "left" | "right"; alpha profile fades to 0 away from peak
function S.layoutFade(segs, x1, x2, yy, peak, baseA, visible)
    local span = x2 - x1
    if span < 8 or not visible then
        for i = 1, S.Const.FADE_N do segs[i].Visible = false end
        return
    end
    local segW = span / S.Const.FADE_N
    for i = 1, S.Const.FADE_N do
        local xA = math.floor(x1 + (i - 1) * segW + 0.5)
        local xB = math.floor(x1 + i * segW + 0.5)
        local o = segs[i]
        if xB - xA >= 1 then
            local t = (i - 0.5) / S.Const.FADE_N
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
            o.Color = S.Theme.C1
            o.Transparency = baseA * a * S.Cfg.opacity
        else
            o.Visible = false
        end
    end
end

function S.truncate(label, availPx)
    local maxChars = math.floor(availPx / S.CHAR_W)
    if maxChars <= 0 then return "" end
    if #label <= maxChars then return label end
    if maxChars <= 2 then return string.rep(".", math.max(0, maxChars)) end
    return label:sub(1, maxChars - 2) .. ".."
end

function S.truncateB(label, availPx)
    local maxChars = math.floor(availPx / S.CHAR_WB)
    if maxChars <= 0 then return "" end
    if #label <= maxChars then return label end
    if maxChars <= 2 then return string.rep(".", math.max(0, maxChars)) end
    return label:sub(1, maxChars - 2) .. ".."
end

function S.lerp(a, b, t) return a + (b - a) * t end
function S.lerpColor(a, b, t)
    return S.C3(
        math.floor(S.lerp(a.R * 255, b.R * 255, t) + 0.5),
        math.floor(S.lerp(a.G * 255, b.G * 255, t) + 0.5),
        math.floor(S.lerp(a.B * 255, b.B * 255, t) + 0.5)
    )
end

function S.hsv2rgb(h, s, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p, q, t2 = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    if i == 0 then r, g, b = v, t2, p elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t2 elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t2, p, v else r, g, b = v, p, q end
    return S.C3(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

function S.rgb2hsv(c)
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

function S.hexOf(c)
    return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function S.inRect(px, py, rx, ry, rw, rh)
    return px >= rx and px <= rx + rw and py >= ry and py <= ry + rh
end

function S.CR(px) return math.max(0, math.floor(px * S.Cfg.cornerRadius / 100 + 0.5)) end

function S.setOpacity(f)
    S.Cfg.opacity = f
    for _, o in ipairs(UI.Objects) do
        local b = S.Bases[o]
        if b then pcall(function() o.Transparency = b * f end) end
    end
end

function S.applyFont(name)
    local id = S.FontIds[name]
    if not id then return end
    S.Cfg.font = name
    for _, t in ipairs(S.TextObjs) do pcall(function() t.Font = id end) end
end

S.KEYNAMES = { [0x08] = "Bksp", [0x09] = "Tab", [0x0D] = "Enter", [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt",
    [0x1B] = "Esc", [0x20] = "Space", [0x21] = "PgUp", [0x22] = "PgDn", [0x23] = "End", [0x24] = "Home",
    [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down", [0x2D] = "Ins", [0x2E] = "Del", [-2] = "MB2" }
for i = 0x30, 0x39 do S.KEYNAMES[i] = string.char(i) end
for i = 0x41, 0x5A do S.KEYNAMES[i] = string.char(i) end
for i = 0x70, 0x7B do S.KEYNAMES[i] = "F" .. (i - 0x6F) end
function S.keyName(vk) return S.KEYNAMES[vk] or ("K" .. tostring(vk)) end

S.ICON_URL = "https://raw.githubusercontent.com/latte-soft/lucide-roblox/master/icons/compiled/48px/"
function S.loadIcon(name, applyFn)
    task.spawn(function()
        local path = S.FOLDER .. "/icons48/" .. name .. ".txt"
        local data = nil
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 100 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return game:HttpGet(S.ICON_URL .. name .. ".png") end)
            if ok and d and #d > 100 then
                data = d
                if not isfolder(S.FOLDER) then pcall(makefolder, S.FOLDER) end
                if not isfolder(S.FOLDER .. "/icons48") then pcall(makefolder, S.FOLDER .. "/icons48") end
                pcall(writefile, path, d)
            end
        end
        if data and applyFn then pcall(applyFn, data) end
    end)
end

function S.loadAvatar(applyFn)
    task.spawn(function()
        local path = S.FOLDER .. "/avatar.txt"
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

-- theme background images (the Matcha character art, Columbina art, etc.), one per themed preset.
-- cached in memory per preset so switching back never refetches; applied in relayout to decode.
S.THEME_IMG = {
    Matcha = "https://raw.githubusercontent.com/nvqren/Matcha-Waifu/refs/heads/main/waifu.png",
    Columbina = "https://api.alo.ne/file/zusqrf",
}
UI.themeImg = {}
UI.themeImgRatio = {}   -- preset -> width/height, read from the PNG so it never stretches
-- aspect ratio (w/h) from image header. handles PNG (IHDR, big-endian at byte 17/21) and
-- GIF (logical screen descriptor, little-endian at byte 7/9).
local function imgRatio(d)
    if type(d) ~= "string" or #d < 24 then return nil end
    local b = string.byte
    local w, h
    if b(d, 1) == 0x89 and b(d, 2) == 0x50 then          -- PNG
        w = b(d, 17) * 16777216 + b(d, 18) * 65536 + b(d, 19) * 256 + b(d, 20)
        h = b(d, 21) * 16777216 + b(d, 22) * 65536 + b(d, 23) * 256 + b(d, 24)
    elseif b(d, 1) == 71 and b(d, 2) == 73 and b(d, 3) == 70 then   -- "GIF"
        w = b(d, 7) + b(d, 8) * 256
        h = b(d, 9) + b(d, 10) * 256
    end
    if w and h and w > 0 and h > 0 then return w / h end
    return nil
end
function S.loadThemeImage(preset)
    local url = S.THEME_IMG[preset]
    if not url then return end
    if UI.themeImg[preset] then S.Win.dirty = true return end   -- already have it
    task.spawn(function()
        local path = S.FOLDER .. "/themeimg_" .. preset .. ".txt"
        local data = nil
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 1000 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return game:HttpGet(url) end)
            if ok and d and #d > 1000 then
                data = d
                if not isfolder(S.FOLDER) then pcall(makefolder, S.FOLDER) end
                pcall(writefile, path, d)
            end
        end
        if data then
            UI.themeImg[preset] = data
            UI.themeImgRatio[preset] = imgRatio(data) or S.Const.IMG_RATIO
            -- set Data directly here (like the logo/icons, which load fine) not deferred to relayout
            if S.Cfg.preset == preset then
                pcall(function() S.D.themeImg.Data = data end)
                UI.themeImgApplied = preset
            end
            S.Win.dirty = true
        end
    end)
end

-- ========== shell ==========
S.D = {}
S.D.main    = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = S.Const.ALPHA_BG, ZIndex = 29, Corner = 8, Visible = true })
S.D.themeImg   = S.New("Image",  { Transparency = 1, ZIndex = 30, Visible = true })
S.D.nyan    = S.New("Image",  { Transparency = 1, ZIndex = 30, Visible = false })
S.D.topbar  = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 31, Corner = 8, Visible = true })
S.D.sidebar = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 32, Corner = 8, Visible = true })
S.D.seam    = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 33, Corner = 0, Visible = true })
S.D.logo    = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 34, Corner = 6, Visible = true, Size = Vector2.new(32, 32) })
S.D.logoTxt = S.New("Text",   { Text = "LS", Color = S.Theme.Dark, Transparency = 1, ZIndex = 35, Font = 0, Size = 14, Visible = true })
S.D.logoTxt2= S.New("Text",   { Text = "LS", Color = S.Theme.Dark, Transparency = 1, ZIndex = 35, Font = 0, Size = 14, Visible = true })
S.D.logoImg = S.New("Image",  { Transparency = 1, ZIndex = 36, Visible = false, Size = Vector2.new(32, 32), Rounding = 0 })
S.D.brand   = S.New("Text",   { Text = "", Color = S.Theme.C1, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true })
S.D.brandSub= S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = true })
S.D.title   = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true })
S.D.searchGlow = S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0, ZIndex = 32, Corner = 8, Visible = false })
S.D.search  = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = S.Const.ALPHA_BG, ZIndex = 32, Corner = 8, Visible = true })
S.D.searchT = S.New("Text",   { Text = "Search", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = true })
S.D.searchIco = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(12, 12), Color = S.Theme.Dim })
S.D.close   = S.New("Text",   { Text = "x", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = 15, Visible = true })
S.D.gripL1  = S.New("Line", { Color = S.Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
S.D.gripL2  = S.New("Line", { Color = S.Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
S.D.gripL3  = S.New("Line", { Color = S.Theme.Dim, Transparency = 0.9, ZIndex = 33, Visible = true, Thickness = 1 })
S.D.hilite  = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 0.5, ZIndex = 32, Corner = 6, Visible = true })
S.D.hiliteBar = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 33, Corner = 2, Visible = true })
S.D.hiliteEdge= S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0.5, ZIndex = 33, Corner = 6, Visible = true })
S.D.navHover  = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 0.7, ZIndex = 32, Corner = 6, Visible = false })
S.D.sbDiv1  = S.NewFadeSegs(33)
S.D.sbDiv2  = S.NewFadeSegs(33)
S.D.avCirc  = S.New("Circle", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 33, Visible = true, Radius = 18, NumSides = 30 })
S.D.avatar  = S.New("Image",  { Transparency = 1, ZIndex = 34, Visible = true, Size = Vector2.new(36, 36), Rounding = 18 })
S.D.footName= S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 1, Visible = true })
S.D.footSub = S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = true })
S.D.gear    = S.New("Image",  { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(18, 18), Color = S.Theme.Dim })
S.D.verTag  = S.New("Text",   { Text = "v1.3", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 2, Visible = false })
S.D.pageTxt = S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = true })
S.D.sbTrack = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 0.8, ZIndex = 36, Corner = 2, Visible = false })
S.D.sbThumb = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = 37, Corner = 2, Visible = false })
-- per-pixel glow: every segment is exactly 1px tall, so the falloff is truly seamless
S.Const.SBGLOW_N = 400
S.D.sbGlowSegs = {}
for i = 1, S.Const.SBGLOW_N do
    S.D.sbGlowSegs[i] = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = 38, Corner = 0, Visible = false })
end
S.D.tipBox  = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0.97, ZIndex = 110, Corner = 4, Visible = false })
S.D.tipL1   = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = S.FS - 1, Visible = false })
S.D.tipL2   = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = S.FS - 1, Visible = false })
S.D.tipL3   = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 111, Font = 0, Size = S.FS - 1, Visible = false })
-- seam wedges: 1px slivers that fill the rounded-corner gaps where sidebar meets topbar.
-- they only cover pixels the bars leave empty, so nothing overlaps and nothing darkens.
S.Const.WEDGE_MAX = 20
S.D.wedges = {}
for i = 1, S.Const.WEDGE_MAX * 4 do
    S.D.wedges[i] = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 31, Corner = 0, Visible = false })
end

S.DGroups = { S.D.sbDiv1, S.D.sbDiv2, S.D.sbGlowSegs, S.D.wedges }
function S.isDGroup(o)
    for _, g in ipairs(S.DGroups) do if g == o then return true end end
    return false
end

S.Items = {}
for i, tab in ipairs(S.Tabs) do
    S.Items[i] = {
        icon  = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = true, Size = Vector2.new(15, 15), Color = S.Theme.Dim }),
        label = S.New("Text",  { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true }),
    }
    S.loadIcon(tab.icon, function(data) S.Items[i].icon.Data = data end)
end
S.okName, S.plrName = pcall(function() return game:GetService("Players").LocalPlayer.Name end)
S.playerName = S.okName and tostring(S.plrName) or "player"
S.okDisp, S.plrDisp = pcall(function() return game:GetService("Players").LocalPlayer.DisplayName end)
S.displayName = (S.okDisp and S.plrDisp and #tostring(S.plrDisp) > 0) and tostring(S.plrDisp) or S.playerName

-- window options (CreateWindow overrides; nil keeps the default)
S.BRAND = "LegoSense"
S.SUBTITLE = nil            -- nil -> use the fetched game name
S.VERSION = "v1.0"
S.WinIcon = nil             -- nil -> default logo url; string url or numeric asset id
S.LOGO_URL = "https://api.alo.ne/file/ngowge"

S.GameName = "..."
S.assetsStarted = false
function S.startAssets()
    if S.assetsStarted then return end
    S.assetsStarted = true
    S.loadIcon("settings", function(data) S.D.gear.Data = data end)
    S.loadIcon("search", function(data) S.D.searchIco.Data = data end)
    S.loadAvatar(function(data) S.D.avatar.Data = data end)

    task.spawn(function()
        local ok, info = pcall(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId) end)
        if ok and info and info.Name then S.GameName = tostring(info.Name) S.Win.dirty = true return end
        local okU, uj = pcall(function()
            return game:HttpGet("https://apis.roblox.com/universes/v1/places/" .. tostring(game.PlaceId) .. "/universe")
        end)
        local uid = okU and tostring(uj):match('"universeId"%s*:%s*(%d+)') or nil
        if uid then
            local okG, gj = pcall(function() return game:HttpGet("https://games.roblox.com/v1/games?universeIds=" .. uid) end)
            local nm = okG and tostring(gj):match('"name"%s*:%s*"([^"]-)"') or nil
            if nm then S.GameName = nm S.Win.dirty = true end
        end
    end)

    task.spawn(function()
        local path = S.FOLDER .. "/logo2.txt"
        -- resolve the logo source: numeric asset id -> thumbnail url, string -> direct url, else default
        local url = S.LOGO_URL
        local usingCustom = false
        if type(S.WinIcon) == "string" and #S.WinIcon > 0 then url = S.WinIcon usingCustom = true
        elseif type(S.WinIcon) == "number" then
            usingCustom = true
            local okT, tj = pcall(function() return game:HttpGet("https://thumbnails.roblox.com/v1/assets?assetIds=" .. tostring(S.WinIcon) .. "&size=150x150&format=Png&isCircular=false") end)
            url = (okT and tostring(tj):match('"imageUrl"%s*:%s*"([^"]+)"')) or S.LOGO_URL
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
                if not isfolder(S.FOLDER) then pcall(makefolder, S.FOLDER) end
                if not usingCustom then pcall(writefile, path, d) end
            else
                print("FALUI|logo fetch failed, keeping LS text")
            end
        end
        if data then pcall(function() S.D.logoImg.Data = data end) UI.logoLoaded = true S.Win.dirty = true end
    end)

    S.loadThemeImage(S.Cfg.preset)   -- current theme's background image, if it has one

    -- nyan frames (or single gif) for the Rainbow theme
    UI.nyanData = {}
    local urls = (#S.Const.NYAN_FRAMES > 0) and S.Const.NYAN_FRAMES or { S.Const.NYAN_URL }
    for i, url in ipairs(urls) do
        task.spawn(function()
            local path = S.FOLDER .. "/nyan_" .. i .. ".txt"
            local data = nil
            if isfile(path) then
                local ok, d = pcall(readfile, path)
                if ok and d and #d > 200 then data = d end
            end
            if not data then
                local ok, d = pcall(function() return game:HttpGet(url) end)
                if ok and d and #d > 200 then
                    data = d
                    if not isfolder(S.FOLDER) then pcall(makefolder, S.FOLDER) end
                    pcall(writefile, path, d)
                end
            end
            if data then
                UI.nyanData[i] = data
                if not UI.nyanData0 then UI.nyanData0 = data end
                if i == 1 then UI.nyanRatio = imgRatio(data) or 1 end
                S.Win.dirty = true
            end
        end)
    end
end

-- ========== snow ==========
-- each flake is a 6-point star built from 3 crossing Lines. Lines are vector shapes (sub-pixel,
-- like the sidebar) so they fall perfectly smoothly -- unlike "*" glyphs which snap to the pixel
-- grid and step. flakes also slowly rotate + twinkle, and fade near every edge so nothing pops.
S.Snow = { flakes = {}, hidden = true }
for i = 1, S.Const.SNOW_N do
    local rad = 3.8 + (i % 4) * 1.2
    local lines = {}
    for k = 1, 3 do
        lines[k] = S.New("Line", { Color = S.BaseC1, Thickness = 1, Transparency = 0, ZIndex = 32, Visible = false })
    end
    S.Snow.flakes[i] = {
        lines = lines, rad = rad,
        fx = math.random(), fy = math.random(),
        vy = (20 + math.random() * 8) * 1.2,
        amp = 3 + math.random() * 6, freq = 0.3 + math.random() * 0.5,
        ph = math.random() * 6.28, br = math.random(),
        spin = (math.random() - 0.5) * 0.8,
    }
end

function S.updateSnow(dt, t)
    local on = S.Win.visible and S.Cfg.bgFx == "Snow"
    if not on then
        if not S.Snow.hidden then
            for _, f in ipairs(S.Snow.flakes) do for _, l in ipairs(f.lines) do l.Visible = false end end
            S.Snow.hidden = true
        end
        return
    end
    S.Snow.hidden = false
    local base = S.Cfg.fxColor or S.Theme.C1
    for _, f in ipairs(S.Snow.flakes) do
        f.py = (f.py or f.fy * S.Win.h) + f.vy * dt
        if f.py > S.Win.h + 8 then
            f.py = -8
            f.fx = math.random()
        end
        local px = S.Win.x + f.fx * S.Win.w + math.sin(t * f.freq + f.ph) * f.amp
        local py = S.Win.y + f.py
        local topB = (px < S.Win.x + S.Sb.cur) and (S.Win.y + 4) or (S.Win.y + S.TB + 2)
        -- soft distance to the nearest edge; alpha ramps over ~16px so nothing snaps on/off
        local m = math.min(px - (S.Win.x + 4), (S.Win.x + S.Win.w - 10) - px, py - topB, (S.Win.y + S.Win.h - 8) - py)
        local edge = math.max(0, math.min(1, m / 16))
        edge = edge * edge * (3 - 2 * edge)
        local shown = m > -f.rad
        if shown then
            local twinkle = 0.4 + 0.4 * math.abs(math.sin(t * 1.4 + f.ph))
            local col = S.lerpColor(base, S.Theme.White, f.br * 0.4)
            local a = twinkle * edge * S.Cfg.opacity
            local rot = t * f.spin + f.ph
            local r = f.rad
            for k = 1, 3 do
                local ang = rot + (k - 1) * 1.0472   -- 60 deg apart -> 6-point star
                local dx, dy = math.cos(ang) * r, math.sin(ang) * r
                local l = f.lines[k]
                l.From = Vector2.new(px - dx, py - dy)
                l.To = Vector2.new(px + dx, py + dy)
                l.Color = col
                l.Transparency = a
                l.Visible = true
            end
        else
            for k = 1, 3 do f.lines[k].Visible = false end
        end
    end
end

-- ========== dropdown popout ==========
S.Const.MAXOPT = 7
S.Drop = { open = nil, options = {}, hovT = {}, searchBuf = "", scroll = 0, animT = 0, closing = false }
S.Drop.bg = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0.985, ZIndex = 100, Corner = 5, Visible = false })
S.Drop.searchBox = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0.97, ZIndex = 101, Corner = 4, Visible = false })
S.Drop.searchTxt = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS - 1, Visible = false })
S.Drop.sbT = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = 102, Corner = 1, Visible = false })
-- scaled-down copy of the main scrollbar's per-pixel glow, for the dropdown list scrollbar
S.Const.DROPGLOW_N = 140
S.Drop.glowSegs = {}
for i = 1, S.Const.DROPGLOW_N do
    S.Drop.glowSegs[i] = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = 103, Corner = 0, Visible = false })
end
S.Drop.rows = {}
for i = 1, S.Const.MAXOPT do
    S.Drop.rows[i] = {
        bg  = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0, ZIndex = 101, Corner = 4, Visible = false }),
        txt = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS, Visible = false }),
        chk = S.New("Text", { Text = "+", Color = S.Theme.C1, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS, Visible = false }),
    }
    S.Drop.hovT[i] = 0
end

function S.dropHideObjs()
    S.Drop.bg.Visible = false
    S.Drop.searchBox.Visible = false
    S.Drop.searchTxt.Visible = false
    S.Drop.sbT.Visible = false
    for i = 1, #S.Drop.glowSegs do S.Drop.glowSegs[i].Visible = false end
    for i = 1, S.Const.MAXOPT do
        S.Drop.rows[i].bg.Visible = false
        S.Drop.rows[i].txt.Visible = false
        S.Drop.rows[i].chk.Visible = false
        S.Drop.hovT[i] = 0
    end
end

-- immediate teardown (used by the system: menu hide, tab switch, opening the picker)
function S.hardCloseDropdown()
    S.Drop.open = nil
    S.Drop.closing = false
    S.Drop.animT = 0
    S.dropHideObjs()
end

-- user-facing close: play the slide-up/fade-out, real teardown happens when the anim finishes
function S.closeDropdown()
    if S.Drop.open then S.Drop.closing = true S.Win.dirty = true else S.dropHideObjs() end
end

function S.openDropdown(row)
    S.Drop.open = row
    S.Drop.options = row.options or {}
    S.Drop.searchBuf = ""
    S.Drop.scroll = 0
    S.Drop.closing = false
    S.Drop.animT = 0            -- grows to 1 -> slides down + fades in
end

function S.dropFiltered()
    local out = {}
    local q = S.Drop.searchBuf:lower()
    for _, o in ipairs(S.Drop.options) do
        if q == "" or tostring(o):lower():find(q, 1, true) then
            table.insert(out, tostring(o))
        end
    end
    return out
end

-- ========== color picker (smooth grid) ==========
S.Const.SV_COLS, S.Const.SV_ROWS, S.Const.SV_CELL = 66, 42, 2.34
S.Const.HUE_SEGS = 72
S.Pick = { open = nil, h = 0.3, s = 0.6, v = 0.8, hexFocus = false, hexBuf = "" }
S.Pick.bg   = S.New("Square", { Filled = true, Color = S.C3(14, 17, 11), Transparency = 0.985, ZIndex = 100, Corner = 6, Visible = false })
S.Pick.sv = {}
for r = 1, S.Const.SV_ROWS do
    S.Pick.sv[r] = {}
    for c = 1, S.Const.SV_COLS do
        S.Pick.sv[r][c] = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false, Size = Vector2.new(math.ceil(S.Const.SV_CELL), math.ceil(S.Const.SV_CELL)) })
    end
end
S.Pick.svCur = S.New("Square", { Filled = false, Color = S.Theme.White, Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(8, 8) })
S.Pick.hueSegs = {}
for i = 1, S.Const.HUE_SEGS do
    S.Pick.hueSegs[i] = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false })
end
S.Pick.hueCur = S.New("Square", { Filled = false, Color = S.Theme.White, Transparency = 1, ZIndex = 102, Visible = false })
S.Pick.prev   = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
S.Pick.hexBox = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
S.Pick.hexTxt = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS - 1, Visible = false })

-- ========== search popup ==========
S.Const.SEARCH_MAX = 8
S.Search = { active = false, buf = "", results = {}, hovT = {}, focus = nil, rect = nil, geom = nil }
S.Search.bg = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0.985, ZIndex = 100, Corner = 5, Visible = false })
S.Search.rows = {}
for i = 1, S.Const.SEARCH_MAX do
    S.Search.rows[i] = {
        bg   = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0, ZIndex = 101, Corner = 4, Visible = false }),
        txt  = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS, Visible = false }),
        icon = S.New("Image",  { Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(13, 13), Color = S.Theme.Dim }),
        tab  = S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS - 1, Visible = false }),
    }
    S.Search.hovT[i] = 0
end
S.loadIcon("move-up-right", function(data)
    for i = 1, S.Const.SEARCH_MAX do S.Search.rows[i].icon.Data = data end
end)

function S.closeSearch()
    S.Search.active = false
    S.Search.buf = ""
    S.Search.bg.Visible = false
    for i = 1, S.Const.SEARCH_MAX do
        local r = S.Search.rows[i]
        r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
        S.Search.hovT[i] = 0
    end
    S.Search.geom = nil
end

function S.pickObjsVisible(v)
    S.Pick.bg.Visible = v
    for r = 1, S.Const.SV_ROWS do for c = 1, S.Const.SV_COLS do S.Pick.sv[r][c].Visible = v end end
    S.Pick.svCur.Visible = v
    for i = 1, S.Const.HUE_SEGS do S.Pick.hueSegs[i].Visible = v end
    S.Pick.hueCur.Visible = v
    S.Pick.prev.Visible = v
    S.Pick.hexBox.Visible = v
    S.Pick.hexTxt.Visible = v
end

function S.closePicker()
    S.Pick.open = nil
    S.Pick.hexFocus = false
    S.pickObjsVisible(false)
end

function S.pickerColor() return S.hsv2rgb(S.Pick.h, S.Pick.s, S.Pick.v) end

function S.pickerApply()
    if not S.Pick.open then return end
    local c = S.pickerColor()
    S.Pick.open.color = c
    if S.Pick.open.onChange then pcall(S.Pick.open.onChange, c) end
end

function S.openPicker(row)
    S.hardCloseDropdown()
    S.Pick.open = row
    local h, s, v = S.rgb2hsv(row.color or S.Theme.C1)
    S.Pick.h, S.Pick.s, S.Pick.v = h, s, v
    S.Pick.hexFocus = false
    S.pickObjsVisible(true)
end

S.Capture = { row = nil }
S.Focus = { row = nil }
S.keyStates = {}

-- ========== components ==========
S.Pages = {}
S.FlagRows = {}

function S.addSection(tabIdx, title, side)
    S.Pages[tabIdx] = S.Pages[tabIdx] or { sections = {}, scrollY = 0, scrollCur = 0, contentH = 0, maxScroll = 0 }
    local sec = {
        title = title, side = side, rows = {}, hovT = 0, vis = true,
        hdr  = S.New("Text", { Text = title, Color = S.Theme.Header, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }),
        hsegs= S.NewFadeSegs(33),
        panel= S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = S.Const.ALPHA_CARD, ZIndex = 31, Corner = 6, Visible = false }),
        glow = S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0, ZIndex = 32, Corner = 6, Visible = false }),
    }
    table.insert(S.Pages[tabIdx].sections, sec)
    return sec
end

function S.regFlag(row, flag)
    if flag then row.flag = flag S.FlagRows[flag] = row end
    return row
end

function S.addToggle(sec, label, default, flag, onChange)
    local row = {
        kind = "toggle", label = label, value = default and true or false, onChange = onChange,
        knobT = default and 1 or 0, hovT = 0, vis = true, h = 34,
        lbl   = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        track = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = 33, Corner = 6, Visible = false, Size = Vector2.new(34, 18) }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 6, Visible = false, Size = Vector2.new(34, 18) }),
        knob  = S.New("Square", { Filled = true, Color = S.Theme.Knob, Transparency = 1, ZIndex = 35, Corner = 5, Visible = false, Size = Vector2.new(14, 14) }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addSlider(sec, label, min, max, default, suffix, flag, onChange)
    local row = {
        kind = "slider", label = label, min = min, max = max, value = default, suffix = suffix or "", onChange = onChange,
        hovT = 0, vis = true, h = 44,
        lbl   = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        chip  = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(52, 17) }),
        chipT = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }),
        track = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = 33, Corner = 1, Visible = false }),
        segs  = {},
        knob  = S.New("Circle", { Filled = true, Color = S.Theme.Knob, Transparency = 1, ZIndex = 35, Visible = false, Radius = 5, NumSides = 16 }),
    }
    for i = 1, S.Const.GRAD_SEGS do
        row.segs[i] = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 34, Visible = false })
    end
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addButton(sec, label, onClick)
    local row = {
        kind = "button", label = label, onClick = onClick, hovT = 0, vis = true, h = 32,
        box = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        lbl = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false }),
    }
    table.insert(sec.rows, row)
    return row
end

function S.addButtonRow(sec, defs)
    local row = { kind = "buttonrow", defs = defs, hovT = 0, vis = true, hovTs = {}, h = 32, boxes = {}, lbls = {} }
    row.olines = {}
    for i, d in ipairs(defs) do
        row.boxes[i] = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false })
        row.olines[i] = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false })
        row.lbls[i]  = S.New("Text", { Text = d.label, Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false })
        row.hovTs[i] = 0
    end
    table.insert(sec.rows, row)
    return row
end

function S.addDropdown(sec, label, options, default, flag, onChange)
    local row = {
        kind = "dropdown", label = label, options = options, value = default, onChange = onChange,
        hovT = 0, vis = true, h = 34,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        box = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        val = S.New("Text", { Text = default, Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false }),
        arr = S.New("Text", { Text = "v", Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addColor(sec, label, default, flag, onChange)
    local row = {
        kind = "color", label = label, color = default, onChange = onChange, hovT = 0, vis = true, h = 34,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        sw  = S.New("Square", { Filled = true, Color = default, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(16, 16) }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addKeybind(sec, label, defaultVk, flag, onChange)
    local row = {
        kind = "keybind", label = label, vk = defaultVk, onChange = onChange, hovT = 0, vis = true, h = 34,
        lbl  = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        chip = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(44, 17) }),
        chipT= S.New("Text", { Text = S.keyName(defaultVk), Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addTextbox(sec, label, default, flag, onChange)
    local row = {
        kind = "textbox", label = label, value = default or "", onChange = onChange, hovT = 0, vis = true, h = 48,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }),
        box = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        txt = S.New("Text", { Text = default or "", Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addDivider(sec, label)
    local row = { kind = "divider", label = label, hovT = 0, vis = true, h = 20,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }),
        segsL = S.NewFadeSegs(33),
        segsR = S.NewFadeSegs(33) }
    table.insert(sec.rows, row)
    return row
end

function S.addNote(sec, label)
    local row = { kind = "note", label = label, hovT = 0, vis = true, h = 24,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }) }
    table.insert(sec.rows, row)
    return row
end

function S.rowObjs(row)
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

function S.setPageVisible(tabIdx, v)
    local page = S.Pages[tabIdx]
    if not page then return end
    for _, sec in ipairs(page.sections) do
        sec.hdr.Visible = v
        for _, s in ipairs(sec.hsegs) do s.Visible = false end
        sec.panel.Visible = v
        sec.glow.Visible = false
        for _, row in ipairs(sec.rows) do
            for _, o in ipairs(S.rowObjs(row)) do o.Visible = v end
        end
    end
    if not v then S.hardCloseDropdown() S.closePicker() end
end

-- ========== config system (clean, sorted JSON) ==========
S.HttpService = game:GetService("HttpService")

-- hand-rolled JSON encoder: keys sorted alphabetically so files are stable and human-readable
function S.jsonEsc(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\'
        elseif c == '\n' then return '\\n' elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t' else return string.format('\\u%04x', string.byte(c)) end
    end))
end
function S.jsonEnc(v)
    local t = type(v)
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    end
    if t == "string" then return '"' .. S.jsonEsc(v) .. '"' end
    if t == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i = 1, #v do parts[i] = S.jsonEnc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. S.jsonEsc(tostring(k)) .. '":' .. S.jsonEnc(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end
-- self-contained JSON parser (no HttpService dependency, so loads work on any executor)
function S.jsonParse(s)
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
function S.jsonDecode(txt)
    if type(txt) ~= "string" or #txt == 0 then return nil end
    if txt:match("^%s*return") then -- legacy Lua configs still load
        local ok, chunk = pcall(loadstring, txt)
        if ok and chunk then local ok2, d = pcall(chunk) if ok2 and type(d) == "table" then return d end end
        return nil
    end
    return S.jsonParse(txt)
end

function S.flagValue(row)
    if row.kind == "color" then
        local c = row.color
        return { c.R, c.G, c.B }
    elseif row.kind == "keybind" then return row.vk
    else return row.value end
end

function S.arr2c(a)
    if type(a) ~= "table" or not a[1] then return nil end
    local r, g, b = a[1], a[2] or 0, a[3] or 0
    if r <= 1 and g <= 1 and b <= 1 then r, g, b = r * 255, g * 255, b * 255 end
    return S.C3(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end

-- every surface colour saved explicitly, so any theme (preset OR custom) restores exactly
S.THEME_KEYS = { "Dark", "Bg", "Panel", "PanelHov", "Control", "Track", "Header", "C1", "C2", "Text" }
function S.snapshot()
    local t = { w = S.Win.w, h = S.Win.h, x = S.Win.x, y = S.Win.y }
    for flag, row in pairs(S.FlagRows) do
        local v = S.flagValue(row)
        if v ~= nil then t[flag] = v end
    end
    local th = {}
    for _, k in ipairs(S.THEME_KEYS) do local c = S.Theme[k] th[k] = { c.R, c.G, c.B } end
    t.theme = th
    return S.jsonEnc(t)
end

function S.applyRow(row, v)
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
        row.color = S.C3(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
        if row.onChange then pcall(row.onChange, row.color) end
    elseif row.kind == "keybind" and type(v) == "number" then
        row.vk = v
        row.chipT.Text = S.keyName(v)
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "textbox" and type(v) == "string" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    end
end

-- flags applied in a fixed order: "preset" first (it retints the theme and overwrites the
-- colour swatches), then the colours (so a saved Custom colour wins), then everything else.
S.LOAD_ORDER = { preset = 1, color1 = 2, color2 = 2 }
function S.loadSnapshot(txt)
    local data = S.jsonDecode(txt)
    if type(data) ~= "table" then return false end
    -- window geometry
    if type(data.w) == "number" and type(data.h) == "number" then
        S.Win.w = math.max(S.Const.MIN_W, data.w)
        S.Win.h = math.max(S.Const.MIN_H, data.h)
    end
    if type(data.x) == "number" then S.Win.x = data.x end
    if type(data.y) == "number" then S.Win.y = data.y end
    local ordered = {}
    for flag, v in pairs(data) do
        if S.FlagRows[flag] then table.insert(ordered, flag) end
    end
    table.sort(ordered, function(a, b)
        return (S.LOAD_ORDER[a] or 9) < (S.LOAD_ORDER[b] or 9)
    end)
    for _, flag in ipairs(ordered) do
        S.applyRow(S.FlagRows[flag], data[flag])
    end
    -- explicit theme palette applied last -> exact surface colours regardless of preset/custom
    if type(data.theme) == "table" then
        for _, k in ipairs(S.THEME_KEYS) do
            local c = S.arr2c(data.theme[k])
            if c then S.Theme[k] = c end
        end
    end
    S.Win.dirty = true
    return true
end

S.cfgDirty = false
function S.markChanged() S.cfgDirty = true end

function S.configList()
    local names = {}
    if isfile(S.cfgDir() .. "/_index.txt") then
        local ok, txt = pcall(readfile, S.cfgDir() .. "/_index.txt")
        if ok and txt then
            for line in txt:gmatch("[^\r\n]+") do
                if #line > 0 then table.insert(names, line) end
            end
        end
    end
    return names
end

function S.writeIndex(names)
    pcall(writefile, S.cfgDir() .. "/_index.txt", table.concat(names, "\n"))
end

function S.ensureCfgDir()
    if not isfolder(S.FOLDER) then pcall(makefolder, S.FOLDER) end
    if not isfolder(S.cfgDir()) then pcall(makefolder, S.cfgDir()) end
end

-- the auto-load choice lives in its own tiny file, separate from any config's data, so the
-- "which config loads on startup" pointer stays clear and never gets tangled in the saved state.
function S.writeAutoload(name)
    S.ensureCfgDir()
    if not name or name == "" or name == "none" then
        pcall(function() if isfile(S.FOLDER .. "/autoload.txt") then delfile(S.FOLDER .. "/autoload.txt") end end)
    else
        pcall(writefile, S.FOLDER .. "/autoload.txt", name)
    end
end
function S.readAutoload()
    if isfile(S.FOLDER .. "/autoload.txt") then
        local ok, txt = pcall(readfile, S.FOLDER .. "/autoload.txt")
        if ok and txt then
            local nm = txt:gsub("[\r\n]", "")
            if #nm > 0 then return nm end
        end
    end
    return "none"
end

-- ========== settings page ==========
S.Presets = {
    Matcha = { c1 = S.C3(150, 205, 120), c2 = S.C3(195, 230, 130),
        Dark = S.C3(14, 18, 11), Bg = S.C3(38, 44, 35), Panel = S.C3(42, 46, 37), PanelHov = S.C3(50, 54, 44),
        Control = S.C3(52, 57, 46), Track = S.C3(70, 74, 64), Header = S.C3(150, 172, 116) },
    Columbina = { c1 = S.C3(220, 47, 126), c2 = S.C3(170, 77, 118),
        Dark = S.C3(20, 22, 34), Bg = S.C3(31, 33, 50), Panel = S.C3(40, 42, 60), PanelHov = S.C3(48, 50, 70),
        Control = S.C3(50, 52, 72), Track = S.C3(72, 74, 98), Header = S.C3(198, 130, 165) },
    Violet = { c1 = S.C3(167, 120, 240), c2 = S.C3(196, 160, 250),
        Dark = S.C3(16, 12, 24), Bg = S.C3(34, 28, 46), Panel = S.C3(42, 35, 56), PanelHov = S.C3(50, 42, 66),
        Control = S.C3(52, 44, 68), Track = S.C3(74, 64, 92), Header = S.C3(170, 140, 210) },
    Gold = { c1 = S.C3(240, 196, 90), c2 = S.C3(250, 220, 140),
        Dark = S.C3(20, 17, 10), Bg = S.C3(44, 38, 26), Panel = S.C3(52, 45, 32), PanelHov = S.C3(60, 52, 38),
        Control = S.C3(62, 54, 40), Track = S.C3(84, 74, 54), Header = S.C3(210, 180, 120) },
    Crimson = { c1 = S.C3(232, 80, 80), c2 = S.C3(245, 130, 120),
        Dark = S.C3(22, 12, 12), Bg = S.C3(46, 30, 30), Panel = S.C3(54, 36, 36), PanelHov = S.C3(64, 42, 42),
        Control = S.C3(66, 44, 44), Track = S.C3(88, 60, 60), Header = S.C3(210, 130, 130) },
    Aqua = { c1 = S.C3(80, 210, 210), c2 = S.C3(130, 235, 225),
        Dark = S.C3(10, 20, 22), Bg = S.C3(28, 42, 44), Panel = S.C3(34, 50, 52), PanelHov = S.C3(40, 58, 60),
        Control = S.C3(42, 60, 62), Track = S.C3(60, 82, 84), Header = S.C3(120, 190, 190) },
    Midnight = { c1 = S.C3(127, 178, 229), c2 = S.C3(156, 214, 240),
        Dark = S.C3(11, 14, 18), Bg = S.C3(33, 38, 46), Panel = S.C3(40, 46, 55), PanelHov = S.C3(47, 54, 64),
        Control = S.C3(48, 56, 66), Track = S.C3(64, 72, 84), Header = S.C3(122, 158, 198) },
    Ember = { c1 = S.C3(229, 151, 95), c2 = S.C3(240, 201, 121),
        Dark = S.C3(18, 14, 11), Bg = S.C3(44, 38, 33), Panel = S.C3(52, 45, 38), PanelHov = S.C3(60, 52, 44),
        Control = S.C3(62, 54, 45), Track = S.C3(82, 72, 61), Header = S.C3(196, 152, 110) },
    Mono = { c1 = S.C3(228, 230, 234), c2 = S.C3(176, 180, 188),
        Dark = S.C3(13, 14, 16), Bg = S.C3(34, 35, 38), Panel = S.C3(43, 44, 48), PanelHov = S.C3(52, 53, 58),
        Control = S.C3(54, 55, 60), Track = S.C3(78, 80, 86), Header = S.C3(190, 193, 200) },
    -- Rainbow uses Mono's light surfaces; the frame loop cycles the accent + sidebar/topbar hue
    Rainbow = { c1 = S.C3(228, 230, 234), c2 = S.C3(176, 180, 188),
        Dark = S.C3(30, 24, 40), Bg = S.C3(34, 35, 38), Panel = S.C3(43, 44, 48), PanelHov = S.C3(52, 53, 58),
        Control = S.C3(54, 55, 60), Track = S.C3(78, 80, 86), Header = S.C3(190, 193, 200) },
    Custom = nil,
}

function S.applyPreset(name)
    local p = S.Presets[name]
    if not p then return end
    S.Theme.C1 = p.c1
    S.Theme.C2 = p.c2
    S.Theme.Dark = p.Dark
    S.Theme.Bg = p.Bg
    S.Theme.Panel = p.Panel
    S.Theme.PanelHov = p.PanelHov
    S.Theme.Control = p.Control
    S.Theme.Track = p.Track
    S.Theme.Header = p.Header
    S.Win.dirty = true
end

function S.applyAccent(c1, c2)
    S.Theme.C1 = c1
    S.Theme.C2 = c2
    S.Win.dirty = true
end

do
    local sTheme = S.addSection(S.SETTINGS_TAB, "THEME", "left")
    S.addDropdown(sTheme, "Preset", { "Matcha", "Columbina", "Midnight", "Ember", "Mono", "Violet", "Gold", "Crimson", "Aqua", "Rainbow", "Custom" }, "Ember", "preset", function(v)
        S.Cfg.preset = v
        local p = S.Presets[v]
        if p then
            S.applyPreset(v)
            if S.rColor1 then S.rColor1.color = p.c1 end
            if S.rColor2 then S.rColor2.color = p.c2 end
        end
        S.loadThemeImage(v)
        S.markChanged()
    end).tip = "Pick a look, Rainbow to cycle, or Custom for your own colours"
    S.rColor1 = S.addColor(sTheme, "Color 1", S.BaseC1, "color1", function(c) S.Theme.C1 = c S.Cfg.preset = "Custom" S.Win.dirty = true S.markChanged() end)
    S.rColor2 = S.addColor(sTheme, "Color 2", S.BaseC2, "color2", function(c) S.Theme.C2 = c S.Cfg.preset = "Custom" S.Win.dirty = true S.markChanged() end)
    local rSpeed = S.addSlider(sTheme, "Rainbow speed", 10, 300, 100, " %", "rainbowSpeed", function(v) S.Cfg.rainbowSpeed = v S.markChanged() end)
    rSpeed.showIf = "Rainbow"          -- only present while the Rainbow theme is active
    rSpeed.showT = (S.Cfg.preset == "Rainbow") and 1 or 0

    local sApp = S.addSection(S.SETTINGS_TAB, "APPEARANCE", "left")
    S.addColor(sApp, "Background", S.Theme.Bg, "bgColor", function(c) S.Theme.Bg = c S.Win.dirty = true S.markChanged() end)
    S.addColor(sApp, "Text color", S.Theme.Text, "textColor", function(c) S.Theme.Text = c S.Win.dirty = true S.markChanged() end)
    S.addSlider(sApp, "Card glow", 0, 200, 60, " %", "cardGlow", function(v) S.Cfg.cardGlow = v S.markChanged() end).tip = "Accent glow around section cards"
    S.addDropdown(sApp, "Background FX", { "Off", "Snow" }, "Snow", "bgFx", function(v) S.Cfg.bgFx = v S.markChanged() end).tip = "Sparkles drifting inside the menu"
    S.addColor(sApp, "FX colour", S.BaseC1, "fxColor", function(c) S.Cfg.fxColor = c S.markChanged() end)
    S.addSlider(sApp, "Corner radius", 0, 200, 100, " %", "cornerRadius", function(v) S.Cfg.cornerRadius = v S.Win.dirty = true S.markChanged() end)
    S.addDivider(sApp, "Misc")
    S.addToggle(sApp, "Performance mode", false, "perfMode", function(v) S.Cfg.perfMode = v S.markChanged() end)
    S.addToggle(sApp, "Smart FPS", false, "smartFps", function(v) S.Cfg.smartFps = v S.markChanged() end)

    local sIface = S.addSection(S.SETTINGS_TAB, "INTERFACE", "right")
    S.addKeybind(sIface, "Menu key", 0x24, "menuKey", function(vk) S.Cfg.menuKey = vk S.markChanged() end)
    S.addToggle(sIface, "Keybind overlay", false, "keybindOverlay", function(v) S.Cfg.keybindOverlay = v S.markChanged() end)
    S.addToggle(sIface, "Hover effects", true, "hoverFx", function(v) S.Cfg.hoverFx = v S.markChanged() end)
    S.addToggle(sIface, "Checkbox style", false, "checkbox", function(v) S.Cfg.checkbox = v S.Win.dirty = true S.markChanged() end).tip = "Square checkboxes instead of pills"
    S.addToggle(sIface, "Collapse sidebar", false, "collapseSidebar", function(v) S.Cfg.collapseSidebar = v S.markChanged() end).tip = "Pin the sidebar closed (no hover expand)"
    S.addToggle(sIface, "Inline dropdowns", false, "inlineDropdowns", function(v) S.Cfg.inlineDropdowns = v S.markChanged() end).tip = "Coming soon: expand in place instead of popout"
    S.addDropdown(sIface, "Tab layout", { "Sidebar" }, "Sidebar", "tabLayout", function(v) S.Cfg.tabLayout = v S.markChanged() end)
    S.addDropdown(sIface, "Search", { "Bar", "Off" }, "Bar", "search", function(v) S.Cfg.search = v S.Win.dirty = true S.markChanged() end)
    S.addDropdown(sIface, "Font", { "UI", "System", "SystemBold", "Minecraft", "Monospace", "Pixel" }, "UI", "font", function(v) S.applyFont(v) S.markChanged() end)
    S.addSlider(sIface, "Menu opacity", 30, 100, 100, " %", "opacity", function(v) S.setOpacity(v / 100) S.markChanged() end)
    S.addToggle(sIface, "Animations", true, "animations", function(v) S.Cfg.animations = v S.markChanged() end)
    S.addSlider(sIface, "Notify time", 1, 15, 5, " s", "notifyTime", function(v) S.Cfg.notifyTime = v S.markChanged() end)

    local sCfgS = S.addSection(S.SETTINGS_TAB, "CONFIGS", "right")
    S.rName = S.addTextbox(sCfgS, "Name", "MyConfig", nil, nil)
    S.addButtonRow(sCfgS, {
        { label = "Save", cb = function()
            local nm = S.rName.value:gsub("[^%w_%-]", "")
            if #nm == 0 then return end
            S.ensureCfgDir()
            pcall(writefile, S.cfgDir() .. "/" .. nm .. ".json", S.snapshot())
            local names = S.configList()
            local found = false
            for _, n in ipairs(names) do if n == nm then found = true end end
            if not found then table.insert(names, nm) S.writeIndex(names) end
            if S.rConfigDrop then S.rConfigDrop.options = S.configList() end
            if S.rAutoLoad then
                local o = { "none" }
                for _, n in ipairs(S.configList()) do table.insert(o, n) end
                S.rAutoLoad.options = o
            end
        end },
        { label = "Load", cb = function()
            local nm = (S.rConfigDrop and S.rConfigDrop.value) or ""
            if nm ~= "" and nm ~= "none" then
                local path = S.cfgDir() .. "/" .. nm .. ".json"
                if not isfile(path) and isfile(S.cfgDir() .. "/" .. nm .. ".lua") then path = S.cfgDir() .. "/" .. nm .. ".lua" end
                if isfile(path) then
                    local ok, txt = pcall(readfile, path)
                    if ok and txt then S.loadSnapshot(txt) end
                end
            end
        end },
        { label = "Delete", cb = function()
            local nm = (S.rConfigDrop and S.rConfigDrop.value) or ""
            if nm ~= "" and nm ~= "none" then
                pcall(function() if isfile(S.cfgDir() .. "/" .. nm .. ".json") then delfile(S.cfgDir() .. "/" .. nm .. ".json") end end)
                pcall(function() if isfile(S.cfgDir() .. "/" .. nm .. ".lua") then delfile(S.cfgDir() .. "/" .. nm .. ".lua") end end)
                local names = S.configList()
                for i = #names, 1, -1 do if names[i] == nm then table.remove(names, i) end end
                S.writeIndex(names)
                if S.rConfigDrop then S.rConfigDrop.options = names S.rConfigDrop.value = names[1] or "none" end
                if S.rAutoLoad then
                    local o = { "none" }
                    for _, n in ipairs(names) do table.insert(o, n) end
                    S.rAutoLoad.options = o
                end
            end
        end },
    })
    S.rConfigDrop = S.addDropdown(sCfgS, "Config", S.configList(), "none", nil, nil)
    S.addToggle(sCfgS, "Auto-save", true, "autoSave", function(v) S.Cfg.autoSave = v S.markChanged() end).tip = "Persist settings to disk automatically"
    local alOpts = { "none" }
    for _, n in ipairs(S.configList()) do table.insert(alOpts, n) end
    S.rAutoLoad = S.addDropdown(sCfgS, "Auto-load", alOpts, "none", nil, function(v) S.Cfg.autoLoad = v S.writeAutoload(v) end)

    local sSys = S.addSection(S.SETTINGS_TAB, "SYSTEM", "right")
    S.addButton(sSys, "Re-center window", function()
        local ok, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
        if ok and vp then
            S.Win.x = math.floor((vp.X - S.Win.w) / 2)
            S.Win.y = math.floor((vp.Y - S.Win.h) / 2)
            S.Win.dirty = true
        end
    end)
    S.addButton(sSys, "Minimize", function() end)
    S.addButton(sSys, "Unload UI", function() UI.Unload() end)
end

-- effective row height: conditional rows (row.showT) collapse to 0 so the card resizes smoothly
function S.rowEffH(row)
    local t = row.showT
    if t == nil then return row.h end
    t = t * t * (3 - 2 * t)
    return row.h * t
end

-- ========== layout (with scroll + culling) ==========
function S.relayoutRaw()
    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    local sw = math.floor(S.Sb.cur + 0.5)
    local expandT = (S.Sb.cur - S.Const.SB_MIN) / math.max(1, S.Sb.max - S.Const.SB_MIN)

    S.D.main.Position = Vector2.new(x, y)
    S.D.main.Size = Vector2.new(w, h)
    S.D.main.Color = S.Theme.Bg
    S.D.main.Corner = S.CR(8)
    -- topbar tucks well under the opaque sidebar so its rounded-left seam is hidden
    -- topbar butts against the sidebar (no overlap -> no double-transparency darkening)
    S.D.topbar.Position = Vector2.new(x + sw, y)
    S.D.topbar.Size = Vector2.new(w - sw, S.TB)
    S.D.topbar.Corner = S.CR(6)
    S.D.seam.Visible = false
    -- fill the rounded-corner gaps at the sidebar/topbar seam with 1px slivers.
    -- each sliver lands only on pixels the bars round away, so nothing overlaps -> no darkening.
    do
        local seamX = x + sw
        local rt = S.CR(6) -- topbar corner radius
        local rs = S.CR(8) -- sidebar corner radius
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
            local o = S.D.wedges[wi]
            if not o then return end
            o.Visible = S.Win.visible
            o.Position = Vector2.new(px, py)
            o.Size = Vector2.new(wpx, hpx or 1)
            o.Color = S.Theme.Dark
        end
        -- topbar top-left corner: empty pixels sit right of the seam, near the top
        for j = 0, rt - 1 do sliver(seamX, y + j, inset(rt, j)) end
        -- topbar bottom-left corner: empty pixels right of the seam, near topbar bottom
        for j = 0, rt - 1 do sliver(seamX, y + S.TB - 1 - j, inset(rt, j)) end
        -- sidebar top-right corner: empty pixels left of the seam, near the top
        for j = 0, rs - 1 do
            local w = math.ceil(inset(rs, j))
            sliver(seamX - w, y + j, w)
        end
        for i = wi + 1, #S.D.wedges do S.D.wedges[i].Visible = false end
    end
    S.D.sidebar.Position = Vector2.new(x, y)
    S.D.sidebar.Size = Vector2.new(sw, h)
    S.D.sidebar.Corner = S.CR(8)

    S.D.sidebar.Color = S.Theme.Dark
    S.D.topbar.Color = S.Theme.Dark
    -- Rainbow theme: sidebar + topbar both at a matching 0.9 so the busy bg reads cleaner
    local barA = (S.Cfg.preset == "Rainbow") and 0.9 or S.Const.ALPHA_BAR
    S.D.sidebar.Transparency = barA * S.Cfg.opacity
    S.D.topbar.Transparency = barA * S.Cfg.opacity
    S.D.search.Color = S.Theme.Panel
    S.D.avCirc.Color = S.Theme.Control
    S.D.logo.Position = Vector2.new(x + 12, y + 6)
    S.D.logo.Color = S.Theme.C1
    S.D.logo.Corner = S.CR(7)
    S.D.logo.Visible = S.Win.visible and not UI.logoLoaded
    S.D.logoTxt.Visible = S.Win.visible and not UI.logoLoaded
    S.D.logoTxt2.Visible = S.Win.visible and not UI.logoLoaded
    S.D.logoImg.Visible = S.Win.visible and UI.logoLoaded and true or false
    S.D.logoImg.Position = Vector2.new(x + 12, y + 6)
    local lsX = x + 12 + math.floor((32 - 2 * S.CHAR_W) / 2) - 1
    S.D.logoTxt.Position = Vector2.new(lsX, y + 17)
    S.D.logoTxt2.Position = Vector2.new(lsX + 1, y + 17)
    S.D.brand.Position = Vector2.new(x + 52, y + 8)
    S.D.brand.Color = S.Theme.C1
    S.D.brand.Text = expandT > 0.05 and S.truncateB(S.BRAND, sw - 52 - 8) or ""
    S.D.brandSub.Position = Vector2.new(x + 52, y + 28)
    S.D.brandSub.Text = expandT > 0.05 and S.truncate(S.SUBTITLE or S.GameName, sw - 52 - 8) or ""

    -- sidebar dividers: centered fades that grow from the middle as the sidebar opens
    local divA = expandT
    local midX = x + sw / 2
    local halfSpan = (sw / 2 - 10) * divA
    S.layoutFade(S.D.sbDiv1, midX - halfSpan, midX + halfSpan, y + 47, "center", 0.5 * divA, S.Win.visible and divA > 0.08)
    S.layoutFade(S.D.sbDiv2, midX - halfSpan, midX + halfSpan, y + h - 66, "center", 0.5 * divA, S.Win.visible and divA > 0.08)

    local titleName = (S.activeTab == S.SETTINGS_TAB) and "Settings" or S.Tabs[S.activeTab].name
    S.D.title.Position = Vector2.new(x + sw + 16, y + 9)
    S.D.title.Color = S.Theme.Text
    local searchW = (S.Cfg.search == "Bar") and math.min(180, math.max(0, w - sw - 220)) or 0
    S.D.search.Visible = S.Win.visible and searchW > 40
    S.D.searchT.Visible = S.D.search.Visible
    S.D.searchIco.Visible = S.D.search.Visible
    S.D.searchGlow.Visible = S.D.search.Visible
    if searchW > 40 then
        local sX = x + w - 36 - searchW
        S.D.search.Position = Vector2.new(sX, y + 8)
        S.D.search.Size = Vector2.new(searchW, 20)
        S.D.search.Corner = S.CR(8)
        -- card-style glow around the field, driven by the same "Card glow" slider
        local sGlowA = math.min(1, 0.14 + 0.12 * S.Cfg.cardGlow / 100 + (S.Search.active and 0.4 or 0)) * S.Cfg.opacity
        S.D.searchGlow.Position = Vector2.new(sX - 1, y + 7)
        S.D.searchGlow.Size = Vector2.new(searchW + 2, 22)
        S.D.searchGlow.Corner = S.CR(8)
        S.D.searchGlow.Color = S.Theme.C1
        S.D.searchGlow.Transparency = sGlowA
        -- magnifier icon on the right, text to its left
        S.D.searchIco.Position = Vector2.new(sX + searchW - 18, y + 12)
        S.D.searchIco.Color = S.Search.active and S.Theme.C1 or S.Theme.Dim
        S.D.searchT.Position = Vector2.new(sX + 10, y + 12)
        if S.Search.active then
            S.D.searchT.Text = S.truncate((#S.Search.buf > 0 and S.Search.buf or "") .. "_", searchW - 30)
            S.D.searchT.Color = S.Theme.Text
        else
            S.D.searchT.Text = S.truncate("Search", searchW - 30)
            S.D.searchT.Color = S.Theme.Dim
        end
        S.Search.rect = { x = sX, y = y + 8, w = searchW, h = 20 }
    else
        S.Search.rect = nil
        if S.Search.active then S.closeSearch() end
    end
    S.D.title.Text = S.truncateB(titleName, w - sw - 16 - 50 - searchW)
    S.D.close.Position = Vector2.new(x + w - 20, y + 9)
    do
        local gx, gy = x + w - 6, y + h - 6
        local lens = { 12, 8, 4 }
        local ls = { S.D.gripL1, S.D.gripL2, S.D.gripL3 }
        for i = 1, 3 do
            local L = lens[i]
            ls[i].From = Vector2.new(gx - L, gy)
            ls[i].To = Vector2.new(gx, gy - L)
            ls[i].Color = S.Theme.Dim
        end
    end

    local iy = S.itemsTop()
    for i, it in ipairs(S.Items) do
        local top = iy + (i - 1) * S.Const.ITEM_H
        it.icon.Position = Vector2.new(x + 20, top + 10)
        it.label.Position = Vector2.new(x + 52, top + 9)
        it.label.Text = expandT > 0.05 and S.truncateB(S.Tabs[i].name, sw - 52 - 8) or ""
        it.icon.Color = (i == S.activeTab) and S.Theme.C1 or S.Theme.Dim
        it.label.Color = (i == S.activeTab) and S.Theme.C1 or S.Theme.Dim
    end
    local selShown = S.Win.visible and S.activeTab ~= S.SETTINGS_TAB
    S.D.hilite.Visible = selShown
    S.D.hiliteBar.Visible = selShown
    S.D.hiliteEdge.Visible = selShown
    local selX, selW = x + 6, math.max(8, sw - 12)
    local selY = S.itemsTop() + S.hiliteY + 2
    S.D.hilite.Position = Vector2.new(selX, selY)
    S.D.hilite.Size = Vector2.new(selW, S.Const.ITEM_H - 8)
    S.D.hilite.Corner = S.CR(6)
    S.D.hilite.Color = S.lerpColor(S.Theme.Panel, S.Theme.C1, 0.18)
    S.D.hiliteEdge.Position = Vector2.new(selX, selY)
    S.D.hiliteEdge.Size = Vector2.new(selW, S.Const.ITEM_H - 8)
    S.D.hiliteEdge.Corner = S.CR(6)
    S.D.hiliteEdge.Color = S.Theme.C1
    S.D.hiliteBar.Position = Vector2.new(selX, selY + 4)
    S.D.hiliteBar.Size = Vector2.new(3, S.Const.ITEM_H - 16)
    S.D.hiliteBar.Color = S.Theme.C1

    S.D.avCirc.Position = Vector2.new(x + 28, y + h - 36)
    S.D.avatar.Position = Vector2.new(x + 10, y + h - 54)
    local nameAvail = sw - 52 - 34
    S.D.footName.Position = Vector2.new(x + 52, y + h - 46)
    S.D.footName.Color = S.Theme.Text
    S.D.footName.Text = expandT > 0.05 and S.truncateB(S.displayName, nameAvail) or ""
    S.D.footSub.Position = Vector2.new(x + 52, y + h - 30)
    S.D.footSub.Text = expandT > 0.05 and S.truncate("@" .. S.playerName, nameAvail) or ""
    S.D.gear.Visible = S.Win.visible and expandT > 0.6
    S.D.gear.Position = Vector2.new(x + sw - 30, y + h - 44)
    S.D.gear.Color = (S.activeTab == S.SETTINGS_TAB) and S.Theme.C1 or S.Theme.Dim
    S.D.verTag.Visible = S.Win.visible
    S.D.verTag.Text = S.VERSION
    S.D.verTag.Position = Vector2.new(x + 14, y + h - 78)
    S.D.verTag.Color = S.Theme.Dim

    local cx = x + sw + S.PAD
    local cw = w - sw - S.PAD * 2 - 8
    -- theme background art: fit inside the content box (sidebar/topbar bounded), true aspect ratio
    do
        local ratio = UI.themeImgRatio[S.Cfg.preset] or S.Const.IMG_RATIO
        local maxH = h - S.TB - 6
        local maxW = cw
        -- fit within both dimensions preserving aspect -> never stretched, never spills the box
        local artW = maxH * ratio
        local artH = maxH
        if artW > maxW then
            artW = maxW
            artH = maxW / ratio
        end
        artW, artH = math.floor(artW), math.floor(artH)
        local imgData = UI.themeImg[S.Cfg.preset]
        S.D.themeImg.Visible = S.Win.visible and imgData ~= nil
        -- (re)apply Data whenever the applied theme differs, then touch Position/Size -> decode
        if imgData and UI.themeImgApplied ~= S.Cfg.preset then
            pcall(function() S.D.themeImg.Data = imgData end)
            UI.themeImgApplied = S.Cfg.preset
        end
        S.D.themeImg.Position = Vector2.new(cx + math.floor((cw - artW) / 2), y + S.TB + 2)
        S.D.themeImg.Size = Vector2.new(artW, artH)
        -- nyan background on the Rainbow theme, fit to its real aspect ratio (never stretched)
        S.D.nyan.Visible = S.Win.visible and S.Cfg.preset == "Rainbow" and UI.nyanData0 ~= nil
        if UI.nyanData0 and not UI.nyanApplied then
            pcall(function() S.D.nyan.Data = UI.nyanData0 end)
            UI.nyanApplied = true
            UI.nyanCur = 1
        end
        local nRatio = UI.nyanRatio or 1
        local nMaxH, nMaxW = h - S.TB - 6, cw
        local nW, nH = nMaxH * nRatio, nMaxH
        if nW > nMaxW then nW = nMaxW nH = nMaxW / nRatio end
        nW, nH = math.floor(nW), math.floor(nH)
        local nX = cx + math.floor((cw - nW) / 2)
        local nY = y + S.TB + 2 + math.floor(((h - S.TB - 6) - nH) / 2)
        UI.nyanRect = { x = nX, y = nY, w = nW, h = nH }
        S.D.nyan.Position = Vector2.new(nX, nY)
        S.D.nyan.Size = Vector2.new(nW, nH)
    end
    local page = S.Pages[S.activeTab]

    if not page then
        S.D.pageTxt.Position = Vector2.new(cx, y + S.TB + 20)
        S.D.pageTxt.Text = S.truncate(S.Tabs[S.activeTab].name .. " page -- components arrive soon", cw)
        S.D.sbTrack.Visible = false
        S.D.sbThumb.Visible = false
    else
        S.D.pageTxt.Text = ""
        local visTop = y + S.TB + 2
        local visBot = y + h - 6
        local viewH = visBot - visTop
        -- clamp target using last known extent, before laying out
        local preMax = page.maxScroll or 0
        if page.scrollY < 0 then page.scrollY = 0 end
        if page.scrollY > preMax then page.scrollY = preMax end
        local startY = y + S.TB + 16 - page.scrollCur
        local colGap = 12
        local colW = math.floor((cw - colGap) / 2)
        local colX = { left = cx, right = cx + colW + colGap }
        local colY = { left = startY, right = startY }

        for _, sec in ipairs(page.sections) do
            local sx = colX[sec.side] or cx
            local sy = colY[sec.side] or startY
            local swid = colW

            local hdrVis = sy >= visTop - 2 and sy <= visBot - 12
            sec.hdr.Visible = S.Win.visible and hdrVis
            sec.hdr.Position = Vector2.new(sx + 2, sy)
            sec.hdr.Color = S.Theme.Header
            sec.hdr.Text = S.truncate(sec.title, swid - 4)
            local hlx = sx + 2 + #sec.hdr.Text * S.CHAR_W + 6
            S.layoutFade(sec.hsegs, math.min(hlx, sx + swid), sx + swid, sy + 7, "left", 0.55, S.Win.visible and hdrVis)

            local py = sy + 18
            local innerX = sx + 12
            local innerW = swid - 24

            -- section collapse: colTs 1=open, 0=collapsed (click the header to toggle). rows and
            -- the panel scale toward the header exactly like the sidebar expand, just vertical.
            local colTs = sec.colT == nil and 1 or sec.colT
            colTs = colTs * colTs * (3 - 2 * colTs)
            sec.headRect = { x = sx, y = sy - 2, w = swid, h = 18 }

            local rowsSum = 0
            for _, row in ipairs(sec.rows) do rowsSum = rowsSum + S.rowEffH(row) end
            local panelH = (rowsSum + 14) * colTs
            local pTop = math.max(py, visTop)
            local pBot = math.min(py + panelH, visBot)
            local panelShown = pBot - pTop > 3
            sec.vis = panelShown
            sec.panel.Visible = S.Win.visible and panelShown
            sec.glow.Visible = false
            if panelShown then
                sec.panel.Position = Vector2.new(sx, pTop)
                sec.panel.Size = Vector2.new(swid, pBot - pTop)
                sec.panel.Corner = S.CR(6)
                sec.glow.Position = Vector2.new(sx - 1, pTop - 1)
                sec.glow.Size = Vector2.new(swid + 2, pBot - pTop + 2)
                sec.glow.Corner = S.CR(6)
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
                row.vis = rvis and shownEnough and colTs > 0.5
                row.live = rlive
                local showSmooth = (row.showT == nil) and 1 or (row.showT * row.showT * (3 - 2 * row.showT))
                row.clipMul = colTs * showSmooth
                row.rect = { x = sx, y = ry, w = swid, h = row.h }
                for _, o in ipairs(S.rowObjs(row)) do
                    o.Visible = S.Win.visible and rlive
                    o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity
                end
                if rlive then
                    if row.kind == "toggle" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        row.lbl.Text = S.truncate(row.label, innerW - 44)
                        if S.Cfg.checkbox then
                            row.track.Size = Vector2.new(18, 18)
                            row.track.Corner = S.CR(3)
                            row.track.Position = Vector2.new(sx + swid - 12 - 18, ry + 8)
                            row.trackX = sx + swid - 12 - 18
                            row.oline.Size = Vector2.new(18, 18)
                            row.oline.Corner = S.CR(3)
                            row.oline.Position = Vector2.new(sx + swid - 12 - 18, ry + 8)
                            row.knob.Size = Vector2.new(8, 8)
                            row.knob.Corner = S.CR(2)
                        else
                            row.track.Size = Vector2.new(34, 18)
                            row.track.Corner = S.CR(6)
                            row.track.Position = Vector2.new(sx + swid - 12 - 34, ry + 8)
                            row.trackX = sx + swid - 12 - 34
                            row.oline.Size = Vector2.new(34, 18)
                            row.oline.Corner = S.CR(6)
                            row.oline.Position = Vector2.new(sx + swid - 12 - 34, ry + 8)
                            row.knob.Size = Vector2.new(14, 14)
                            row.knob.Corner = S.CR(5)
                        end
                        row.trackY = ry + 8
                    elseif row.kind == "slider" then
                        row.lbl.Position = Vector2.new(innerX, ry + 6)
                        row.lbl.Text = S.truncate(row.label, innerW - 62)
                        row.chip.Position = Vector2.new(sx + swid - 12 - 52, ry + 4)
                        row.chip.Size = Vector2.new(52, 17)   -- reset so clipObj shrink doesn't stick
                        row.chip.Corner = S.CR(3)
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
                        row.box.Corner = S.CR(4)
                        row.oline.Position = Vector2.new(innerX, ry + 4)
                        row.oline.Size = Vector2.new(innerW, row.h - 8)
                        row.oline.Corner = S.CR(4)
                        local btxt = S.truncate(row.label, innerW - 8)
                        row.lbl.Text = btxt
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - #btxt * S.CHAR_W) / 2), ry + 5 + math.floor((row.h - 8 - S.FS) / 2))
                    elseif row.kind == "buttonrow" then
                        local n = #row.defs
                        local gap = 8
                        local bw = math.floor((innerW - gap * (n - 1)) / n)
                        row.bw = bw
                        for i = 1, n do
                            local bx = innerX + (i - 1) * (bw + gap)
                            row.boxes[i].Position = Vector2.new(bx, ry + 4)
                            row.boxes[i].Size = Vector2.new(bw, row.h - 8)
                            row.boxes[i].Corner = S.CR(4)
                            row.olines[i].Position = Vector2.new(bx, ry + 4)
                            row.olines[i].Size = Vector2.new(bw, row.h - 8)
                            row.olines[i].Corner = S.CR(4)
                            local bt = S.truncate(row.defs[i].label, bw - 6)
                            row.lbls[i].Text = bt
                            row.lbls[i].Position = Vector2.new(bx + math.floor((bw - #bt * S.CHAR_W) / 2), ry + 5 + math.floor((row.h - 8 - S.FS) / 2))
                        end
                    elseif row.kind == "dropdown" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        local boxW = math.max(90, math.floor(innerW * 0.45))
                        row.boxW = boxW
                        row.lbl.Text = S.truncate(row.label, innerW - boxW - 10)
                        row.box.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.box.Size = Vector2.new(boxW, 22)
                        row.box.Corner = S.CR(4)
                        row.oline.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.oline.Size = Vector2.new(boxW, 22)
                        row.oline.Corner = S.CR(4)
                        row.val.Position = Vector2.new(sx + swid - 12 - boxW + 8, ry + 10)
                        row.val.Text = S.truncate(tostring(row.value), boxW - 28)
                        row.arr.Position = Vector2.new(sx + swid - 12 - 14, ry + 10)
                    elseif row.kind == "color" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        row.lbl.Text = S.truncate(row.label, innerW - 28)
                        row.sw.Position = Vector2.new(sx + swid - 12 - 16, ry + 9)
                        row.sw.Size = Vector2.new(16, 16)   -- reset each layout so clipObj shrink doesn't stick
                        row.sw.Corner = S.CR(3)
                        row.sw.Color = row.color
                    elseif row.kind == "keybind" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        local kw = math.max(34, #S.keyName(row.vk) * S.CHAR_W + 14)
                        row.kw = kw
                        row.lbl.Text = S.truncate(row.label, innerW - kw - 10)
                        row.chip.Position = Vector2.new(sx + swid - 12 - kw, ry + 8)
                        row.chip.Size = Vector2.new(kw, 17)
                        row.chip.Corner = S.CR(3)
                        row.chipX = sx + swid - 12 - kw
                        row.chipY = ry + 8
                    elseif row.kind == "textbox" then
                        row.lbl.Position = Vector2.new(innerX, ry + 3)
                        row.lbl.Text = S.truncate(row.label, innerW)
                        row.box.Position = Vector2.new(innerX, ry + 18)
                        row.box.Size = Vector2.new(innerW, 24)
                        row.box.Corner = S.CR(4)
                        row.oline.Position = Vector2.new(innerX, ry + 18)
                        row.oline.Size = Vector2.new(innerW, 24)
                        row.oline.Corner = S.CR(4)
                        row.txt.Position = Vector2.new(innerX + 8, ry + 23)
                    elseif row.kind == "divider" then
                        local dtxt = S.truncate(row.label, innerW - 60)
                        row.lbl.Text = dtxt
                        local tw = #dtxt * S.CHAR_W
                        local mid = innerX + innerW / 2
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - tw) / 2), ry + 6)
                        local gap = 8
                        S.layoutFade(row.segsL, innerX, mid - tw / 2 - gap, ry + 12, "right", 0.5, S.Win.visible and rvis)
                        S.layoutFade(row.segsR, mid + tw / 2 + gap, innerX + innerW, ry + 12, "left", 0.5, S.Win.visible and rvis)
                    elseif row.kind == "note" then
                        row.lbl.Position = Vector2.new(innerX, ry + 5)
                        row.lbl.Text = S.truncate(row.label, innerW)
                    end
                end
                ry = ry + S.rowEffH(row) * colTs
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
            S.D.sbTrack.Visible = S.Win.visible
            S.D.sbTrack.Position = Vector2.new(trackX + 1, trackY)
            S.D.sbTrack.Size = Vector2.new(2, trackH)
            S.D.sbThumb.Visible = S.Win.visible
            S.D.sbThumb.Position = Vector2.new(trackX + 1, tY)
            S.D.sbThumb.Size = Vector2.new(2, thumbH)
            S.D.sbThumb.Color = S.Theme.Track
            UI.sbRect = { x = trackX - 3, y = trackY, w = 10, h = trackH, thumbH = thumbH, maxScroll = maxScroll }
        else
            S.D.sbTrack.Visible = false
            S.D.sbThumb.Visible = false
            for i = 1, #S.D.sbGlowSegs do S.D.sbGlowSegs[i].Visible = false end
            UI.sbRect = nil
        end
    end

    -- popouts follow anchors (close if anchor culled)
    if S.Drop.open and (not S.Drop.open.vis) then S.hardCloseDropdown() end
    if S.Pick.open and (not S.Pick.open.vis) then S.closePicker() end

    if S.Drop.open and S.Drop.open.rect then
        local row = S.Drop.open
        local bw = row.boxW or 100
        local bx = row.rect.x + row.rect.w - 12 - bw
        local by = row.rect.y + 30
        local filtered = S.dropFiltered()
        local total = #filtered
        local visN = math.min(total, S.Const.MAXOPT)
        local maxSc = math.max(0, total - S.Const.MAXOPT)
        if S.Drop.scroll > maxSc then S.Drop.scroll = maxSc end
        if S.Drop.scroll < 0 then S.Drop.scroll = 0 end
        S.Drop.bg.Visible = true
        S.Drop.bg.Color = S.Theme.Dark
        S.Drop.searchBox.Color = S.Theme.Control
        S.Drop.bg.Position = Vector2.new(bx, by)
        S.Drop.bg.Size = Vector2.new(bw, 28 + visN * 24 + 6)
        S.Drop.bg.Corner = S.CR(5)
        S.Drop.searchBox.Visible = true
        S.Drop.searchBox.Position = Vector2.new(bx + 4, by + 4)
        S.Drop.searchBox.Size = Vector2.new(bw - 8, 20)
        S.Drop.searchBox.Corner = S.CR(4)
        S.Drop.searchTxt.Visible = true
        S.Drop.searchTxt.Position = Vector2.new(bx + 10, by + 8)
        S.Drop.searchTxt.Text = S.truncate((#S.Drop.searchBuf > 0 and S.Drop.searchBuf or "Search") .. "_", bw - 24)
        S.Drop.searchTxt.Color = #S.Drop.searchBuf > 0 and S.Theme.Text or S.Theme.Dim
        local oy = by + 28
        for i = 1, S.Const.MAXOPT do
            local r = S.Drop.rows[i]
            local idx = i + S.Drop.scroll
            if i <= visN and filtered[idx] then
                r.bg.Position = Vector2.new(bx + 4, oy + (i - 1) * 24)
                r.bg.Size = Vector2.new(bw - 8 - (total > S.Const.MAXOPT and 6 or 0), 22)
                r.bg.Corner = S.CR(4)
                r.bg.Visible = true
                r.txt.Position = Vector2.new(bx + 12, oy + 4 + (i - 1) * 24)
                r.txt.Text = S.truncate(filtered[idx], bw - 44)
                r.txt.Visible = true
                r.chk.Position = Vector2.new(bx + bw - 18 - (total > S.Const.MAXOPT and 6 or 0), oy + 4 + (i - 1) * 24)
                r.chk.Visible = filtered[idx] == tostring(row.value)
                r.chk.Color = S.Theme.C1
            else
                r.bg.Visible = false
                r.txt.Visible = false
                r.chk.Visible = false
            end
        end
        if total > S.Const.MAXOPT then
            local listH = visN * 24
            local thH = math.max(16, math.floor(listH * S.Const.MAXOPT / total))
            local thY = oy + (maxSc > 0 and (S.Drop.scroll / maxSc) * (listH - thH) or 0)
            S.Drop.sbT.Visible = true
            S.Drop.sbT.Position = Vector2.new(bx + bw - 7, thY)
            S.Drop.sbT.Size = Vector2.new(4, thH)
            S.Drop.sbT.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, 0.4)
            S.Drop.dropSb = { x = bx + bw - 10, y = oy, w = 10, h = listH, thH = thH, maxSc = maxSc }
        else
            S.Drop.sbT.Visible = false
            S.Drop.dropSb = nil
        end
        S.Drop.geom = { bx = bx, by = by, bw = bw, oy = oy, visN = visN }

        -- open/close transform: slide down from a few px up + fade the whole popout in/out, list
        -- collapsing toward the top. transparency is set from each object's BASE (not multiplied
        -- in place) so it never compounds across frames; runs every frame incl. fully-open (aT=1).
        local aT = math.max(0, math.min(1, S.Drop.animT or 1))
        aT = aT * aT * (3 - 2 * aT)
        local yoff = (1 - aT) * -12
        local baseY = by
        local applyAnim = function(o)
            if not o or not o.Visible then return end
            o.Position = Vector2.new(o.Position.X, o.Position.Y + yoff)
            o.Transparency = (S.Bases[o] or 1) * aT
        end
        -- collapse the list height; rows past the shrinking edge fold away
        local fullH = S.Drop.bg.Size.Y
        local collapsedH = math.max(6, fullH * (0.25 + 0.75 * aT))
        for i = 1, S.Const.MAXOPT do
            local r = S.Drop.rows[i]
            if r.bg.Visible and (r.bg.Position.Y + r.bg.Size.Y) > (baseY + collapsedH) then
                r.bg.Visible = false r.txt.Visible = false r.chk.Visible = false
            end
        end
        applyAnim(S.Drop.bg)
        S.Drop.bg.Size = Vector2.new(S.Drop.bg.Size.X, collapsedH)
        applyAnim(S.Drop.searchBox)
        applyAnim(S.Drop.searchTxt)
        applyAnim(S.Drop.sbT)
        for i = 1, S.Const.MAXOPT do
            applyAnim(S.Drop.rows[i].bg)
            applyAnim(S.Drop.rows[i].txt)
            applyAnim(S.Drop.rows[i].chk)
        end
    end

    if S.Pick.open and S.Pick.open.rect then
        local row = S.Pick.open
        local pw = S.Const.SV_COLS * S.Const.SV_CELL + 24
        local ph = S.Const.SV_ROWS * S.Const.SV_CELL + 24 + 20 + 32
        local px = row.rect.x + row.rect.w - pw - 4
        local pyy = math.min(row.rect.y + 30, S.Win.y + S.Win.h - ph - 6)
        S.Pick.bg.Position = Vector2.new(px, pyy)
        S.Pick.bg.Size = Vector2.new(pw, ph)
        S.Pick.bg.Corner = S.CR(6)
        S.Pick.gx = px + 12
        S.Pick.gy = pyy + 12
        for r = 1, S.Const.SV_ROWS do
            local yA = math.floor(S.Pick.gy + (r - 1) * S.Const.SV_CELL)
            local yB = math.floor(S.Pick.gy + r * S.Const.SV_CELL)
            local hgt = math.max(1, yB - yA + 1)
            for c = 1, S.Const.SV_COLS do
                local xA = math.floor(S.Pick.gx + (c - 1) * S.Const.SV_CELL)
                local xB = math.floor(S.Pick.gx + c * S.Const.SV_CELL)
                local cell = S.Pick.sv[r][c]
                cell.Position = Vector2.new(xA, yA)
                cell.Size = Vector2.new(math.max(1, xB - xA + 1), hgt)
                cell.Color = S.hsv2rgb(S.Pick.h, (c - 1) / (S.Const.SV_COLS - 1), 1 - (r - 1) / (S.Const.SV_ROWS - 1))
            end
        end
        local gridW = S.Const.SV_COLS * S.Const.SV_CELL
        S.Pick.svCur.Position = Vector2.new(S.Pick.gx + S.Pick.s * gridW - 4, S.Pick.gy + (1 - S.Pick.v) * (S.Const.SV_ROWS * S.Const.SV_CELL) - 4)
        S.Pick.hy = S.Pick.gy + S.Const.SV_ROWS * S.Const.SV_CELL + 8
        local hw = gridW / S.Const.HUE_SEGS
        for i = 1, S.Const.HUE_SEGS do
            local xA = math.floor(S.Pick.gx + (i - 1) * hw)
            local xB = math.floor(S.Pick.gx + i * hw)
            S.Pick.hueSegs[i].Position = Vector2.new(xA, S.Pick.hy)
            S.Pick.hueSegs[i].Size = Vector2.new(math.max(1, xB - xA + 1), 12)
            S.Pick.hueSegs[i].Color = S.hsv2rgb((i - 1) / (S.Const.HUE_SEGS - 1), 0.92, 0.95)
        end
        S.Pick.hueCur.Position = Vector2.new(S.Pick.gx + S.Pick.h * gridW - 2, S.Pick.hy - 2)
        S.Pick.hueCur.Size = Vector2.new(5, 16)
        local rowY = S.Pick.hy + 20
        S.Pick.prev.Position = Vector2.new(S.Pick.gx, rowY)
        S.Pick.prev.Size = Vector2.new(30, 20)
        S.Pick.prev.Corner = S.CR(3)
        S.Pick.prev.Color = S.pickerColor()
        S.Pick.hexBox.Position = Vector2.new(S.Pick.gx + 38, rowY)
        S.Pick.hexBox.Size = Vector2.new(gridW - 38, 20)
        S.Pick.hexBox.Corner = S.CR(3)
        S.Pick.hexTxt.Position = Vector2.new(S.Pick.gx + 46, rowY + 4)
        S.Pick.hexTxt.Text = S.Pick.hexFocus and (S.Pick.hexBuf .. "_") or S.hexOf(S.pickerColor())
        S.Pick.hexRowY = rowY
    end

    -- search results popout, anchored under the search field
    if S.Search.active and S.Search.rect and #S.Search.results > 0 then
        local n = #S.Search.results
        local rowH = 26
        local pw = math.max(S.Search.rect.w, 268)
        local px = S.Search.rect.x + S.Search.rect.w - pw
        local py = S.Search.rect.y + S.Search.rect.h + 4
        local ph = n * rowH + 8
        S.Search.bg.Visible = true
        S.Search.bg.Color = S.Theme.Dark
        S.Search.bg.Position = Vector2.new(px, py)
        S.Search.bg.Size = Vector2.new(pw, ph)
        S.Search.bg.Corner = S.CR(5)
        for i = 1, S.Const.SEARCH_MAX do
            local r = S.Search.rows[i]
            local res = S.Search.results[i]
            if res then
                local ry = py + 4 + (i - 1) * rowH
                r.bg.Position = Vector2.new(px + 4, ry)
                r.bg.Size = Vector2.new(pw - 8, rowH - 2)
                r.bg.Corner = S.CR(4)
                r.bg.Visible = true
                local tabW = #res.tab * S.CHAR_W
                local tabX = px + pw - 10 - tabW
                local iconX = tabX - 6 - 13
                r.tab.Text = res.tab
                r.tab.Position = Vector2.new(tabX, ry + 5)
                r.tab.Color = S.Theme.Dim
                r.tab.Visible = true
                r.icon.Position = Vector2.new(iconX, ry + 5)
                r.icon.Color = S.Theme.C1
                r.icon.Visible = true
                r.txt.Text = S.truncate(res.label, (iconX - 8) - (px + 12))
                r.txt.Position = Vector2.new(px + 12, ry + 5)
                r.txt.Visible = true
            else
                r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
            end
        end
        S.Search.geom = { px = px, py = py, pw = pw, rowH = rowH, n = n }
    else
        S.Search.bg.Visible = false
        for i = 1, S.Const.SEARCH_MAX do
            local r = S.Search.rows[i]
            r.bg.Visible = false r.txt.Visible = false r.icon.Visible = false r.tab.Visible = false
        end
        S.Search.geom = nil
    end

    S.Win.dirty = false
end

function S.relayout()
    local ok, e = pcall(S.relayoutRaw)
    if not ok then print("FALUI|relayout ERROR: " .. tostring(e)) end
end

-- ========== per-frame updates ==========
S.hoveredRow, S.hoverT = nil, 0
S.navHovT, S.navHovIdx = 0, 0
S.animClock = 0

function S.hideTip()
    S.D.tipBox.Visible = false
    S.D.tipL1.Visible = false
    S.D.tipL2.Visible = false
    S.D.tipL3.Visible = false
end

function S.wrapText(s, maxChars)
    local lines, cur = {}, ""
    for word in tostring(s):gmatch("%S+") do
        if #cur == 0 then cur = word
        elseif #cur + 1 + #word <= maxChars then cur = cur .. " " .. word
        else table.insert(lines, cur) cur = word if #lines >= 3 then break end end
    end
    if #cur > 0 and #lines < 3 then table.insert(lines, cur) end
    return lines
end

function S.updateControls(dt, mx, my)
    S.animClock = S.animClock + dt
    local page = S.Pages[S.activeTab]
    local newHovered = nil
    local aeF = S.Cfg.animations and (1 - (0.000001 ^ dt)) or 1
    local blockRows = S.Drop.open ~= nil or S.Pick.open ~= nil
    local secEase = S.Cfg.animations and (1 - (0.0000001 ^ dt)) or 1
    if page then
        for _, sec in ipairs(page.sections) do
            -- animate section collapse (same ease as the sidebar expand, just vertical)
            if sec.colT == nil then sec.colT = 1 end
            local ct = sec.collapsed and 0 or 1
            if sec.colT ~= ct then
                sec.colT = sec.colT + (ct - sec.colT) * secEase
                if math.abs(sec.colT - ct) < 0.003 then sec.colT = ct end
                S.Win.dirty = true
            end
            -- animate conditional rows (show/hide slider) -> drives fade + smooth card resize
            for _, row in ipairs(sec.rows) do
                if row.showIf then
                    local target = (S.Cfg.preset == row.showIf) and 1 or 0
                    if row.showT ~= target then
                        row.showT = row.showT + (target - row.showT) * aeF
                        if math.abs(row.showT - target) < 0.004 then row.showT = target end
                        S.Win.dirty = true
                    end
                end
            end
            local secHov = S.Cfg.hoverFx and not blockRows and sec.vis and sec.rect and S.inRect(mx, my, sec.rect.x, sec.rect.y, sec.rect.w, sec.rect.h) and mx > (S.Win.x + S.Sb.cur)
            sec.hovT = sec.hovT + ((secHov and 1 or 0) - sec.hovT) * aeF
            sec.panel.Color = S.lerpColor(S.Theme.Panel, S.Theme.PanelHov, sec.hovT)
            local glowA = math.min(1, 0.16 + (0.10 * S.Cfg.cardGlow / 100) + 0.5 * sec.hovT) * S.Cfg.opacity
            sec.glow.Color = S.Theme.C1
            sec.glow.Transparency = glowA
            sec.glow.Visible = S.Win.visible and sec.vis and glowA > 0.03
            for _, row in ipairs(sec.rows) do
                if row.vis then
                    local r = row.rect
                    local hov = not blockRows and r and S.inRect(mx, my, r.x, r.y, r.w, r.h) and mx > (S.Win.x + S.Sb.cur)
                    local hovTarget = (S.Cfg.hoverFx and hov) and 1 or 0
                    row.hovT = row.hovT + (hovTarget - row.hovT) * aeF
                    if hov and row.tip then newHovered = row end
                    if row.kind == "toggle" then
                        local target = row.value and 1 or 0
                        row.knobT = row.knobT + (target - row.knobT) * aeF
                        if math.abs(row.knobT - target) < 0.01 then row.knobT = target end
                        local baseTrack = S.lerpColor(S.Theme.Track, S.Theme.C1, row.knobT)
                        if S.Cfg.checkbox then
                            row.knob.Position = Vector2.new(row.trackX + 5, row.trackY + 5)
                            row.knob.Visible = S.Win.visible and row.vis and row.knobT > 0.1
                        else
                            row.knob.Visible = S.Win.visible and row.vis
                            row.knob.Position = Vector2.new(row.trackX + 2 + row.knobT * (34 - 4 - 14), row.trackY + 2)
                        end
                        row.track.Color = S.lerpColor(baseTrack, S.Theme.White, 0.10 * row.hovT)
                        row.oline.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                    elseif row.kind == "slider" then
                        local t = (row.value - row.min) / (row.max - row.min)
                        local fw = row.barW * t
                        local segW = fw / S.Const.GRAD_SEGS
                        for i = 1, S.Const.GRAD_SEGS do
                            local seg = row.segs[i]
                            if segW > 0.5 then
                                seg.Visible = S.Win.visible
                                seg.Position = Vector2.new(row.barX + (i - 1) * segW, row.barY)
                                seg.Size = Vector2.new(math.max(1, math.ceil(segW)), 3)
                                seg.Color = S.lerpColor(S.Theme.C1, S.Theme.C2, (i - 1) / math.max(1, S.Const.GRAD_SEGS - 1))
                            else
                                seg.Visible = false
                            end
                        end
                        row.knob.Position = Vector2.new(row.barX + fw, row.barY + 1)
                        row.knobX = row.barX + fw
                        if S.Focus.row == row then
                            row.chipT.Text = (row.buf or "") .. "_"
                        else
                            row.chipT.Text = tostring(math.floor(row.value + 0.5)) .. row.suffix
                        end
                        if row.chipRect then
                            row.chipT.Position = Vector2.new(row.chipRect.x + math.floor((row.chipRect.w - #row.chipT.Text * (S.CHAR_W - 1)) / 2), row.chipRect.y + 2)
                        end
                        row.chip.Color = S.Theme.Control
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                    elseif row.kind == "button" then
                        row.box.Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), row.hovT)
                        row.oline.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                    elseif row.kind == "buttonrow" then
                        for i = 1, #row.defs do
                            local bw = row.bw or 60
                            local bx = row.rect.x + 12 + (i - 1) * (bw + 8)
                            local bHov = not blockRows and S.inRect(mx, my, bx, row.rect.y + 4, bw, row.h - 8)
                            row.hovTs[i] = row.hovTs[i] + (((S.Cfg.hoverFx and bHov) and 1 or 0) - row.hovTs[i]) * aeF
                            row.boxes[i].Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), row.hovTs[i])
                            row.olines[i].Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovTs[i])
                            row.lbls[i].Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovTs[i])
                        end
                    elseif row.kind == "dropdown" then
                        row.box.Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), row.hovT)
                        row.oline.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                    elseif row.kind == "color" then
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                        row.sw.Color = row.color
                    elseif row.kind == "keybind" then
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                        row.chipT.Text = (S.Capture.row == row) and "..." or S.keyName(row.vk)
                        if row.chipX then
                            row.chipT.Position = Vector2.new(row.chipX + math.floor(((row.kw or 34) - #row.chipT.Text * (S.CHAR_W - 1)) / 2), row.chipY + 2)
                        end
                        row.chip.Color = (S.Capture.row == row) and S.lerpColor(S.Theme.Control, S.Theme.C1, 0.3) or S.Theme.Control
                    elseif row.kind == "textbox" then
                        row.box.Color = (S.Focus.row == row) and S.lerpColor(S.Theme.Control, S.Theme.White, 0.08) or S.Theme.Control
                        row.oline.Color = (S.Focus.row == row) and S.Theme.C1 or S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.txt.Text = S.truncate(row.value .. ((S.Focus.row == row) and "_" or ""), (row.rect.w - 24 - 16))
                    end
                end
            end
        end
    end

    if S.Drop.open and S.Drop.geom then
        local g = S.Drop.geom
        for i = 1, g.visN do
            local hov = S.inRect(mx, my, g.bx + 4, g.oy + (i - 1) * 24, g.bw - 8, 22)
            S.Drop.hovT[i] = S.Drop.hovT[i] + (((S.Cfg.hoverFx and hov) and 1 or 0) - S.Drop.hovT[i]) * aeF
            S.Drop.rows[i].bg.Transparency = 0.85 * S.Drop.hovT[i] * S.Cfg.opacity
            S.Drop.rows[i].txt.Color = S.lerpColor(S.Theme.Text, S.Theme.White, S.Drop.hovT[i])
        end
    end

    if S.Search.active and S.Search.geom then
        local g = S.Search.geom
        for i = 1, g.n do
            local r = S.Search.rows[i]
            local hov = S.inRect(mx, my, g.px + 4, g.py + 4 + (i - 1) * g.rowH, g.pw - 8, g.rowH - 2)
            S.Search.hovT[i] = S.Search.hovT[i] + (((S.Cfg.hoverFx and hov) and 1 or 0) - S.Search.hovT[i]) * aeF
            r.bg.Transparency = 0.85 * S.Search.hovT[i] * S.Cfg.opacity
            r.txt.Color = S.lerpColor(S.Theme.Text, S.Theme.White, S.Search.hovT[i])
        end
    end

    -- sidebar item hover (softer fill, img4 bottom)
    do
        local hitIdx = 0
        local iy = S.itemsTop()
        if mx > S.Win.x and mx < S.Win.x + S.Sb.cur and not blockRows then
            for i = 1, #S.Tabs do
                if S.inRect(mx, my, S.Win.x, iy + (i - 1) * S.Const.ITEM_H, S.Sb.cur, S.Const.ITEM_H) then hitIdx = i break end
            end
        end
        if hitIdx ~= 0 and hitIdx ~= S.activeTab then S.navHovIdx = hitIdx end
        local want = (hitIdx ~= 0 and hitIdx ~= S.activeTab and S.Cfg.hoverFx) and 1 or 0
        S.navHovT = S.navHovT + (want - S.navHovT) * aeF
        if S.navHovIdx ~= 0 and S.navHovT > 0.02 and S.Win.visible then
            S.D.navHover.Visible = true
            S.D.navHover.Position = Vector2.new(S.Win.x + 6, iy + (S.navHovIdx - 1) * S.Const.ITEM_H + 2)
            S.D.navHover.Size = Vector2.new(math.max(8, S.Sb.cur - 12), S.Const.ITEM_H - 8)
            S.D.navHover.Corner = S.CR(6)
            S.D.navHover.Color = S.lerpColor(S.Theme.Panel, S.Theme.PanelHov, S.navHovT)
            S.D.navHover.Transparency = (0.72 - 0.35 * S.navHovT) * S.Cfg.opacity
        else
            S.D.navHover.Visible = false
        end
    end

    if newHovered ~= S.hoveredRow then
        S.hoveredRow = newHovered
        S.hoverT = 0
        S.hideTip()
    elseif S.hoveredRow and S.hoveredRow.tip then
        S.hoverT = S.hoverT + dt
        if S.hoverT > 0.4 then
            local lines = S.wrapText(S.hoveredRow.tip, 30)
            local maxLen = 0
            for _, l in ipairs(lines) do maxLen = math.max(maxLen, #l) end
            local tw = maxLen * S.CHAR_W + 16
            local th = #lines * 15 + 10
            local tx = mx + 14
            local ty = my + 18
            if tx + tw > S.Win.x + S.Win.w then tx = mx - tw - 6 end
            S.D.tipBox.Position = Vector2.new(tx, ty)
            S.D.tipBox.Size = Vector2.new(tw, th)
            S.D.tipBox.Color = S.Theme.Control
            S.D.tipBox.Visible = true
            local ls = { S.D.tipL1, S.D.tipL2, S.D.tipL3 }
            for i = 1, 3 do
                ls[i].Text = lines[i] or ""
                ls[i].Position = Vector2.new(tx + 8, ty + 5 + (i - 1) * 15)
                ls[i].Visible = lines[i] ~= nil
            end
        end
    end
end

-- ========== visibility ==========
function S.setVisible(v)
    S.Win.visible = v
    for _, o in pairs(S.D) do
        if S.isDGroup(o) then
            for _, s in ipairs(o) do s.Visible = false end
        else
            o.Visible = v
        end
    end
    for _, it in ipairs(S.Items) do
        it.icon.Visible = v
        it.label.Visible = v
    end
    for idx = 1, S.SETTINGS_TAB do S.setPageVisible(idx, false) end
    if v then S.setPageVisible(S.activeTab, true) end
    S.hardCloseDropdown()
    S.closePicker()
    S.closeSearch()
    S.hideTip()
    S.Capture.row = nil
    S.Focus.row = nil
    if not v then
        for _, f in ipairs(S.Snow.flakes) do for _, l in ipairs(f.lines) do l.Visible = false end end
        S.Snow.hidden = true
    end
    if v then
        S.D.gear.Visible = false
        S.D.verTag.Visible = false
        S.D.search.Visible = false
        S.D.searchT.Visible = false
        S.D.sbTrack.Visible = false
        S.D.sbThumb.Visible = false
        for i = 1, #S.D.sbGlowSegs do S.D.sbGlowSegs[i].Visible = false end
        S.D.navHover.Visible = false
        S.Win.dirty = true
    end
    pcall(setrobloxinput, not v)
end

for _, sec in ipairs(S.Pages[S.SETTINGS_TAB].sections) do
    for _, row in ipairs(sec.rows) do
        if row.kind == "button" and row.label == "Minimize" then
            row.onClick = function() S.setVisible(false) end
        end
    end
end

function S.switchTab(i)
    if i == S.activeTab then return end
    S.setPageVisible(S.activeTab, false)
    S.activeTab = i
    S.setPageVisible(S.activeTab, true)
    S.hideTip()
    S.Win.dirty = true
end

-- ========== search logic ==========
S.SEARCHABLE = { toggle = true, slider = true, dropdown = true, button = true, color = true, keybind = true, textbox = true }
-- score: lower is better. exact-ish substring beats a fuzzy subsequence match; earlier match wins.
function S.searchScore(label, q)
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

function S.tabNameOf(idx)
    if idx == S.SETTINGS_TAB then return "Settings" end
    return (S.Tabs[idx] and S.Tabs[idx].name) or ("Tab " .. idx)
end

function S.buildSearch()
    local q = S.Search.buf:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local scored = {}
    if q ~= "" then
        for idx = 1, S.SETTINGS_TAB do
            local page = S.Pages[idx]
            if page then
                for _, sec in ipairs(page.sections) do
                    for _, row in ipairs(sec.rows) do
                        if S.SEARCHABLE[row.kind] and type(row.label) == "string" and #row.label > 0 then
                            local sc = S.searchScore(row.label, q)
                            if sc then
                                table.insert(scored, { label = row.label, tabIdx = idx, tab = S.tabNameOf(idx), row = row, sec = sec, score = sc })
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
    S.Search.results = {}
    for i = 1, math.min(S.Const.SEARCH_MAX, #scored) do S.Search.results[i] = scored[i] end
end

function S.gotoResult(res)
    if not res then return end
    S.switchTab(res.tabIdx)
    S.Search.focus = res              -- one-shot: scroll the row into view once it's laid out
    S.closeSearch()
    S.Win.dirty = true
end

-- ========== typing ==========
function S.edgeKey(vk)
    local down = iskeypressed(vk)
    local was = S.keyStates[vk]
    S.keyStates[vk] = down
    return down and not was
end

function S.pollTyping(applyChar, applyBksp, applyDone)
    local shift = iskeypressed(0x10)
    if S.edgeKey(0x08) then applyBksp() end
    if S.edgeKey(0x0D) or S.edgeKey(0x1B) then applyDone() return end
    if S.edgeKey(0x20) then applyChar(" ") end
    for vk = 0x30, 0x39 do
        if S.edgeKey(vk) then applyChar(string.char(vk)) end
    end
    for vk = 0x41, 0x5A do
        if S.edgeKey(vk) then
            local ch = string.char(vk)
            if not shift then ch = ch:lower() end
            applyChar(ch)
        end
    end
    if S.edgeKey(0xBD) then applyChar(shift and "_" or "-") end
    if S.edgeKey(0xBE) then applyChar(".") end
    if S.edgeKey(0xDE) or S.edgeKey(0xBF) then applyChar("#") end
end

-- where autosave (and save-on-unload) writes:
--   1. the config currently selected in the "Config" dropdown, if any
--   2. otherwise the auto-load config, if one is set
--   3. otherwise the default settings.json
function S.saveTargetPath()
    -- live dropdown values are the source of truth; both "none" -> default settings.json
    local sel = S.rConfigDrop and S.rConfigDrop.value
    if sel and sel ~= "" and sel ~= "none" then
        return S.cfgDir() .. "/" .. sel .. ".json"
    end
    local al = S.rAutoLoad and S.rAutoLoad.value
    if al and al ~= "" and al ~= "none" then
        return S.cfgDir() .. "/" .. al .. ".json"
    end
    return S.FOLDER .. "/settings.json"
end

function S.saveSettings()
    S.ensureCfgDir()
    pcall(writefile, S.saveTargetPath(), S.snapshot())
end

-- ========== main loop ==========
S.RunService = game:GetService("RunService")
-- Players service AND LocalPlayer can both be nil right at inject; wait (bounded) for both so
-- nothing here indexes nil and crashes the whole script.
S.Players = game:GetService("Players")
S.LocalPlayer = S.Players.LocalPlayer
if not S.LocalPlayer then
    local t0 = os.clock()
    repeat
        task.wait()
        if not S.Players then S.Players = game:GetService("Players") end
        S.LocalPlayer = S.Players and S.Players.LocalPlayer
    until S.LocalPlayer or (os.clock() - t0) > 10
end
S.mouse = S.LocalPlayer and S.LocalPlayer:GetMouse() or nil
if S.LocalPlayer then
    S.playerName = tostring(S.LocalPlayer.Name)
    local dn = S.LocalPlayer.DisplayName
    S.displayName = (dn and #tostring(dn) > 0) and tostring(dn) or S.playerName
end

S.In = { x = 0, y = 0, down = false, wasDown = false, pressed = false, released = false }
S.Drag = { mode = nil, ox = 0, oy = 0, row = nil, sy = 0, startScroll = 0, pendIdx = 0, startDropScroll = 0 }
S.scrollGlowT = 0
S.dropGlowT = 0
S.wheelPulse = 0
S.keyWas = false
S.errCount = 0
S.lastClock = os.clock()
S.runT = 0
S.saveTimer = 0
S.nyanClock = 0

function S.curPage() return S.Pages[S.activeTab] end

function S.doScroll(d)
    local page = S.curPage()
    if page and S.Win.visible then
        page.scrollY = math.max(0, math.min((page.maxScroll or 0), page.scrollY + d))
        S.wheelPulse = 0.45
        S.Win.dirty = true
    end
end

pcall(function() table.insert(UI.WheelConns, S.mouse.WheelForward:Connect(function() S.doScroll(-34) end)) end)
pcall(function() table.insert(UI.WheelConns, S.mouse.WheelBackward:Connect(function() S.doScroll(34) end)) end)
pcall(function()
    local uis = game:GetService("UserInputService")
    table.insert(UI.WheelConns, uis.InputChanged:Connect(function(io)
        pcall(function()
            if tostring(io.UserInputType):find("MouseWheel") then
                local z = io.Position.Z
                if z ~= 0 then S.doScroll(z > 0 and -34 or 34) end
            end
        end)
    end))
end)

function S.sliderFromMouse(row)
    local t = math.max(0, math.min(1, (S.In.x - row.barX) / row.barW))
    local v = math.floor(row.min + t * (row.max - row.min) + 0.5)
    if v ~= row.value then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
        if row.flag then S.markChanged() end
    end
end

-- trim one object to the vertical viewport [top,bot]. rectangles are physically cut (position
-- + height shrunk, rounding preserved) so the part outside the UI is truly gone; glyphs/knobs
-- can't be cut, so they fade by the fraction inside. `mul` is an extra alpha (row show/hide fade).
function S.clipObj(o, top, bot, mul)
    if not o or not o.Visible then return end
    mul = mul or 1
    local s = S.Shapes[o]
    if s == "Square" then
        local p, sz = o.Position, o.Size
        local y0, y1 = p.Y, p.Y + sz.Y
        if y1 <= top or y0 >= bot then o.Visible = false return end
        local ny0, ny1 = math.max(y0, top), math.min(y1, bot)
        if ny0 > y0 or ny1 < y1 then
            o.Position = Vector2.new(p.X, ny0)
            o.Size = Vector2.new(sz.X, ny1 - ny0)
        end
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * mul
    elseif s == "Text" then
        local p = o.Position
        local hgt = tonumber(o.Size) or S.FS
        local vis = math.min(p.Y + hgt, bot) - math.max(p.Y, top)
        if vis <= 0 then o.Visible = false return end
        local frac = math.max(0, math.min(1, vis / hgt))
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * frac * mul
    elseif s == "Circle" then
        local p = o.Position
        local r = tonumber(o.Radius) or 5
        local vis = math.min(p.Y + r, bot) - math.max(p.Y - r, top)
        if vis <= 0 then o.Visible = false return end
        local frac = math.max(0, math.min(1, vis / (2 * r)))
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * frac * mul
    end
end

function S.clipRows()
    local page = S.Pages[S.activeTab]
    if not page or not S.Win.visible then return end
    local top = S.Win.y + S.TB + 2
    local bot = S.Win.y + S.Win.h - 6
    for _, sec in ipairs(page.sections) do
        S.clipObj(sec.hdr, top, bot)
        for _, row in ipairs(sec.rows) do
            if row.live then
                local mul = row.clipMul or 1
                for _, o in ipairs(S.rowObjs(row)) do S.clipObj(o, top, bot, mul) end
            end
        end
    end
end

function S.frame()
    local now = os.clock()
    local dt = math.min(now - S.lastClock, 0.1)
    S.lastClock = now
    S.runT = S.runT + dt

    if S.mouse then S.In.x, S.In.y = S.mouse.X, S.mouse.Y end
    S.In.wasDown = S.In.down
    S.In.down = ismouse1pressed()
    S.In.pressed = S.In.down and not S.In.wasDown
    S.In.released = (not S.In.down) and S.In.wasDown

    if UI.created and not S.Capture.row and not S.Focus.row and not S.Pick.hexFocus and not S.Drop.open and not S.Search.active then
        local k = iskeypressed(S.Cfg.menuKey)
        if k and not S.keyWas then S.setVisible(not S.Win.visible) end
        S.keyWas = k
    end

    S.updateSnow(dt, S.runT)

    if not S.Win.visible then return end

    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    S.Sb.max = math.max(140, math.min(380, math.floor(w * 0.29)))

    if S.Cfg.preset == "Rainbow" then
        S.hue = (S.hue + dt * (S.Cfg.rainbowSpeed / 100) * 0.15) % 1
        S.Theme.C1 = S.hsv2rgb(S.hue, 0.5, 0.85)
        S.Theme.C2 = S.hsv2rgb((S.hue + 0.08) % 1, 0.55, 0.9)
        S.Theme.Dark = S.hsv2rgb(S.hue, 0.55, 0.32)   -- sidebar + topbar cycle too; light Mono bg stays
        S.Win.dirty = true
    end

    -- nyan background frame animation (swaps Data + touches Position so Matcha re-decodes)
    if S.Cfg.preset == "Rainbow" and #S.Const.NYAN_FRAMES > 1 and UI.nyanData and UI.nyanRect then
        S.nyanClock = S.nyanClock + dt
        local n = #S.Const.NYAN_FRAMES
        local idx = (math.floor(S.nyanClock * S.Const.NYAN_FPS) % n) + 1
        if idx ~= UI.nyanCur and UI.nyanData[idx] then
            pcall(function()
                S.D.nyan.Data = UI.nyanData[idx]
                S.D.nyan.Position = Vector2.new(UI.nyanRect.x, UI.nyanRect.y)
            end)
            UI.nyanCur = idx
        end
    end

    -- dropdown open/close animation (slide + fade); teardown happens when the close anim finishes
    if S.Drop.open then
        local target = S.Drop.closing and 0 or 1
        local dE = S.Cfg.animations and (1 - (0.00003 ^ dt)) or 1
        S.Drop.animT = S.Drop.animT + (target - S.Drop.animT) * dE
        if S.Drop.closing and S.Drop.animT < 0.03 then
            S.hardCloseDropdown()
        else
            if not S.Drop.closing and math.abs(S.Drop.animT - 1) < 0.004 then S.Drop.animT = 1 end
            S.Win.dirty = true
        end
    end

    if S.Search.active and not S.Capture.row and not S.Focus.row and not S.Pick.hexFocus and not S.Drop.open then
        S.pollTyping(
            function(ch) S.Search.buf = S.Search.buf .. ch S.buildSearch() S.Win.dirty = true end,
            function() S.Search.buf = S.Search.buf:sub(1, -2) S.buildSearch() S.Win.dirty = true end,
            function()
                if S.Search.results[1] then S.gotoResult(S.Search.results[1]) else S.closeSearch() S.Win.dirty = true end
            end
        )
    end

    if S.Drop.open and not S.Capture.row and not S.Focus.row and not S.Pick.hexFocus then
        S.pollTyping(
            function(ch) S.Drop.searchBuf = S.Drop.searchBuf .. ch S.Drop.scroll = 0 S.Win.dirty = true end,
            function() S.Drop.searchBuf = S.Drop.searchBuf:sub(1, -2) S.Drop.scroll = 0 S.Win.dirty = true end,
            function()
                local f = S.dropFiltered()
                if #S.Drop.searchBuf > 0 and f[1] then
                    S.Drop.open.value = f[1]
                    if S.Drop.open.onChange then pcall(S.Drop.open.onChange, S.Drop.open.value) end
                    if S.Drop.open.flag then S.markChanged() end
                end
                S.closeDropdown()
                S.Win.dirty = true
            end
        )
    end

    if S.Capture.row then
        if ismouse2pressed() then
            S.Capture.row.vk = -2
            if S.Capture.row.onChange then pcall(S.Capture.row.onChange, -2) end
            if S.Capture.row.flag then S.markChanged() end
            S.Capture.row = nil
        else
            for vk = 8, 222 do
                if vk ~= 0x01 and S.edgeKey(vk) then
                    if vk == 0x1B then
                        S.Capture.row = nil
                    else
                        S.Capture.row.vk = vk
                        if S.Capture.row.onChange then pcall(S.Capture.row.onChange, vk) end
                        if S.Capture.row.flag then S.markChanged() end
                        S.Capture.row = nil
                    end
                    break
                end
            end
        end
        if S.In.pressed then S.Capture.row = nil end
        S.Win.dirty = true
    elseif S.Focus.row then
        local row = S.Focus.row
        if row.kind == "slider" then
            S.pollTyping(
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
                        if row.flag then S.markChanged() end
                    end
                    S.Focus.row = nil
                end
            )
            if S.In.pressed and row.chipRect and not S.inRect(S.In.x, S.In.y, row.chipRect.x, row.chipRect.y, row.chipRect.w, row.chipRect.h) then
                S.Focus.row = nil
            end
        else
            S.pollTyping(
                function(ch) row.value = row.value .. ch if row.onChange then pcall(row.onChange, row.value) end if row.flag then S.markChanged() end end,
                function() row.value = row.value:sub(1, -2) if row.onChange then pcall(row.onChange, row.value) end if row.flag then S.markChanged() end end,
                function() S.Focus.row = nil end
            )
            if S.In.pressed and row.rect and not S.inRect(S.In.x, S.In.y, row.rect.x, row.rect.y, row.rect.w, row.rect.h) then
                S.Focus.row = nil
            end
        end
    elseif S.Pick.hexFocus then
        S.pollTyping(
            function(ch)
                ch = ch:upper()
                if ch:match("[%dA-F#]") and #S.Pick.hexBuf < 7 then S.Pick.hexBuf = S.Pick.hexBuf .. ch end
            end,
            function() S.Pick.hexBuf = S.Pick.hexBuf:sub(1, -2) end,
            function()
                local hx = S.Pick.hexBuf:gsub("#", "")
                if #hx == 6 then
                    local r = tonumber(hx:sub(1, 2), 16)
                    local g = tonumber(hx:sub(3, 4), 16)
                    local b = tonumber(hx:sub(5, 6), 16)
                    if r and g and b then
                        local hh, ss, vv = S.rgb2hsv(S.C3(r, g, b))
                        S.Pick.h, S.Pick.s, S.Pick.v = hh, ss, vv
                        S.pickerApply()
                    end
                end
                S.Pick.hexFocus = false
                S.Win.dirty = true
            end
        )
        S.Win.dirty = true
    end

    local overSidebar = S.inRect(S.In.x, S.In.y, x, y, math.max(S.Sb.cur, S.Const.SB_MIN), h) and S.Drag.mode == nil and not S.Drop.open and not S.Pick.open
    S.Sb.target = (overSidebar and not S.Cfg.collapseSidebar) and S.Sb.max or S.Const.SB_MIN
    local ease = S.Cfg.animations and (1 - (0.0000001 ^ dt)) or 1
    -- gentler ease for the sidebar so it glides open/closed instead of snapping
    local sbEase = S.Cfg.animations and (1 - (0.0006 ^ dt)) or 1
    local newCur = S.Sb.cur + (S.Sb.target - S.Sb.cur) * sbEase
    if math.abs(newCur - S.Sb.cur) > 0.1 then
        S.Sb.cur = newCur
        S.Win.dirty = true
    elseif math.abs(S.Sb.target - S.Sb.cur) > 0.1 then
        S.Sb.cur = S.Sb.target
        S.Win.dirty = true
    end

    local targetHY = (S.activeTab <= #S.Tabs) and (S.activeTab - 1) * S.Const.ITEM_H or S.hiliteY
    local newHY = S.hiliteY + (targetHY - S.hiliteY) * ease
    if math.abs(newHY - S.hiliteY) > 0.1 then
        S.hiliteY = newHY
        S.Win.dirty = true
    end

    if S.In.pressed and not S.Capture.row then
        local consumed = false
        do local p = S.curPage() if p then p.momentum = 0 end end

        -- search field + results popout take clicks first
        if not consumed and S.Search.rect and S.inRect(S.In.x, S.In.y, S.Search.rect.x, S.Search.rect.y, S.Search.rect.w, S.Search.rect.h) then
            S.closeDropdown() S.closePicker()
            S.Search.active = true
            S.buildSearch()
            S.Win.dirty = true
            consumed = true
        elseif S.Search.active and S.Search.geom then
            local g = S.Search.geom
            if S.inRect(S.In.x, S.In.y, g.px, g.py, g.pw, g.n * g.rowH + 8) then
                local i = math.floor((S.In.y - (g.py + 4)) / g.rowH) + 1
                if S.Search.results[i] then S.gotoResult(S.Search.results[i]) end
                consumed = true
            else
                S.closeSearch()
                S.Win.dirty = true
            end
        end

        if not consumed and S.Pick.open then
            local gx, gy = S.Pick.gx or 0, S.Pick.gy or 0
            local gridW, gridH = S.Const.SV_COLS * S.Const.SV_CELL, S.Const.SV_ROWS * S.Const.SV_CELL
            if S.inRect(S.In.x, S.In.y, gx, gy, gridW, gridH) then
                S.Pick.s = math.max(0, math.min(1, (S.In.x - gx) / gridW))
                S.Pick.v = 1 - math.max(0, math.min(1, (S.In.y - gy) / gridH))
                S.pickerApply()
                S.Win.dirty = true
                consumed = true
                S.Drag.mode = "picksv"
            elseif S.inRect(S.In.x, S.In.y, gx, S.Pick.hy or 0, gridW, 14) then
                S.Pick.h = math.max(0, math.min(1, (S.In.x - gx) / gridW))
                S.pickerApply()
                S.Win.dirty = true
                consumed = true
                S.Drag.mode = "pickhue"
            elseif S.inRect(S.In.x, S.In.y, gx + 38, S.Pick.hexRowY or 0, gridW - 38, 20) then
                S.Pick.hexFocus = true
                S.Pick.hexBuf = ""
                S.Win.dirty = true
                consumed = true
            elseif S.inRect(S.In.x, S.In.y, S.Pick.bg.Position.X, S.Pick.bg.Position.Y, S.Pick.bg.Size.X, S.Pick.bg.Size.Y) then
                consumed = true
            else
                S.closePicker()
                consumed = true
            end
        end

        if not consumed and S.Drop.open and S.Drop.geom then
            local g = S.Drop.geom
            if S.Drop.dropSb and S.inRect(S.In.x, S.In.y, S.Drop.dropSb.x, S.Drop.dropSb.y, S.Drop.dropSb.w, S.Drop.dropSb.h) then
                S.Drag.mode = "dropsbar"
                consumed = true
            elseif S.inRect(S.In.x, S.In.y, g.bx + 4, g.by + 4, g.bw - 8, 20) then
                consumed = true -- search field, typing already active
            elseif S.inRect(S.In.x, S.In.y, g.bx, g.oy, g.bw, g.visN * 24) then
                local i = math.floor((S.In.y - g.oy) / 24) + 1
                if i >= 1 and i <= g.visN then
                    S.Drag.mode = "droppend"
                    S.Drag.pendIdx = i + S.Drop.scroll
                    S.Drag.sy = S.In.y
                    S.Drag.startDropScroll = S.Drop.scroll
                end
                consumed = true
            elseif S.inRect(S.In.x, S.In.y, S.Drop.bg.Position.X, S.Drop.bg.Position.Y, S.Drop.bg.Size.X, S.Drop.bg.Size.Y) then
                consumed = true
            else
                S.closeDropdown()
                S.Win.dirty = true
                consumed = true
            end
        end

        if not consumed then
            if S.inRect(S.In.x, S.In.y, x + w - 24, y + 4, 22, 26) then
                UI.Unload()
                return
            elseif S.inRect(S.In.x, S.In.y, x + w - 24, y + h - 24, 26, 26) then
                S.Drag.mode = "resize"
            elseif UI.sbRect and S.inRect(S.In.x, S.In.y, UI.sbRect.x, UI.sbRect.y, UI.sbRect.w, UI.sbRect.h) then
                S.Drag.mode = "sbar"
            elseif S.inRect(S.In.x, S.In.y, x, y, S.Sb.cur, h) then
                if S.D.gear.Visible and S.inRect(S.In.x, S.In.y, x + S.Sb.cur - 34, y + h - 40, 26, 26) then
                    S.switchTab(S.SETTINGS_TAB)
                else
                    local iy = S.itemsTop()
                    for i = 1, #S.Tabs do
                        if S.inRect(S.In.x, S.In.y, x, iy + (i - 1) * S.Const.ITEM_H, S.Sb.cur, S.Const.ITEM_H) then
                            S.switchTab(i)
                            break
                        end
                    end
                end
            else
                local handled = false
                local page = S.Pages[S.activeTab]
                if page then
                    -- click a section header -> collapse/expand that card
                    for _, sec in ipairs(page.sections) do
                        local hr = sec.headRect
                        if hr and S.In.y > y + S.TB and S.inRect(S.In.x, S.In.y, hr.x, hr.y, hr.w, hr.h) then
                            sec.collapsed = not sec.collapsed
                            handled = true
                            break
                        end
                    end
                    for _, sec in ipairs(page.sections) do
                        if handled then break end
                        for _, row in ipairs(sec.rows) do
                            local r = row.rect
                            if row.vis and r and S.In.y > y + S.TB and S.In.y < y + h - 4 and S.inRect(S.In.x, S.In.y, r.x, r.y, r.w, r.h) then
                                local rowPass = false
                                if row.kind == "toggle" then
                                    row.value = not row.value
                                    if row.onChange then pcall(row.onChange, row.value) end
                                    if row.flag then S.markChanged() end
                                elseif row.kind == "button" then
                                    if row.onClick then pcall(row.onClick) end
                                    if #UI.Objects == 0 then return end
                                elseif row.kind == "buttonrow" then
                                    local bw = row.bw or 60
                                    for i = 1, #row.defs do
                                        local bx2 = r.x + 12 + (i - 1) * (bw + 8)
                                        if S.inRect(S.In.x, S.In.y, bx2, r.y + 4, bw, row.h - 8) then
                                            pcall(row.defs[i].cb)
                                            break
                                        end
                                    end
                                elseif row.kind == "slider" then
                                    local t = (row.value - row.min) / math.max(0.0001, row.max - row.min)
                                    local kx = row.knobX or (row.barX + row.barW * t)
                                    if row.chipRect and S.inRect(S.In.x, S.In.y, row.chipRect.x, row.chipRect.y, row.chipRect.w, row.chipRect.h) then
                                        S.Focus.row = row
                                        row.buf = tostring(math.floor(row.value + 0.5))
                                    elseif S.inRect(S.In.x, S.In.y, kx - 9, row.barY - 9, 18, 20) then
                                        S.Drag.mode = "slider"
                                        S.Drag.row = row
                                    else
                                        rowPass = true
                                    end
                                elseif row.kind == "dropdown" then
                                    S.openDropdown(row)
                                    S.Win.dirty = true
                                elseif row.kind == "color" then
                                    S.openPicker(row)
                                    S.Win.dirty = true
                                elseif row.kind == "keybind" then
                                    S.Capture.row = row
                                elseif row.kind == "textbox" then
                                    S.Focus.row = row
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
                    if S.inRect(S.In.x, S.In.y, x + S.Sb.cur, y, w - S.Sb.cur, S.TB) then
                        S.Drag.mode = "move"
                        S.Drag.ox, S.Drag.oy = S.In.x - x, S.In.y - y
                    elseif S.inRect(S.In.x, S.In.y, x + S.Sb.cur, y + S.TB, w - S.Sb.cur, h - S.TB) then
                        local page2 = S.curPage()
                        if page2 then
                            S.Drag.mode = "scrollpend"
                            S.Drag.sy = S.In.y
                            S.Drag.startScroll = page2.scrollY
                        end
                    end
                end
            end
        end
    end
    if S.In.released then
        if S.Drag.mode == "droppend" and S.Drop.open then
            local f = S.dropFiltered()
            local pick = f[S.Drag.pendIdx]
            if pick then
                S.Drop.open.value = pick
                if S.Drop.open.onChange then pcall(S.Drop.open.onChange, pick) end
                if S.Drop.open.flag then S.markChanged() end
            end
            S.closeDropdown()
            S.Win.dirty = true
        elseif S.Drag.mode == "scroll" then
            -- release a flick: hand the tracked velocity to the momentum integrator
            local page = S.curPage()
            if page then page.momentum = S.Drag.vel or 0 end
        end
        S.Drag.mode = nil
        S.Drag.row = nil
        S.Drag.vel = 0
    end

    if S.Drag.mode == "move" then
        S.Win.x, S.Win.y = S.In.x - S.Drag.ox, S.In.y - S.Drag.oy
        S.Win.dirty = true
    elseif S.Drag.mode == "resize" then
        local newW = math.max(S.Const.MIN_W, S.In.x - S.Win.x + 8)
        local newH = math.max(S.Const.MIN_H, S.In.y - S.Win.y + 8)
        if newW ~= S.Win.w or newH ~= S.Win.h then
            S.Win.w, S.Win.h = newW, newH
            S.Win.dirty = true
        end
    elseif S.Drag.mode == "slider" and S.Drag.row then
        S.sliderFromMouse(S.Drag.row)
    elseif S.Drag.mode == "picksv" and S.Pick.open then
        local gx, gy = S.Pick.gx or 0, S.Pick.gy or 0
        S.Pick.s = math.max(0, math.min(1, (S.In.x - gx) / (S.Const.SV_COLS * S.Const.SV_CELL)))
        S.Pick.v = 1 - math.max(0, math.min(1, (S.In.y - gy) / (S.Const.SV_ROWS * S.Const.SV_CELL)))
        S.pickerApply()
        S.Win.dirty = true
    elseif S.Drag.mode == "pickhue" and S.Pick.open then
        local gx = S.Pick.gx or 0
        S.Pick.h = math.max(0, math.min(1, (S.In.x - gx) / (S.Const.SV_COLS * S.Const.SV_CELL)))
        S.pickerApply()
        S.Win.dirty = true
    elseif S.Drag.mode == "droppend" then
        if math.abs(S.In.y - S.Drag.sy) > 6 then S.Drag.mode = "dropscroll" end
    elseif S.Drag.mode == "dropscroll" then
        S.Drop.scroll = S.Drag.startDropScroll + math.floor((S.Drag.sy - S.In.y) / 24 + 0.5)
        S.Win.dirty = true
    elseif S.Drag.mode == "dropsbar" and S.Drop.dropSb then
        local sb = S.Drop.dropSb
        if sb.maxSc > 0 then
            local ratio = (S.In.y - sb.y - sb.thH / 2) / math.max(1, sb.h - sb.thH)
            S.Drop.scroll = math.floor(math.max(0, math.min(sb.maxSc, ratio * sb.maxSc)) + 0.5)
            S.Win.dirty = true
        end
    elseif S.Drag.mode == "scrollpend" then
        if math.abs(S.In.y - S.Drag.sy) > 6 then S.Drag.mode = "scroll" end
    elseif S.Drag.mode == "scroll" then
        local page = S.curPage()
        if page then
            local newScroll = math.max(0, math.min((page.maxScroll or 0), S.Drag.startScroll - (S.In.y - S.Drag.sy)))
            -- track a smoothed scroll velocity (px/s) so a flick release carries momentum
            local inst = (newScroll - page.scrollY) / math.max(dt, 1e-4)
            S.Drag.vel = (S.Drag.vel or 0) * 0.6 + inst * 0.4
            page.scrollY = newScroll
            S.Win.dirty = true
        end
    elseif S.Drag.mode == "sbar" and UI.sbRect then
        local sb = UI.sbRect
        local page = S.curPage()
        if page and sb.maxScroll > 0 then
            local ratio = (S.In.y - sb.y - sb.thumbH / 2) / math.max(1, sb.h - sb.thumbH)
            page.scrollY = math.max(0, math.min(sb.maxScroll, ratio * sb.maxScroll))
            S.Win.dirty = true
        end
    end

    -- momentum: after a flick release the page keeps gliding, velocity decaying by friction,
    -- and stops when it slows below a threshold or hits either scroll bound (mobile-style)
    do
        local page = S.curPage()
        if page and S.Drag.mode == nil and page.momentum and math.abs(page.momentum) > 8 then
            page.scrollY = page.scrollY + page.momentum * dt
            page.momentum = page.momentum * (0.1 ^ dt)
            if page.scrollY <= 0 then page.scrollY = 0 page.momentum = 0 end
            if page.scrollY >= (page.maxScroll or 0) then page.scrollY = page.maxScroll or 0 page.momentum = 0 end
            S.wheelPulse = math.max(S.wheelPulse, 0.1)
            S.Win.dirty = true
        elseif page and page.momentum and math.abs(page.momentum) <= 8 then
            page.momentum = 0
        end
    end

    -- smooth scroll toward target
    do
        local page = S.curPage()
        if page then
            local sEase = S.Cfg.animations and (1 - (0.000001 ^ dt)) or 1
            local nc = page.scrollCur + (page.scrollY - page.scrollCur) * sEase
            if math.abs(nc - page.scrollCur) > 0.4 then
                page.scrollCur = nc
                S.Win.dirty = true
            elseif math.abs(page.scrollY - page.scrollCur) > 0.4 then
                page.scrollCur = page.scrollY
                S.Win.dirty = true
            end
        end
    end

    -- scrollbar glow while scrolling by any means
    S.wheelPulse = math.max(0, S.wheelPulse - dt)
    local scrolling = S.Drag.mode == "scroll" or S.Drag.mode == "sbar" or S.wheelPulse > 0
    local gEase = S.Cfg.animations and (1 - (0.00001 ^ dt)) or 1
    S.scrollGlowT = S.scrollGlowT + ((scrolling and 1 or 0) - S.scrollGlowT) * gEase
    if S.D.sbThumb.Visible then
        S.D.sbThumb.Color = S.lerpColor(S.Theme.Track, S.lerpColor(S.Theme.Track, S.Theme.C1, 0.5), S.scrollGlowT)
        local tp, ts = S.D.sbThumb.Position, S.D.sbThumb.Size
        local show = S.scrollGlowT > 0.02
        local N = #S.D.sbGlowSegs
        -- glow spans ~70% of the whole scrollbar track, centered on the thumb, brightest in the middle
        local trackH = (UI.sbRect and UI.sbRect.h) or ts.Y
        local total = math.floor(trackH * 0.7)
        local used = math.max(1, math.min(total, N))
        local center = tp.Y + ts.Y / 2
        local y0 = math.floor(center - used / 2)
        local coreC = S.lerpColor(S.Theme.C1, S.Theme.White, 0.55) -- brighter green core
        local halfW = ts.X / 2 + 2
        for i = 1, N do
            local o = S.D.sbGlowSegs[i]
            if show and i <= used then
                local yy = y0 + (i - 1)                 -- exactly 1px per segment
                local cy = (i - 0.5) / used             -- 0..1 down the glow
                local d = math.abs(cy - 0.5) * 2        -- 0 center, 1 ends
                local a = 1 - d
                a = a * a                                -- gentle falloff so the long glow still reaches the ends
                o.Visible = true
                o.Position = Vector2.new(tp.X - 2, yy)
                o.Size = Vector2.new(math.max(1, math.floor(halfW * 2)), 1)
                o.Color = S.lerpColor(S.Theme.C1, coreC, a) -- fade to the brighter core at the middle
                o.Transparency = (0.85 * a * S.scrollGlowT) * S.Cfg.opacity
            else
                o.Visible = false
            end
        end
    else
        for i = 1, #S.D.sbGlowSegs do S.D.sbGlowSegs[i].Visible = false end
    end

    -- dropdown scrollbar: same per-pixel glow, scaled to the smaller thumb/track
    local dropScrolling = S.Drag.mode == "dropscroll" or S.Drag.mode == "dropsbar"
    S.dropGlowT = S.dropGlowT + ((dropScrolling and 1 or 0) - S.dropGlowT) * gEase
    if S.Drop.open and S.Drop.sbT.Visible and S.Drop.dropSb then
        local tp, ts = S.Drop.sbT.Position, S.Drop.sbT.Size
        local show = S.dropGlowT > 0.02
        local N = #S.Drop.glowSegs
        local total = math.floor(S.Drop.dropSb.h * 0.7)
        local used = math.max(1, math.min(total, N))
        local center = tp.Y + ts.Y / 2
        local y0 = math.floor(center - used / 2)
        local coreC = S.lerpColor(S.Theme.C1, S.Theme.White, 0.55)
        local halfW = ts.X / 2 + 1.5
        for i = 1, N do
            local o = S.Drop.glowSegs[i]
            if show and i <= used then
                local yy = y0 + (i - 1)
                local cy = (i - 0.5) / used
                local a = 1 - math.abs(cy - 0.5) * 2
                a = a * a
                o.Visible = true
                o.Position = Vector2.new(tp.X - 1.5, yy)
                o.Size = Vector2.new(math.max(1, math.floor(halfW * 2)), 1)
                o.Color = S.lerpColor(S.Theme.C1, coreC, a)
                o.Transparency = (0.85 * a * S.dropGlowT) * S.Cfg.opacity
            else
                o.Visible = false
            end
        end
    else
        for i = 1, #S.Drop.glowSegs do S.Drop.glowSegs[i].Visible = false end
    end

    if S.cfgDirty and S.Cfg.autoSave then
        S.saveTimer = S.saveTimer + dt
        if S.saveTimer > 1.5 then
            S.saveTimer = 0
            S.cfgDirty = false
            S.saveSettings()
        end
    else
        S.saveTimer = 0
    end

    if S.Win.dirty then S.relayout() end
    -- one-shot: after jumping to a searched feature's tab, scroll it near the top
    if S.Search.focus and S.Search.focus.row and S.Search.focus.row.rect then
        local page = S.Pages[S.activeTab]
        if page and S.Search.focus.tabIdx == S.activeTab and (page.maxScroll or 0) > 0 then
            local targetY = S.Win.y + S.TB + 40
            page.scrollY = math.max(0, math.min(page.maxScroll or 0, page.scrollY + (S.Search.focus.row.rect.y - targetY)))
            S.Win.dirty = true
            S.relayout()
        end
        S.Search.focus = nil
    end
    S.updateControls(dt, S.In.x, S.In.y)
    S.clipRows()
end

UI.Conn = S.RunService.RenderStepped:Connect(function()
    local ok, e = pcall(S.frame)
    if not ok then
        S.errCount = S.errCount + 1
        if S.errCount <= 3 or S.errCount % 300 == 0 then
            print("FALUI|frame ERROR (" .. S.errCount .. "): " .. tostring(e))
        end
    end
end)

function UI.Unload()
    if UI.Conn then pcall(function() UI.Conn:Disconnect() end) end
    for _, c in ipairs(UI.WheelConns) do pcall(function() c:Disconnect() end) end
    if S.Cfg.autoSave then pcall(S.saveSettings) end
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
function S.resolveSide(side)
    side = tostring(side or "left"):lower()
    return (side == "right") and "right" or "left"
end

function S.newTabIndex(name, icon)
    -- the new sidebar tab takes the slot Settings currently occupies; Settings shifts up one,
    -- keeping it the last (gear) page and its section data intact under the new index.
    local newIdx = S.SETTINGS_TAB
    S.Pages[S.SETTINGS_TAB + 1] = S.Pages[S.SETTINGS_TAB]
    S.Pages[S.SETTINGS_TAB] = nil
    if S.activeTab == S.SETTINGS_TAB then S.activeTab = S.SETTINGS_TAB + 1 end
    S.SETTINGS_TAB = S.SETTINGS_TAB + 1
    S.Tabs[newIdx] = { name = name, icon = icon or "circle" }
    S.Items[newIdx] = {
        icon  = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = S.Win.visible, Size = Vector2.new(15, 15), Color = S.Theme.Dim }),
        label = S.New("Text",  { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = S.Win.visible }),
    }
    S.loadIcon(S.Tabs[newIdx].icon, function(data) S.Items[newIdx].icon.Data = data end)
    S.Win.dirty = true
    return newIdx
end

-- ---- Element: a single control handle ----
S.Element = {}
S.Element.__index = S.Element
function S.Element.new(row) return setmetatable({ row = row }, S.Element) end
function S.Element:SetTip(tip) self.row.tip = tip return self end
function S.Element:Set(v) S.applyRow(self.row, v) S.Win.dirty = true return self end
function S.Element:Get()
    local r = self.row
    if r.color ~= nil then return r.color elseif r.vk ~= nil then return r.vk else return r.value end
end

-- ---- Section: a card that holds controls ----
S.Section = {}
S.Section.__index = S.Section
function S.Section.new(sec, tabIdx) return setmetatable({ section = sec, tabIdx = tabIdx }, S.Section) end
function S.Section:_refresh()
    if self.tabIdx == S.activeTab then S.setPageVisible(S.activeTab, true) end
    S.Win.dirty = true
end
function S.Section:CreateToggle(o)
    o = o or {}
    local r = S.addToggle(self.section, o.Text or o.Name or "Toggle", o.Default, o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateSlider(o)
    o = o or {}
    local r = S.addSlider(self.section, o.Text or o.Name or "Slider", o.Min or 0, o.Max or 100, o.Default or o.Min or 0, o.Suffix, o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateDropdown(o)
    o = o or {}
    local r = S.addDropdown(self.section, o.Text or o.Name or "Dropdown", o.Options or {}, o.Default or (o.Options and o.Options[1]) or "", o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateButton(o)
    o = o or {}
    local r = S.addButton(self.section, o.Text or o.Name or "Button", o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateButtonRow(defs)
    local r = S.addButtonRow(self.section, defs or {}) self:_refresh() return S.Element.new(r)
end
function S.Section:CreateColor(o)
    o = o or {}
    local r = S.addColor(self.section, o.Text or o.Name or "Color", o.Default or S.Theme.C1, o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
S.Section.CreateColorpicker = S.Section.CreateColor
function S.Section:CreateKeybind(o)
    o = o or {}
    local r = S.addKeybind(self.section, o.Text or o.Name or "Keybind", o.Default or 0x24, o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateTextbox(o)
    o = o or {}
    local r = S.addTextbox(self.section, o.Text or o.Name or "Textbox", o.Default, o.Flag, o.Callback)
    r.tip = o.Tip self:_refresh() return S.Element.new(r)
end
function S.Section:CreateDivider(text) local r = S.addDivider(self.section, text or "") self:_refresh() return S.Element.new(r) end
function S.Section:CreateNote(text) local r = S.addNote(self.section, text or "") self:_refresh() return S.Element.new(r) end
S.Section.CreateLabel = S.Section.CreateNote

-- ---- Tab: a sidebar page ----
S.Tab = {}
S.Tab.__index = S.Tab
function S.Tab.new(idx) return setmetatable({ index = idx }, S.Tab) end
function S.Tab:CreateSection(opts, side)
    local title
    if type(opts) == "table" then title = opts.Title or opts.Name or opts.Text side = opts.Side else title = opts end
    local sec = S.addSection(self.index, title or "Section", S.resolveSide(side))
    if self.index == S.activeTab then S.setPageVisible(S.activeTab, true) end
    S.Win.dirty = true
    return S.Section.new(sec, self.index)
end
S.Tab.CreateGroupbox = S.Tab.CreateSection

function S.wrapTab(tabIdx) return S.Tab.new(tabIdx) end

S.Library = {}
UI.Library = S.Library
S.Library.Flags = S.FlagRows

function S.Library:CreateTab(name, icon)
    return S.wrapTab(S.newTabIndex(name or "Tab", icon))
end

-- grab a built-in tab (Home/Visuals/Aim/Modifiers/Farm) or Settings, by name or index
function S.Library:Tab(ref)
    local idx = ref
    if type(ref) == "string" then
        if ref:lower() == "settings" then
            idx = S.SETTINGS_TAB
        else
            for i, t in ipairs(S.Tabs) do if t.name:lower() == ref:lower() then idx = i break end end
        end
    end
    if type(idx) ~= "number" or not S.Tabs[idx] and idx ~= S.SETTINGS_TAB then return nil end
    return S.wrapTab(idx)
end

function S.Library:SetPreset(name) S.applyPreset(name) S.Win.dirty = true end
function S.Library:GetFlag(flag)
    local r = S.FlagRows[flag]
    if not r then return nil end
    return r.color or r.vk or r.value
end
function S.Library:SetFlag(flag, v)
    local r = S.FlagRows[flag]
    if r then S.applyRow(r, v) S.Win.dirty = true return true end
    return false
end
function S.Library:Show() S.setVisible(true) end
function S.Library:Hide() S.setVisible(false) end
function S.Library:Toggle() S.setVisible(not S.Win.visible) end
function S.Library:Unload() UI.Unload() end

-- load persisted state from disk (runs once FOLDER/CFGSUB are known, i.e. inside CreateWindow)
function S.loadPersisted()
    S.Cfg.autoLoad = S.readAutoload()   -- autoload pointer is the source of truth
    if S.rAutoLoad then S.rAutoLoad.value = S.Cfg.autoLoad end
    local sp = isfile(S.FOLDER .. "/settings.json") and S.FOLDER .. "/settings.json" or (isfile(S.FOLDER .. "/settings.lua") and S.FOLDER .. "/settings.lua" or nil)
    if sp then
        local ok, txt = pcall(readfile, sp)
        if ok and txt then S.loadSnapshot(txt) end
    end
    if S.Cfg.autoLoad and S.Cfg.autoLoad ~= "none" then
        local cp = isfile(S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".json") and S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".json"
            or (isfile(S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".lua") and S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".lua" or nil)
        if cp then
            local ok, txt = pcall(readfile, cp)
            if ok and txt then S.loadSnapshot(txt) end
        end
        if S.rAutoLoad then S.rAutoLoad.value = S.Cfg.autoLoad end
    end
end

function S.sanitizeName(s) return (tostring(s):gsub("[^%w_%-]", "")) end

-- the window is only built/shown when the consumer calls this (nothing on disk is touched
-- and nothing is shown until then). all fields optional; nil keeps the default.
function S.Library:CreateWindow(opts)
    opts = opts or {}
    if opts.Title ~= nil then
        S.BRAND = tostring(opts.Title)
        local f = S.sanitizeName(opts.Title)
        if #f > 0 then S.FOLDER = f end
    end
    if opts.Subtitle ~= nil then S.SUBTITLE = tostring(opts.Subtitle) end
    if opts.Version ~= nil then S.VERSION = tostring(opts.Version) end
    if opts.Icon ~= nil then S.WinIcon = opts.Icon end
    if type(opts.FileSettings) == "table" and opts.FileSettings.ConfigFolder then
        local c = S.sanitizeName(opts.FileSettings.ConfigFolder)
        if #c > 0 then S.CFGSUB = c end
    end
    S.startAssets()
    S.loadPersisted()
    S.loadThemeImage(S.Cfg.preset)   -- force the active theme's bg image once, after config load
    UI.created = true
    S.setVisible(true)
    S.relayout()
    return S.Library
end

S.setVisible(false)   -- stay hidden and untouched until CreateWindow is called
S.relayout()

-- the chunk returns the library directly, so: local Lib = loadstring(...)()  then  Lib:CreateWindow{...}
return S.Library