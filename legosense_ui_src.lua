-- Silent unless getgenv().LEGOSENSE_DEBUG: some games (Volleyball Legends) upload LogService history to
-- their server, so a print/warn from the lib ends up in their logs.
local print, warn = print, warn
if not (getgenv and getgenv().LEGOSENSE_DEBUG) then print, warn = function() end, function() end end
local perfT0 = os.clock()

-- ========== ENVIRONMENT ==========
-- Matcha is the only non-standard runtime: its quirks (top-level `return` dropped by loadstring,
-- Matcha-only Drawing props like Corner/Rounding, notify(message, title, duration)) are handled
-- where they matter. Everything else is treated as regular Roblox Luau, and any executor globals
-- it lacks are filled in here. Whether the UI renders depends only on a working Drawing library:
-- without one the library runs headless (flags, configs and callbacks work, nothing is drawn).
-- Must stay at the top of the file. Wrapped in do...end to keep its locals out of the register budget.
do
    local env = { matcha = false, executor = nil, version = nil, drawing = false, filesystem = false, input = false }

    local okId, name, ver = pcall(function() return identifyexecutor() end)
    if okId and type(name) == "string" then env.executor, env.version = name, ver end
    env.matcha = env.executor == "Matcha"

    local okD, dnew = pcall(function() return Drawing.new end)
    env.drawing = okD and type(dnew) == "function"
    env.filesystem = type(isfile) == "function" and type(readfile) == "function" and type(writefile) == "function"
    env.input = type(iskeypressed) == "function" and type(ismouse1pressed) == "function"

    -- filesystem: no-ops when missing (every library call site is pcall'd)
    if not env.filesystem then
        isfile = isfile or function() return false end
        isfolder = isfolder or function() return false end
        readfile = readfile or function(p) error("[legosense] no filesystem: cannot read " .. tostring(p)) end
        writefile = writefile or function() end
        appendfile = appendfile or function() end
        makefolder = makefolder or function() end
        delfile = delfile or function() end
    end

    -- input: Windows VK codes -> UserInputService, only for globals the executor doesn't provide
    if not env.input then
        local okU, UIS = pcall(function() return game:GetService("UserInputService") end)
        -- held state from input events: these still fire while LegoSense blocks game input (sink + modal
        -- overlay), when IsKeyDown / IsMouseButtonPressed report false. Cleared when the window loses focus.
        local held = {}
        if okU then
            pcall(function()
                UIS.InputBegan:Connect(function(io)
                    held[io.KeyCode] = true
                    held[io.UserInputType] = true
                end)
                UIS.InputEnded:Connect(function(io)
                    held[io.KeyCode] = nil
                    held[io.UserInputType] = nil
                end)
                UIS.WindowFocusReleased:Connect(function() table.clear(held) end)
            end)
        end
        local function mouseDown(t)
            if not okU then return false end
            if held[t] then return true end
            local ok, d = pcall(UIS.IsMouseButtonPressed, UIS, t)
            return ok and d
        end
        if type(ismouse1pressed) ~= "function" then ismouse1pressed = function() return mouseDown(Enum.UserInputType.MouseButton1) end end
        if type(ismouse2pressed) ~= "function" then ismouse2pressed = function() return mouseDown(Enum.UserInputType.MouseButton2) end end
        if type(iskeypressed) ~= "function" then
            local KC = Enum.KeyCode
            local VK = {
                [0x08] = KC.Backspace, [0x09] = KC.Tab, [0x0D] = KC.Return,
                [0x10] = KC.LeftShift, [0x11] = KC.LeftControl, [0x12] = KC.LeftAlt,
                [0x1B] = KC.Escape, [0x20] = KC.Space,
                [0x21] = KC.PageUp, [0x22] = KC.PageDown, [0x23] = KC.End, [0x24] = KC.Home,
                [0x25] = KC.Left, [0x26] = KC.Up, [0x27] = KC.Right, [0x28] = KC.Down,
                [0x2D] = KC.Insert, [0x2E] = KC.Delete,
                [0xBD] = KC.Minus, [0xBE] = KC.Period, [0xBF] = KC.Slash, [0xDE] = KC.Quote,
            }
            local digits = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
            for i = 0, 9 do VK[0x30 + i] = KC[digits[i + 1]] end
            for i = 0x41, 0x5A do VK[i] = KC[string.char(i)] end
            for i = 0x70, 0x7B do VK[i] = KC["F" .. (i - 0x6F)] end
            iskeypressed = function(vk)
                if vk == 0x01 then return ismouse1pressed() end
                if vk == 0x02 then return ismouse2pressed() end
                if vk == 0x04 then return mouseDown(Enum.UserInputType.MouseButton3) end
                local kc = VK[vk]
                if not (okU and kc) then return false end
                if held[kc] then return true end
                local ok, d = pcall(UIS.IsKeyDown, UIS, kc)
                return ok and d
            end
        end
    end
    if type(setrobloxinput) ~= "function" then setrobloxinput = function() end end

    -- no Drawing library -> inert stand-ins so the library boots headless
    if not env.drawing then
        -- stand-ins stay invisible (so per-frame clipping skips them) and report zero-size geometry
        local VEC = { Position = true, Size = true, From = true, To = true, PointA = true, PointB = true, PointC = true, TextBounds = true, ImageSize = true }
        local stubMeta = {
            __index = function(_, k)
                if k == "Remove" or k == "Destroy" then return function() end end
                if k == "Visible" then return false end
                if VEC[k] then return Vector2.new(0, 0) end
                return nil
            end,
            __newindex = function(self, k, v)
                if k ~= "Visible" and not VEC[k] then rawset(self, k, v) end
            end,
        }
        Drawing = { new = function(t) return setmetatable({ _type = t }, stubMeta) end, Fonts = { UI = 0, System = 1, Plex = 2, Monospace = 3 } }
        warn("[legosense] no Drawing library - running headless (flags/config only)")
    end

    _G.FALUI_ENV = env
end
-- ========== END ENVIRONMENT ==========

if _G.FALUI and _G.FALUI.Unload then pcall(_G.FALUI.Unload) end
-- orphan sweep: every raw Drawing any LegoSense copy made is also kept in a shared list. A copy that crashed mid-load
-- (never registered Unload) or leaked objects left them on screen, often at (0,0) top-left; the next load removes them.
do
    local reg = rawget(_G, "LS_ALL_DRAWINGS")
    if type(reg) == "table" then
        for o in pairs(reg) do pcall(function() o.Visible = false end) pcall(function() o:Remove() end) end
    end
    _G.LS_ALL_DRAWINGS = setmetatable({}, { __mode = "k" })
end

local S = {}

S.Env = _G.FALUI_ENV

-- GET that works on Matcha (game:HttpGet / httpget) and on regular executors (request fallbacks).
-- Callers pcall it; it returns the body string or errors.
function S.httpGet(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" then return body end
    if type(httpget) == "function" then return httpget(url) end
    local req = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
        or (type(syn) == "table" and syn.request)
    if req then
        local r = req({ Url = url, Method = "GET" })
        return r and r.Body
    end
    return game:GetService("HttpService"):GetAsync(url)
end

-- Matcha supports every Drawing prop the library writes. Other executors may not have the
-- Matcha-only ones (Corner, Rounding, ...): there each object is wrapped so a failing write is
-- dropped and never retried, instead of erroring every frame and killing relayout.
S.BadProps = {}
function S.wrapDrawing(o, t)
    local bad = S.BadProps[t]
    if not bad then bad = {} S.BadProps[t] = bad end
    return setmetatable({}, {
        __index = function(_, k)
            local ok, v = pcall(function() return o[k] end)
            if not ok then return nil end
            if type(v) == "function" then return function(_, ...) return v(o, ...) end end
            return v
        end,
        __newindex = function(_, k, v)
            if bad[k] then return end
            -- Never blacklist a core property. A write can fail because an object was just removed, and blacklisting
            -- Visible would then hide every Text and Image object.
            if not pcall(function() o[k] = v end) and not S.CoreProps[k] then bad[k] = true end
        end,
    })
end
S.CoreProps = { Visible = true, Position = true, Size = true, Color = true, Transparency = true, Text = true, Data = true,
    ZIndex = true, Thickness = true, Filled = true, Font = true, From = true, To = true, Radius = true, Outline = true,
    Center = true, OutlineColor = true, PointA = true, PointB = true, PointC = true, NumSides = true }

-- Rounded corners off Matcha: other executors (Potassium, ...) ignore Corner, so a Square with Corner >= 2 px
-- is drawn as 3 non-overlapping rects + a triangle fan per corner (outlines: 4 lines + arc segments).
-- Nothing overlaps, so see-through fills stay even. Writes are queued and the geometry is rebuilt once
-- per frame (S.rrFlush after S.frame), only for squares that are visible.
S.RRQueue = {}
S.RR_FWD = { Color = true, Transparency = true, ZIndex = true, Thickness = true }
function S.roundRect(base)
    local st = { base = base, pos = Vector2.new(0, 0), size = Vector2.new(0, 0), r = 0, filled = true, vis = false, transp = 1, z = 1, thick = 1 }
    return setmetatable({}, {
        __index = function(_, k)
            if k == "Remove" or k == "Destroy" then
                return function()
                    st.removed = true S.rrFree(st) pcall(function() base:Remove() end)
                    if st.img then pcall(function() st.img:Remove() end) st.img = nil end
                end
            end
            if k == "Position" then return st.pos elseif k == "Size" then return st.size
            elseif k == "Corner" or k == "Rounding" then return st.r elseif k == "Visible" then return st.vis end
            local v = base[k]
            if type(v) == "function" then return function(_, ...) return v(base, ...) end end
            return v
        end,
        __newindex = function(_, k, v)
            if k == "Corner" or k == "Rounding" then st.r = v
            elseif k == "CornerMask" then st.mask = v -- { tl, tr, br, bl } booleans; nil = all four rounded
            elseif k == "ArcOnly" then st.arcOnly = v -- outline: corner rings only, no straight edges
            elseif k == "Fillet" then st.fillet = v   -- true: draw a concave top-left corner instead (S.rrFillet)
            elseif k == "Position" then st.pos = v base.Position = v
            elseif k == "Size" then st.size = v base.Size = v
            elseif k == "Visible" then
                st.vis = v
                if not v then
                    base.Visible = false
                    if st.img then st.img.Visible = false end
                    S.rrHideParts(st)
                end
            elseif k == "Filled" then st.filled = v base.Filled = v
            else
                base[k] = v
                if k == "Color" then st.color = v elseif k == "Transparency" then st.transp = v
                elseif k == "ZIndex" then st.z = v elseif k == "Thickness" then st.thick = v end
                if st.img and k ~= "Thickness" and S.RR_FWD[k] then st.img[k] = v end
                if st.all and S.RR_FWD[k] then
                    for _, o in ipairs(st.all) do
                        if k == "Transparency" then o.Transparency = v * (st.cov[o] or 1) else o[k] = v end
                    end
                end
                return
            end
            if not st.queued then st.queued = true S.RRQueue[#S.RRQueue + 1] = st end
        end,
    })
end
function S.rrFree(st)
    if st.all then for _, o in ipairs(st.all) do pcall(function() o:Remove() end) end end
    st.all, st.cov = nil, nil
end
function S.rrMk(st, t)
    local ok, o = pcall(Drawing.new, t)
    if not ok or not o then return nil end
    if _G.LS_ALL_DRAWINGS then _G.LS_ALL_DRAWINGS[o] = true end
    o = S.wrapDrawing(o, t)
    if t ~= "Line" then o.Filled = true end
    o.Color, o.Transparency, o.ZIndex, o.Visible = st.color or Color3.new(1, 1, 1), st.transp or 1, st.z or 1, false
    if t == "Line" then o.Thickness = st.thick or 1 end
    st.all[#st.all + 1] = o
    return o
end
-- Pools: filled = 1 middle rect + per corner row one 1px strip spanning both corners (top band, bottom band)
-- + one anti-alias pixel at each end of every strip. outline = 4 edge rects + per corner per row a ring strip
-- with an anti-alias pixel on its outer and inner boundary. Everything sits on whole pixels, nothing overlaps,
-- and the outline's outer curve is the fill's curve, so borders hug their fills exactly.
-- A pool is sized for the largest radius seen; smaller radii (e.g. a card clipped short) hide the extra rows.
function S.rrBuild(st, r)
    S.rrFree(st)
    st.all, st.cov = {}, {}
    if st.filled then
        st.mid = S.rrMk(st, "Square")
        st.top, st.bot, st.aa = {}, {}, {}
        for i = 1, r do st.top[i] = S.rrMk(st, "Square") st.bot[i] = S.rrMk(st, "Square") end
        for i = 1, 4 * r do st.aa[i] = S.rrMk(st, "Square") end
    else
        st.edges, st.ring = {}, {}
        for i = 1, 4 do st.edges[i] = S.rrMk(st, "Square") end
        for c = 1, 4 do
            st.ring[c] = {}
            for i = 1, r do st.ring[c][i] = { S.rrMk(st, "Square"), S.rrMk(st, "Square"), S.rrMk(st, "Square") } end
        end
    end
    st.pFilled, st.pR, st.shown = st.filled, r, false
end
-- u = inset from the outer side -> screen x of a run of width wd (right-hand corners mirror)
function S.rrSx(right, x, w, u, wd) return right and (x + w - u - wd) or (x + u) end
function S.rrHideParts(st)
    if st.all and st.shown then for _, o in ipairs(st.all) do o.Visible = false end st.shown = false end
end
-- a 1px pixel / strip helper: place o, set its anti-alias coverage, show it if it covers anything
function S.rrPix(st, o, px, py, w, cov)
    o.Position, o.Size = Vector2.new(px, py), Vector2.new(math.max(1, w), 1)
    st.cov[o] = cov
    o.Transparency = (st.transp or 1) * cov
    o.Visible = w >= 1 and cov > 0.03
end
-- concave (inward) top-left corner: fills between the corner's two edges and a quarter circle of radius
-- Corner centred at (x + r, y + r). Same pixel rows + anti-alias pixel as the convex corners.
function S.rrFillet(st)
    local s = st.size
    local r = math.floor(math.min(st.r or 0, s.X, s.Y))
    st.base.Visible = false
    if r < 2 or not st.vis then S.rrHideParts(st) return end
    if not st.all or not st.pFilled or r > st.pR then S.rrBuild(st, r) end
    local x, y = st.pos.X, st.pos.Y
    st.mid.Visible = false
    for i = 1, st.pR do
        local strip, aa = st.top[i], st.aa[4 * i - 3]
        st.bot[i].Visible, st.aa[4 * i - 2].Visible, st.aa[4 * i - 1].Visible, st.aa[4 * i].Visible = false, false, false, false
        if i <= r then
            local dy = r - (i - 0.5)
            local fw = r - math.sqrt(math.max(0, r * r - dy * dy)) -- filled width left of the arc on this row
            local fl = math.floor(fw)
            S.rrPix(st, strip, x, y + i - 1, fl, 1)
            S.rrPix(st, aa, x + fl, y + i - 1, 1, fw - fl)
        else
            strip.Visible, aa.Visible = false, false
        end
    end
    st.shown = true
end
function S.rrApply(st)
    if st.fillet then return S.rrFillet(st) end
    local s = st.size
    local r = math.floor(math.min(st.r or 0, s.X / 2, s.Y / 2))
    local round = r >= 2
    -- plain rounded fills: one Image with native Rounding (smooth edge, 1 drawing instead of ~4r). Native rounding
    -- takes fractional radii, so tiny pills / dots (radius 1..2 px) are round here too
    local rf = math.min(st.r or 0, s.X / 2, s.Y / 2)
    if rf >= 1 and st.filled and not st.mask and S.rrImgOn() then
        local im = st.img or S.rrImage(st)
        if im then
            st.base.Visible = false
            S.rrHideParts(st)
            im.Position, im.Size, im.Rounding = st.pos, st.size, rf
            im.Visible = st.vis
            return
        end
    end
    if st.img then st.img.Visible = false end
    st.base.Visible = st.vis and not round
    if not (round and st.vis) then S.rrHideParts(st) return end
    if not st.all or st.pFilled ~= st.filled or r > st.pR then S.rrBuild(st, r) end
    local x, y, w, h = st.pos.X, st.pos.Y, s.X, s.Y
    local m = st.mask
    local tl, tr, br, bl = (not m) or m.tl == true, (not m) or m.tr == true, (not m) or m.br == true, (not m) or m.bl == true
    if st.filled then
        local T = st.transp or 1
        st.mid.Position, st.mid.Size = Vector2.new(x, y + r), Vector2.new(w, h - 2 * r)
        st.mid.Visible = h - 2 * r > 0
        for i = 1, st.pR do
            local top, bot = st.top[i], st.bot[i]
            local a1, a2, a3, a4 = st.aa[4 * i - 3], st.aa[4 * i - 2], st.aa[4 * i - 1], st.aa[4 * i]
            if i <= r then
                local dy = r - (i - 0.5) -- arc centre to this pixel row's centre
                local inset = r - math.sqrt(math.max(0, r * r - dy * dy))
                local ci = math.ceil(inset - 0.001)
                local cov = ci - inset    -- covered share of the boundary pixel just outside the strip
                local ty, by = y + i - 1, y + h - i
                local cTL, cTR, cBL, cBR = tl and ci or 0, tr and ci or 0, bl and ci or 0, br and ci or 0
                top.Position, top.Size = Vector2.new(x + cTL, ty), Vector2.new(w - cTL - cTR, 1)
                bot.Position, bot.Size = Vector2.new(x + cBL, by), Vector2.new(w - cBL - cBR, 1)
                top.Visible, bot.Visible = true, true
                local aa = cov > 0.03 and ci >= 1
                a1.Position, a2.Position = Vector2.new(x + ci - 1, ty), Vector2.new(x + w - ci, ty)
                a3.Position, a4.Position = Vector2.new(x + ci - 1, by), Vector2.new(x + w - ci, by)
                local on = { tl, tr, bl, br }
                for q, a in ipairs({ a1, a2, a3, a4 }) do
                    a.Size = Vector2.new(1, 1)
                    st.cov[a] = cov
                    a.Transparency = T * cov
                    a.Visible = aa and on[q]
                end
            else
                top.Visible, bot.Visible, a1.Visible, a2.Visible, a3.Visible, a4.Visible = false, false, false, false, false, false
            end
        end
    else
        -- outline of thickness t: edges as rects, corners as rings between radius r and r - t
        local t = math.max(1, math.min(r, math.floor((st.thick or 1) + 0.5)))
        local ri = r - t
        local E = st.edges
        local rTL, rTR, rBR, rBL = tl and r or 0, tr and r or 0, br and r or 0, bl and r or 0
        local edgesOn = not st.arcOnly
        -- top / bottom span between the corners; left / right start below a square corner's top edge
        S.rrPix(st, E[1], x + rTL, y, w - rTL - rTR, edgesOn and 1 or 0) E[1].Size = Vector2.new(math.max(1, w - rTL - rTR), t)
        S.rrPix(st, E[2], x + rBL, y + h - t, w - rBL - rBR, edgesOn and 1 or 0) E[2].Size = Vector2.new(math.max(1, w - rBL - rBR), t)
        local lT, lB = tl and r or t, bl and r or t
        local rT, rB = tr and r or t, br and r or t
        E[3].Position, E[3].Size = Vector2.new(x, y + lT), Vector2.new(t, math.max(1, h - lT - lB))
        E[4].Position, E[4].Size = Vector2.new(x + w - t, y + rT), Vector2.new(t, math.max(1, h - rT - rB))
        E[3].Visible, E[4].Visible = edgesOn and h - lT - lB >= 1, edgesOn and h - rT - rB >= 1
        st.cov[E[3]], st.cov[E[4]] = 1, 1
        E[3].Transparency, E[4].Transparency = st.transp or 1, st.transp or 1
        local rounded = { tl, tr, br, bl }
        for c = 1, 4 do
            local rows = st.ring[c]
            local right = (c == 2 or c == 3)
            local bottom = (c >= 3)
            for i = 1, st.pR do
                local strip, aO, aI = rows[i][1], rows[i][2], rows[i][3]
                if rounded[c] and i <= r then
                    local py = bottom and (y + h - i) or (y + i - 1)
                    local dy = r - (i - 0.5)
                    local xo = r - math.sqrt(math.max(0, r * r - dy * dy))               -- outer boundary, inset from the side
                    local xi = (dy < ri) and (r - math.sqrt(ri * ri - dy * dy)) or r     -- inner boundary (r = past the corner)
                    local p0, p1 = math.ceil(xo - 0.001), math.floor(xi + 0.001)
                    if p0 <= p1 then
                        S.rrPix(st, strip, S.rrSx(right, x, w, p0, p1 - p0), py, p1 - p0, (p1 - p0 >= 1) and 1 or 0)
                        S.rrPix(st, aO, S.rrSx(right, x, w, p0 - 1, 1), py, 1, (p0 >= 1) and (p0 - xo) or 0)
                        S.rrPix(st, aI, S.rrSx(right, x, w, p1, 1), py, 1, (xi < r) and (xi - p1) or 0)
                    else -- both boundaries inside one pixel
                        strip.Visible, aI.Visible = false, false
                        S.rrPix(st, aO, S.rrSx(right, x, w, math.floor(xo), 1), py, 1, xi - xo)
                    end
                else
                    strip.Visible, aO.Visible, aI.Visible = false, false, false
                end
            end
        end
    end
    st.shown = true
end
function S.rrFlush()
    local q = S.RRQueue
    if #q == 0 then return end
    S.RRQueue = {}
    for _, st in ipairs(q) do
        st.queued = false
        if not st.removed then S.rrApply(st) end
    end
end

-- ========== FX: images made at runtime ==========
-- A small PNG encoder (grey + alpha, stored deflate) so soft shapes (glows, shadows, solid fills) are generated
-- in Lua and tinted with Image.Color. Needs buffer + bit32; S.FX.ok is false where they're missing (then every
-- effect that needs an image is skipped and the old drawing path is used).
S.FX = { cache = {} }
S.FX.ok = pcall(function()
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do c = (bit32.band(c, 1) == 1) and bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) or bit32.rshift(c, 1) end
        t[i] = c
    end
    S.FX.crcT = t
    assert(buffer.create(1))
end)
function S.FX.crc(b, s, e)
    local c, T = 0xFFFFFFFF, S.FX.crcT
    for i = s, e - 1 do c = bit32.bxor(T[bit32.band(bit32.bxor(c, buffer.readu8(b, i)), 255)], bit32.rshift(c, 8)) end
    return bit32.bxor(c, 0xFFFFFFFF)
end
-- px: buffer of w*h*2 bytes (grey, alpha) -> PNG file as a string
function S.FX.png(w, h, px)
    local rowLen = 1 + w * 2
    local raw = h * rowLen
    local nb = math.max(1, math.ceil(raw / 65535))
    local zl = 2 + raw + 5 * nb + 4
    local b = buffer.create(8 + 25 + 12 + zl + 12)
    local o = 0
    local function u8(v) buffer.writeu8(b, o, v) o += 1 end
    local function u32(v) u8(bit32.rshift(v, 24)) u8(bit32.band(bit32.rshift(v, 16), 255)) u8(bit32.band(bit32.rshift(v, 8), 255)) u8(bit32.band(v, 255)) end
    for _, v in ipairs({ 137, 80, 78, 71, 13, 10, 26, 10 }) do u8(v) end
    u32(13) local cs = o u8(73) u8(72) u8(68) u8(82) u32(w) u32(h) u8(8) u8(4) u8(0) u8(0) u8(0) u32(S.FX.crc(b, cs, o))
    u32(zl) cs = o u8(73) u8(68) u8(65) u8(84) u8(0x78) u8(0x01)
    local r = buffer.create(raw)
    for y = 0, h - 1 do buffer.writeu8(r, y * rowLen, 0) buffer.copy(r, y * rowLen + 1, px, y * w * 2, w * 2) end
    local pos = 0
    for i = 1, nb do
        local n = math.min(65535, raw - pos)
        u8(i == nb and 1 or 0) u8(n % 256) u8(n // 256) u8((65535 - n) % 256) u8((65535 - n) // 256)
        buffer.copy(b, o, r, pos, n) o += n pos += n
    end
    local s1, s2 = 1, 0
    for i = 0, raw - 1 do s1 = (s1 + buffer.readu8(r, i)) % 65521 s2 = (s2 + s1) % 65521 end
    u32(s2 * 65536 + s1) u32(S.FX.crc(b, cs, o))
    u32(0) cs = o u8(73) u8(69) u8(78) u8(68) u32(S.FX.crc(b, cs, o))
    return buffer.tostring(b)
end
-- white image whose alpha is f(x, y) (0..1, sampled at pixel centres)
function S.FX.image(w, h, f)
    local px = buffer.create(w * h * 2)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local i = (y * w + x) * 2
            buffer.writeu8(px, i, 255)
            buffer.writeu8(px, i + 1, math.clamp(math.floor(f(x + 0.5, y + 0.5) * 255 + 0.5), 0, 255))
        end
    end
    return S.FX.png(w, h, px)
end
-- cached by key; nil when images can't be made here
function S.FX.get(key, w, h, f)
    if not S.FX.ok then return nil end
    local c = S.FX.cache[key]
    if c == nil then
        local ok, d = pcall(S.FX.image, w, h, f)
        c = ok and d or false
        S.FX.cache[key] = c
    end
    return c or nil
end
function S.FX.rrSD(x, y, cx, cy, hw, hh, r)
    local qx, qy = math.abs(x - cx) - hw + r, math.abs(y - cy) - hh + r
    return math.min(math.max(qx, qy), 0) + math.sqrt(math.max(qx, 0) ^ 2 + math.max(qy, 0) ^ 2) - r
end
function S.FX.solid() return S.FX.get("solid", 4, 4, function() return 1 end) end
-- radial gaussian: visible radius is ~45% of the drawn size
function S.FX.glow()
    return S.FX.get("glow", 96, 96, function(x, y) local d = math.sqrt((x - 48) ^ 2 + (y - 48) ^ 2) / 21 return math.exp(-d * d) end)
end
-- hollow soft edge around a w x h rounded rect (inside left empty), made at half size. Used for the tab Halo
-- glow. Cached per size; returns the PNG or nil.
function S.FX.edge(w, h, r, m, power)
    w, h = math.floor(w + 0.5), math.floor(h + 0.5)
    local iw, ih = math.ceil((w + 2 * m) / 2), math.ceil((h + 2 * m) / 2)
    -- image px -> logical px over the exact drawn area (the size is rounded, so x and y scale separately)
    local sx, sy = (w + 2 * m) / iw, (h + 2 * m) / ih
    return S.FX.get("edge" .. w .. "x" .. h .. "r" .. r .. "m" .. m .. "p" .. power, iw, ih, function(x, y)
        local sd = S.FX.rrSD(x * sx, y * sy, w / 2 + m, h / 2 + m, w / 2, h / 2, r)
        if sd < 0 then return 0 end
        local k = sd / m
        return math.exp(-k * k * power)
    end)
end
-- a glow Image (scaled like every UI drawing); nil when images can't be made
function S.FX.newGlow(z)
    local d = S.FX.glow()
    if not d then return nil end
    return S.New("Image", { Data = d, Color = S.Theme.C1, Transparency = 0, ZIndex = z, Visible = false, Size = Vector2.new(1, 1) })
end
-- centre a glow on (cx, cy), size s (logical px)
function S.FX.place(g, cx, cy, sw, sh)
    sh = sh or sw
    g.Position = Vector2.new(cx - sw / 2, cy - sh / 2)
    g.Size = Vector2.new(sw, sh)
end
-- rounded fills through one Image with native Rounding (off Matcha; Matcha has native Corner)
function S.rrImgOn() return S.FX.ok and not S.FX.noImgRound and S.FX.solid() ~= nil end
function S.rrImage(st)
    local ok, o = pcall(Drawing.new, "Image")
    if not ok or not o then S.FX.noImgRound = true return nil end
    if _G.LS_ALL_DRAWINGS then _G.LS_ALL_DRAWINGS[o] = true end
    o = S.wrapDrawing(o, "Image")
    o.Data = S.FX.solid()
    o.Color, o.Transparency, o.ZIndex, o.Visible = st.color or Color3.new(1, 1, 1), st.transp or 1, st.z or 1, false
    st.img = o
    return o
end

-- frame budget for background work (PNG decode, resample, blur, glass): every heavy loop calls S.budget() each
-- row or chunk. After about 2.5 ms of work in a frame, the jobs yield to leave time for rendering.
-- One shared clock: several background jobs together still stay inside the budget.
-- The budget is per FRAME, shared by every background thread: the first budgeted work in a frame starts the clock,
-- and every thread that resumes later in that frame yields once 2.5 ms are used (each thread restarting the clock
-- let 5 jobs take ~5 x 2.5 ms of one frame during load).
S.BudgetT0 = os.clock()
S.PerfT0 = perfT0
S.frameNo = 0
local bootSample: ((number) -> ())?
if not S.Env.matcha then
    pcall(function()
        S.FrameConn = game:GetService("RunService").RenderStepped:Connect(function(dt)
            S.frameNo = S.frameNo + 1
            if bootSample then pcall(bootSample, dt) end
        end)
    end)
end
function S.budget()
    local now = os.clock()
    if S.bFrame ~= S.frameNo then S.bFrame, S.bStart = S.frameNo, now end
    if now - S.bStart > 0.0015 and coroutine.isyieldable() then -- 1.5 ms: leaves room under 8.3 ms (120 fps) even during the intro
        task.wait()
        return true
    end
    return false
end
-- load in steps: the library's own build (shell, Settings page, CreateWindow) used to run in ONE frame (~80 ms with the
-- compile). At these boundaries it hands the frame back when it has used its budget. Not on Matcha (no yields there).
function S.loadYield()
    if S.Env and not S.Env.matcha and coroutine.isyieldable() and os.clock() - S.BudgetT0 > 0.002 then
        task.wait()
        S.BudgetT0 = os.clock()
    end
end
-- UI scale: the whole library lays out in logical px; this layer multiplies geometry by S.K on write
-- and hands the logical value back on read. Mouse and viewport are divided by S.K where they are read.
S.K = 1.15
S.SCALED = { Position = true, Size = true, From = true, To = true, PointA = true, PointB = true, PointC = true, Radius = true, Corner = true, Rounding = true }
S.ScaleLogical = setmetatable({}, { __mode = "k" })
-- Drawing renders independently of Luau. Keep intermediate layout/control writes private until
-- clipping has computed the final state; otherwise a hidden row flashes outside the viewport.
S.DrawQueue, S.DrawBatch = {}, false
function S.drawBegin()
    local owner = not S.DrawBatch
    S.DrawBatch = true
    return owner
end
function S.drawQueue(e, k, v)
    e.pending[k] = v
    if not e.queued then e.queued = true S.DrawQueue[#S.DrawQueue + 1] = e end
end
function S.drawClip(o, top, bot)
    local e = S.ScaleLogical[o]
    if e then e.clipTop, e.clipBot = top, bot end
end
function S.drawGeometryNeedsHide(e, pending)
    if not e.appliedVisible or not e.clipTop or not (pending.Position or pending.Size or pending.Radius) then return false end
    local p = e.l.Position
    if not p then return false end
    local lo, hi = p.Y, p.Y
    if e.t == "Square" or e.t == "Image" then
        local old = e.appliedSize
        hi = hi + (old and old.Y or 0)
    elseif e.t == "Text" then
        hi = hi + (tonumber(e.appliedSize) or 0)
        local oldY = (e.appliedPosition or p).Y
        if pending.Size and (oldY < e.clipTop or oldY + (tonumber(e.l.Size) or 0) > e.clipBot) then return true end
    elseif e.t == "Circle" then
        lo, hi = lo - (e.appliedRadius or 0), hi + (e.appliedRadius or 0)
        local oldY, newRadius = (e.appliedPosition or p).Y, e.l.Radius or 0
        if pending.Radius and (oldY - newRadius < e.clipTop or oldY + newRadius > e.clipBot) then return true end
    else return false end
    return lo < e.clipTop or hi > e.clipBot
end
function S.drawFlush()
    local queue = S.DrawQueue
    S.DrawQueue = {}
    -- Scaled rectangle geometry issues one write for each of Position and Size.
    local writes = 0
    for _, e in ipairs(queue) do
        local pending = e.pending
        e.pending, e.queued = {}, false
        if not S.unloaded and not e.removed then
            -- Hide before moving an object out of view. Show only after its clipped geometry,
            -- image data and opacity are ready. A true->false intent never reaches the renderer.
            local hideGeometry = S.drawGeometryNeedsHide(e, pending)
            if pending.Visible == false or hideGeometry then
                e.o.Visible = false
                writes = writes + 1
            end
            if (e.t == "Square" or e.t == "Image") and (pending.Position or pending.Size) then
                S.applyScaled(e.o, e.t, "Position", e.l.Position, e.l)
                pending.Position, pending.Size = nil, nil
                writes = writes + 2
            end
            for k, v in pairs(pending) do
                if k ~= "Visible" then
                    if S.SCALED[k] then S.applyScaled(e.o, e.t, k, v, e.l) else e.o[k] = v end
                    writes = writes + 1
                end
            end
            if pending.Visible == true or (hideGeometry and e.c.Visible == true) then
                e.o.Visible = true
                writes = writes + 1
            end
            e.appliedPosition, e.appliedSize, e.appliedRadius = e.l.Position, e.l.Size, e.l.Radius
            if e.c.Visible ~= nil then e.appliedVisible = e.c.Visible end
        end
    end
    return writes
end
function S.drawEnd(owner)
    if owner then S.DrawBatch = false S.drawFlush() end
end
function S.applyScaled(o, t, k, v, l)
    local K = S.K
    if (t == "Square" or t == "Image") and (k == "Position" or k == "Size") then
        -- both edges rounded from the same logical edges, so neighbouring rects never gap or overlap
        local p, s = l.Position or Vector2.new(0, 0), l.Size or Vector2.new(0, 0)
        local x0, y0 = math.floor(p.X * K + 0.5), math.floor(p.Y * K + 0.5)
        o.Position = Vector2.new(x0, y0)
        o.Size = Vector2.new(math.floor((p.X + s.X) * K + 0.5) - x0, math.floor((p.Y + s.Y) * K + 0.5) - y0)
    elseif t == "Text" and k == "Size" then
        o[k] = math.floor(v * K + 0.5)
    elseif k == "Radius" or k == "Corner" or k == "Rounding" then
        o[k] = v * K
    elseif t == "Text" then
        o[k] = Vector2.new(math.floor(v.X * K + 0.5), math.floor(v.Y * K + 0.5))
    else
        o[k] = Vector2.new(v.X * K, v.Y * K)
    end
end
-- writes are cached: setting a property to the value it already has is skipped (a relayout re-sets thousands of
-- unchanged values and every executor property write costs; this was most of a ~34 ms relayout). Reads of written
-- properties come from the cache too.
function S.scaleDrawing(o, t)
    local l, c = {}, {}
    local e = { o = o, t = t, l = l, c = c, pending = {}, appliedVisible = false }
    local p = setmetatable({}, {
        __index = function(_, k)
            local lv = l[k]
            if lv ~= nil then return lv end
            lv = c[k]
            if lv ~= nil then return lv end
            local v = o[k]
            if type(v) == "function" then
                return function(_, ...)
                    if k == "Remove" or k == "Destroy" then e.removed = true end
                    return v(o, ...)
                end
            end
            if k == "TextBounds" and v then return Vector2.new(v.X / S.K, v.Y / S.K) end
            return v
        end,
        __newindex = function(_, k, v)
            -- after Unload this instance's objects are gone and Potassium hands their ids to the NEXT load: a late write
            -- from a background job could then hide or blank the next menu.
            if S.unloaded then return end
            if S.SCALED[k] then
                if l[k] == v and v ~= nil then return end
                l[k] = v
                if S.DrawBatch and not e.immediate then S.drawQueue(e, k, v)
                else
                    S.applyScaled(o, t, k, v, l)
                    e.appliedPosition, e.appliedSize, e.appliedRadius = l.Position, l.Size, l.Radius
                end
            else
                if k == "Data" then
                    if S.DrawBatch and not e.immediate then S.drawQueue(e, k, v) else o[k] = v end
                    return -- re-setting picture data can intentionally force a decode
                end
                if c[k] == v and v ~= nil then return end
                c[k] = v
                if S.DrawBatch and not e.immediate then S.drawQueue(e, k, v)
                else o[k] = v if k == "Visible" then e.appliedVisible = v end end
            end
        end,
    })
    S.ScaleLogical[p] = e
    return p
end
-- screen size in logical px (explicit constructor: Matcha's Vector2 may lack arithmetic operators)
function S.vpLogical()
    local v = workspace.CurrentCamera.ViewportSize
    return Vector2.new(v.X / S.K, v.Y / S.K)
end
-- pictures are resampled to their exact screen size at load; S.setScale redoes them once the slider settles (0.4 s)
S.Rescalers = {}
function S.onRescale(fn) table.insert(S.Rescalers, fn) end
function S.rescaleSoon()
    S.rescaleGen = (S.rescaleGen or 0) + 1
    local g = S.rescaleGen
    task.delay(0.4, function()
        if g ~= S.rescaleGen then return end
        for _, fn in ipairs(S.Rescalers) do task.spawn(pcall, fn) end
    end)
end
function S.setScale(pct)
    S.K = math.max(0.75, math.min(1.6, (tonumber(pct) or 115) / 100))
    for _, e in pairs(S.ScaleLogical) do
        for k, v in pairs(e.l) do pcall(S.applyScaled, e.o, e.t, k, v, e.l) end
    end
    S.vp = nil -- re-read the viewport in logical px next frame
    if S.calibrateFont then S.calibrateFont() end -- glyph widths shift slightly with the rounded font size
    S.rescaleSoon()
    if S.Win then S.Win.dirty = true end
end

local UI = { Objects = {}, Version = "step14", WheelConns = {}, created = false }
_G.FALUI = UI

-- The boot sampler shares the budget connection until UI.Conn takes over. Phase records and
-- the hitch ring are allocated once, including the scratch section totals used by each UI callback.
S.PERF_BINS = { 4.2, 8.3, 16.7, 33.3, math.huge }
S.PERF_SECTIONS = { "relayout", "updateControls", "clipRows", "snow", "toasts", "overlays",
    "glassBlurRects", "intro", "drawFlush", "rrFlush", "other" }
S.Perf = { marks = {}, ph = {}, sections = {}, hitches = table.create(8), hitchNext = 1, hitchCount = 0,
    sent = 0, delivered = 0, created = 0, freed = 0, peak = 0, nextStats = 0 }
for i = 1, 8 do S.Perf.hitches[i] = {} end
for _, name in ipairs({ "load", "intro", "settle", "spotlight", "open", "closed" }) do
    local sections = {}
    for _, key in ipairs(S.PERF_SECTIONS) do sections[key], S.Perf.sections[key] = 0, 0 end
    S.Perf.ph[name] = { n = 0, sum = 0, worst = 0, s120 = 0, s60 = 0, bins = { 0, 0, 0, 0, 0 },
        uiN = 0, uiSum = 0, uiWorst = 0, blurN = 0, blurSum = 0, sections = sections,
        drawEntries = 0, drawMax = 0, drawWrites = 0, relayouts = 0, cpuN = 0, cpuSum = 0, gpuN = 0, gpuSum = 0 }
end

function S.perfMark(name)
    S.Perf.marks[name] = math.floor((os.clock() - S.PerfT0) * 1000 + 0.5)
    S.Perf.lastMark = name
end
function S.perfBootMark(name)
    if not S.Perf.readyT then S.perfMark(name) end
end
function S.perfPhase(now)
    if not UI.created then return "load" end
    -- The window state is defined below the boot sampler.
    local state: any = S
    if state.Intro then return "intro" end
    if not S.Perf.readyT or now - S.Perf.readyT < 5 then return "settle" end
    if state.Spot and state.Spot.open then return "spotlight" end
    return state.Win.visible and "open" or "closed"
end

-- Call only from UI-owned failure branches. Consumer callbacks have their own protected boundaries.
function S.perfError(where: string, err: unknown)
    pcall(function()
        local msg: string = type(err) == "string" and err or ("(" .. type(err) .. " error)")
        msg = msg:match("^[^\r\n]*") or ""
        local source, detail = msg:match("^(.-):%d+:[ \t]*(.*)$")
        if source and detail then
            local name = source:gsub("^@", ""):match("[^/\\]+$")
            if source == "" or source:match('^%[string ".*"%]$') or name == "legosense_ui_src.lua"
                or name == "legosense_ui_src.luau" or name == "legosense_ui_preview" then
                msg = detail
            elseif debug and type(debug.info) == "function" then
                local sourceInfo = debug.info :: (number, string) -> string
                local ok, chunk = pcall(sourceInfo, 2, "s")
                if ok and type(chunk) == "string" and (source == chunk or source == chunk:gsub("^@", "")) then
                    msg = detail
                end
            end
        end
        -- Protect JSON encoding from malformed error strings and keep complete UTF-8 characters.
        if not utf8.len(msg :: string) then msg = msg:gsub("[\128-\255]", "?") end
        local limit = utf8.offset(msg :: string, 301)
        if limit then msg = msg:sub(1, limit - 1) end

        local P = (S :: any).Perf
        local errors = P.errors
        if errors then
            for _, entry in ipairs(errors) do
                if entry.where == where and entry.msg == msg then
                    entry.count = entry.count + 1
                    return
                end
            end
            if #errors >= 10 then
                P.droppedErrors = (P.droppedErrors or 0) + 1
                return
            end
        end

        local now = os.clock()
        local entry = { msg = msg, count = 1, firstS = math.floor((now - S.PerfT0) * 10 + 0.5) / 10,
            phase = S.perfPhase(now), where = where }
        if errors then
            errors[#errors + 1] = entry
        else
            P.errors = { entry }
        end
    end)
end

function S.perfCPU(st) return st.RenderCPUFrameTime end
function S.perfGPU(st) return st.RenderGPUFrameTime end
function S.perfStats()
    local P = S.Perf
    if not P.stats then
        local ok, st = pcall(function() return game:GetService("Stats") end)
        if ok then P.stats = st end
    end
    if not P.stats then return nil, nil end
    local okC, cpu = pcall(S.perfCPU, P.stats)
    local okG, gpu = pcall(S.perfGPU, P.stats)
    return okC and type(cpu) == "number" and cpu >= 0 and cpu < math.huge and cpu * 1000 or nil,
        okG and type(gpu) == "number" and gpu >= 0 and gpu < math.huge and gpu * 1000 or nil
end

function S.perfFrame(dt)
    local P, now = S.Perf, os.clock()
    local phase = S.perfPhase(now)
    -- RenderStepped's delta spans the preceding render interval. Carry its phase and UI costs
    -- across the boundary so the last intro frame is still an intro hitch.
    local previous = P.framePhase or phase
    local sample = P.ph[previous]
    local ms = dt * 1000
    sample.n, sample.sum = sample.n + 1, sample.sum + ms
    if ms > sample.worst then sample.worst = ms end
    if ms > 8.33 then sample.s120 = sample.s120 + 1 end
    if ms > 16.7 then sample.s60 = sample.s60 + 1 end
    for i, b in ipairs(S.PERF_BINS) do
        if ms <= b then sample.bins[i] = sample.bins[i] + 1 break end
    end
    if ms > 100 then
        local h = P.hitches[P.hitchNext]
        h.phase, h.ms, h.uptimeS = previous, ms, now - S.PerfT0
        h.section, h.sectionMs = P.biggestSection or "other", P.biggestMs or 0
        h.lastMark = (previous == "load" or previous == "intro") and P.lastMark or nil
        P.hitchNext = P.hitchNext % #P.hitches + 1
        P.hitchCount = math.min(P.hitchCount + 1, #P.hitches)
    end
    if now >= P.nextStats then
        P.nextStats = now + 0.5
        local cpu, gpu = S.perfStats()
        if cpu then sample.cpuN, sample.cpuSum = sample.cpuN + 1, sample.cpuSum + cpu end
        if gpu then sample.gpuN, sample.gpuSum = sample.gpuN + 1, sample.gpuSum + gpu end
    end
    if phase == "settle" and not P.readyT then
        P.readyT = now
        S.perfMark("ready")
    end
    P.framePhase, P.biggestSection, P.biggestMs = phase, nil, nil
end

function S.perfSection(name, now)
    local P = S.Perf
    if not P.section then return end
    now = now or os.clock()
    P.sections[P.section] = P.sections[P.section] + (now - P.sectionT)
    P.section, P.sectionT = name, now
end

function S.perfUIEnd(started, entries, writes, finished)
    S.perfSection(nil, finished)
    local P = S.Perf
    local phase = P.ph[P.framePhase]
    local elapsed = finished - started
    phase.uiN, phase.uiSum = phase.uiN + 1, phase.uiSum + elapsed
    phase.uiWorst = math.max(phase.uiWorst, elapsed)
    phase.drawEntries, phase.drawWrites = phase.drawEntries + entries, phase.drawWrites + writes
    phase.drawMax = math.max(phase.drawMax, entries)
    local biggest, ms = "other", 0
    for _, key in ipairs(S.PERF_SECTIONS) do
        local duration = P.sections[key]
        phase.sections[key] = phase.sections[key] + duration
        if duration > ms then biggest, ms = key, duration end
        P.sections[key] = 0
    end
    P.biggestSection, P.biggestMs = biggest, ms * 1000
end

function S.perfBlur(phase, elapsed)
    local p = S.Perf.ph[phase]
    p.blurN, p.blurSum = p.blurN + 1, p.blurSum + elapsed
end

S.perfMark("librarySetup")
bootSample = S.perfFrame

-- disk layout: <FOLDER>/<CFGSUB>/name.json for configs, <FOLDER>/settings.json etc.
-- FOLDER derives from the window Title (CreateWindow), default "Legosense".
-- storage: one root for every script made with LegoSense. Each script gets its own folder under it, named by
-- CreateWindow{ Folder = ... } (or FileSettings.Folder), else by its Title - never by game, so two scripts in one game
-- never share files. Shared downloads (icons, avatar, theme art) live in LegoSense/_cache for every script.
--   LegoSense/<script>/settings.json, autoload.txt, configs/<name>.json, discord/   |   LegoSense/_cache/...
S.ROOT = "LegoSense"
S.CACHE = S.ROOT .. "/_cache"
S.FOLDER = S.ROOT .. "/Default"
S.CFGSUB = "configs"
-- makefolder for every level of a path (some executors don't create parents)
function S.ensureDir(path)
    local cur = ""
    for part in tostring(path):gmatch("[^/]+") do
        cur = (cur == "") and part or (cur .. "/" .. part)
        if not isfolder(cur) then pcall(makefolder, cur) end
    end
end
-- one-time copy of a script's pre-root folder (<Title>/ at the workspace top) into LegoSense/<Title>/; the old folder
-- is left as it was. Downloaded caches are skipped (they're refetched into _cache).
function S.migrateOld(name)
    local old = name
    if old:lower() == S.ROOT:lower() or not isfolder(old) or isfile(S.FOLDER .. "/settings.json") then return end
    local skip = { icons48 = true }
    local function copy(src, dst)
        S.ensureDir(dst)
        local ok, list = pcall(listfiles, src)
        if not ok or type(list) ~= "table" then return end
        for _, f in ipairs(list) do
            local base = tostring(f):match("[^/\\]+$")
            if base and not skip[base] and not base:match("^avatar") and not base:match("^themeimg_") and not base:match("^nyan_") and base ~= "logo2.txt" then
                if isfolder(f) then copy(f, dst .. "/" .. base)
                else pcall(function() writefile(dst .. "/" .. base, readfile(f)) end) end
            end
        end
    end
    pcall(copy, old, S.FOLDER)
end
function S.cfgDir() return S.FOLDER .. "/" .. S.CFGSUB end

-- numeric/config constants live here (own table, kept out of the ~200 local-register budget)
S.Const = {}

function S.C3(r, g, b) return Color3.fromRGB(r, g, b) end
S.BaseC1 = S.C3(228, 230, 234)
S.BaseC2 = S.C3(176, 180, 188)
S.Theme = {
    Dark = S.C3(13, 14, 16), Bg = S.C3(34, 35, 38), Panel = S.C3(43, 44, 48), PanelHov = S.C3(52, 53, 58),
    Control = S.C3(54, 55, 60), Track = S.C3(78, 80, 86), C1 = S.BaseC1, C2 = S.BaseC2,
    Header = S.C3(190, 193, 200), Text = S.C3(219, 225, 211), Dim = S.C3(130, 137, 118),
    Knob = S.C3(245, 248, 240), White = S.C3(255, 255, 255),
}
S.Const.ALPHA_BG = 0.72
S.Const.ALPHA_BAR = 0.72
S.Const.ALPHA_CARD = 0.6
-- cascade after the intro's TV unfold (S.Casc = start clock): tabs slide in, then cards rise in one after another
S.Const.CASC = { STEP = 0.18, DUR = 0.9, RISE = 14, SLIDE = 10 }
-- Switching tabs or Settings sub-tabs replays the card cascade faster than the intro.
S.Const.CASC_SWITCH = { STEP = 0.07, DUR = 0.5, RISE = 10, SLIDE = 10 }
function S.cascK(i, t0) -- 0..1 ease-out for the i-th element from start clock t0 (default S.Casc); 1 when no cascade runs
    if not S.Casc then return 1 end
    t0 = t0 or S.Casc
    local C = S.CascSpeed or S.Const.CASC
    local sp = (S.Cfg and S.Cfg.animSpeed or 100) / 100
    local p = math.clamp(((os.clock() - t0) * sp - (i - 1) * C.STEP) / C.DUR, 0, 1)
    if p < 1 then S.cascLive = true end
    return 1 - (1 - p) ^ 3
end
-- cards of the page just opened rise + fade in, staggered (sidebar tabs untouched: S.Casc is set in the past)
function S.cascSwitch()
    if not S.animOn() or S.Intro or S.Cfg.cascSwitch == false then return end
    local now = os.clock()
    S.Casc, S.CascCards, S.CascSpeed = now - 100, now, S.Const.CASC_SWITCH
end
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

S.Cfg = {
    animations = true, hoverFx = true, opacity = 1.0, intro = true, winGlow = false, tabGlow = "Bar",
    rainbow = false, rainbowSpeed = 100,
    checkbox = false, collapseSidebar = false, sidebarMode = "Auto", inlineDropdowns = false, blockInput = true,
    tabLayout = "Sidebar", search = "Bar", font = "UI",
    notifyTime = 5, menuKey = 0x24, keybindOverlay = false,
    bgFx = "Off", border = 0, frost = 0, cornerRadius = 100, uiScale = 115,
    perfMode = false, preset = "Mono",
    autoSave = true, autoLoad = "none", fxColor = S.BaseC1,
    -- customisation (Settings > Theme / Effects / Interface / Overlays)
    bgAlpha = 72, cardAlpha = 60, barAlpha = 72, themeImg = true, themeImgA = 100, themeImgUrl = "",
    glows = true, haloFx = true, scrollGlow = true,
    blurStrength = 100, blurWin = true, blurOv = true, blurTips = true, blurSpot = true,
    animSpeed = 100, cascSwitch = true, ripples = true, overscroll = true, snowAmount = 28, snowSpeed = 100,
    spotOn = true, spotKey = 0x20, rememberPos = false, openTab = "Last used", tipDelay = 0.4, truncDelay = 2.5,
    sbWidth = 27, scrollSpeed = 100, smoothScroll = true,
    ovOpacity = 100, ovLock = false, kbActiveOnly = false, notifCorner = "Bottom right", notifMax = 6, watermark = false,
}
-- Matcha has its own font ids; standard Drawing (Potassium etc.) only has 0-3 (Drawing.Fonts), and ids above 3 broke
-- text there (TextBounds errors "invalid vector subscript"), so each executor gets only the fonts it really has
if S.Env.matcha then
    S.FontNames = { "UI", "System", "SystemBold", "Minecraft", "Monospace", "Pixel" }
    S.FontIds = { UI = 0, System = 1, SystemBold = 2, Minecraft = 4, Monospace = 5, Pixel = 7 }
else
    S.FontNames = { "UI", "System", "Plex", "Monospace" }
    S.FontIds = { UI = 0, System = 1, Plex = 2, Monospace = 3 }
end

S.Win = { x = 380, y = 140, w = 820, h = 620, visible = true, dirty = true }
S.KeyRows = {}       -- keybind rows with a Mode (polled every frame by S.pollKeyRows)
S.onUnloadList = {}  -- Library:OnUnload handlers
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
    if not ok then
        S.perfError("create", o)
        print("LEGOSENSE|create fail " .. t .. ": " .. tostring(o))
        return nil
    end
    -- hide BEFORE anything else: Potassium draws on its own thread, so a new object set up in pairs() order could
    -- be drawn for a frame at its default spot (top-left of the screen) before Visible = false landed
    pcall(function() o.Visible = false end)
    if _G.LS_ALL_DRAWINGS then _G.LS_ALL_DRAWINGS[o] = true end -- raw object, for the next load's orphan sweep
    if S.Env.drawing and not S.Env.matcha then
        o = S.wrapDrawing(o, t)
        if t == "Square" then o = S.roundRect(o) end -- no native Corner here: fake it (see S.roundRect)
    end
    if S.Env.drawing then o = S.scaleDrawing(o, t) end
    for k, v in pairs(props) do
        if k ~= "Visible" then
            local okP, e = pcall(function() o[k] = v end)
            if not okP then
                S.perfError("property", e)
                print("LEGOSENSE|" .. t .. "." .. k .. " set fail: " .. tostring(e))
            end
        end
    end
    if t == "Text" and props.Outline == nil then
        pcall(function() o.Outline = false end)
    end
    -- text made after a font change (toasts, dialogs, late rows) follows the current Font setting
    if t == "Text" and S.Cfg.font ~= "UI" then pcall(function() o.Font = S.FontIds[S.Cfg.font] or 0 end) end
    if props.Visible then pcall(function() o.Visible = true end) end -- last, once everything else is in place
    S.Bases[o] = props.Transparency or 1
    S.Shapes[o] = t
    if t == "Text" then table.insert(S.TextObjs, o) end
    table.insert(UI.Objects, o)
    local P = S.Perf
    P.created = P.created + 1
    P.peak = math.max(P.peak, #UI.Objects)
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
    -- whole screen pixels: with UI scale (S.K, e.g. 1.15) a 1 px line at some y landed across two pixel rows and read
    -- thicker (the Friends header). Snap y to a device pixel and make the line exactly one device pixel tall.
    local K = S.K or 1
    yy = math.floor(yy * K + 0.5) / K
    local lh = 1 / K
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
            o.Size = Vector2.new(xB - xA, lh)
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

-- Only this permanently hidden probe bypasses frame buffering: TextBounds must describe
-- the text we are measuring now, not the previous frame's tooltip or wrap candidate.
function S.textWidth(text, size, font)
    size = size or S.FS - 1
    text = tostring(text or "")
    if not S.Env.matcha then
        local ok, width = pcall(function()
            local m = S.wrapM
            if not m then
                local batch = S.DrawBatch
                S.DrawBatch = false
                local made, value = pcall(S.New, "Text", { Text = "", Font = 0, Size = size, Transparency = 0, Visible = false })
                S.DrawBatch = batch
                if not made or not value then return nil end
                m, S.wrapM = value, value
                local e = S.ScaleLogical[m]
                if e then e.immediate = true end
            end
            m.Size = size
            m.Font = font or S.FontIds[S.Cfg.font] or 0
            m.Text = text
            local b = m.TextBounds
            return b and b.X
        end)
        if ok and width and (width > 0 or text == "") then return width end
    end
    return #text * S.CHAR_W * size / S.FS
end
function S.textChars(text)
    local chars = {}
    if utf8 and utf8.codes then
        local ok = pcall(function() for _, cp in utf8.codes(text) do chars[#chars + 1] = utf8.char(cp) end end)
        if ok then return chars end
        chars = {}
    end
    for i = 1, #text do chars[#chars + 1] = text:sub(i, i) end
    return chars
end
-- Measured word wrapping, including long unbroken tokens and explicit paragraph breaks.
function S.wrapPx(label, availPx, size)
    size, availPx = size or S.FS - 1, math.max(1, availPx)
    local lines, cur = {}, ""
    for paragraph in (tostring(label) .. "\n"):gmatch("(.-)\n") do
        local before = #lines
        for word in paragraph:gmatch("%S+") do
            if S.textWidth(word, size) > availPx then
                if cur ~= "" then lines[#lines + 1], cur = cur, "" end
                for _, ch in ipairs(S.textChars(word)) do
                    if cur ~= "" and S.textWidth(cur .. ch, size) > availPx then lines[#lines + 1], cur = cur, "" end
                    cur = cur .. ch
                end
            else
                local candidate = cur == "" and word or cur .. " " .. word
                if cur ~= "" and S.textWidth(candidate, size) > availPx then lines[#lines + 1], cur = cur, word
                else cur = candidate end
            end
        end
        if cur ~= "" or #lines == before then lines[#lines + 1], cur = cur, "" end
    end
    return lines
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

-- Block / unblock the game's input while the menu (or Spotlight) is up. Matcha has setrobloxinput.
-- Elsewhere (Potassium has no such call) do it on the Roblox side: a top-priority ContextActionService bind
-- sinks keys / mouse buttons / wheel / mouse movement before the character + camera controls see them, and a
-- see-through Modal button over the screen eats clicks meant for game GUI and tools and frees a locked mouse.
-- The menu itself reads input through iskeypressed / ismouse1pressed / GetMouseLocation, which this doesn't touch.
-- Ctrl held + Space: swallow the Space (no jump) so Ctrl+Space only opens Spotlight. Only with "Block Roblox input" on.
function S.bindCtrlSpace()
    if S.Env.matcha then return end
    pcall(function()
        game:GetService("ContextActionService"):BindActionAtPriority("LegoSenseCtrlSpace", function()
            if S.Cfg.blockInput and iskeypressed(0x11) then return Enum.ContextActionResult.Sink end
            return Enum.ContextActionResult.Pass
        end, false, 100001, Enum.KeyCode.Space)
    end)
end
function S.setGameInput(enabled)
    if S.Env.matcha then pcall(setrobloxinput, enabled) return end
    local okC, cas = pcall(function() return game:GetService("ContextActionService") end)
    if enabled then
        if okC then pcall(function() cas:UnbindAction("LegoSenseBlock") end) end
        if S.blockGui then pcall(function() S.blockGui.Enabled = false end) end
        return
    end
    if okC then
        pcall(function()
            cas:BindActionAtPriority("LegoSenseBlock", function() return Enum.ContextActionResult.Sink end, false, 100000,
                Enum.UserInputType.Keyboard, Enum.UserInputType.MouseButton1, Enum.UserInputType.MouseButton2,
                Enum.UserInputType.MouseButton3, Enum.UserInputType.MouseWheel, Enum.UserInputType.MouseMovement)
        end)
    end
    if not S.blockGui then
        pcall(function()
            local g = Instance.new("ScreenGui")
            g.Name, g.ResetOnSpawn, g.IgnoreGuiInset, g.DisplayOrder = "LegoSenseInputBlock", false, true, 100000
            local b = Instance.new("TextButton")
            b.Size, b.BackgroundTransparency, b.Text, b.AutoButtonColor, b.Modal = UDim2.fromScale(1, 1), 1, "", false, true
            b.Parent = g
            g.Parent = (gethui and gethui()) or game:GetService("CoreGui")
            S.blockGui = g
        end)
    end
    if S.blockGui then pcall(function() S.blockGui.Enabled = true end) end
end

function S.hexOf(c)
    return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function S.inRect(px, py, rx, ry, rw, rh)
    return px >= rx and px <= rx + rw and py >= ry and py <= ry + rh
end

-- Effective FX flags leave the saved preferences in place when switching modes.
function S.animOn() return S.Cfg.animations and not S.Cfg.perfMode end
function S.hoverOn() return S.Cfg.hoverFx and not S.Cfg.perfMode end
function S.glowsOn() return S.Cfg.glows ~= false and not S.Cfg.perfMode end
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
    if not id then name, id = "UI", 0 end -- a font saved on another executor
    S.Cfg.font = name
    for _, t in ipairs(S.TextObjs) do pcall(function() t.Font = id end) end
    S.calibrateFont()
end

-- Every width estimate in the layout (truncate, wrap, chips, headers, overlays) uses S.CHAR_W / S.CHAR_WB.
-- Matcha's font matches the tuned 7 / 9. Elsewhere the font differs, so measure its real average glyph width
-- once per font / scale change; centring spots additionally use S.TW (exact TextBounds).
S.Const.CW_SAMPLE = "The quick brown fox jumps over the lazy dog 0123456789"
function S.calibrateFont()
    if not S.Env.drawing or S.Env.matcha then return end
    S.perfBootMark("fontCalibrationStart")
    local probe = S.New("Text", { Text = S.Const.CW_SAMPLE, Size = S.FS, Font = S.FontIds[S.Cfg.font] or 0, Visible = false, Transparency = 0 })
    if not probe then
        S.perfBootMark("fontCalibrationEnd")
        return
    end
    pcall(function()
        local tb = probe.TextBounds
        if tb and tb.X > 0 then S.CHAR_W = tb.X / #S.Const.CW_SAMPLE end
        probe.Size = S.FS + 4
        tb = probe.TextBounds
        if tb and tb.X > 0 then S.CHAR_WB = tb.X / #S.Const.CW_SAMPLE end
    end)
    S.freeObj(probe)
    if S.Win then S.Win.dirty = true end
    S.perfBootMark("fontCalibrationEnd")
end

S.KEYNAMES = { [0x08] = "Bksp", [0x09] = "Tab", [0x0D] = "Enter", [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt",
    [0x1B] = "Esc", [0x20] = "Space", [0x21] = "PgUp", [0x22] = "PgDn", [0x23] = "End", [0x24] = "Home",
    [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down", [0x2D] = "Ins", [0x2E] = "Del", [-2] = "MB2", [0x01] = "MB1" }
for i = 0x30, 0x39 do S.KEYNAMES[i] = string.char(i) end
for i = 0x41, 0x5A do S.KEYNAMES[i] = string.char(i) end
for i = 0x70, 0x7B do S.KEYNAMES[i] = "F" .. (i - 0x6F) end
function S.keyName(vk) return S.KEYNAMES[vk] or ("K" .. tostring(vk)) end

-- Sharp icons: the lucide PNGs are 48 px and were drawn at 16 * UI scale (~18 screen px): a 2.6:1 shrink with no
-- filtering = jagged / "sharpened" strokes. S.iconSharp decodes the PNG (8-bit grey+alpha or RGBA; a small inflate
-- below), averages it down to the exact screen size (area-weighted box filter) and re-encodes it with S.FX.png.
function S.inflate(src, pos, alive)
    local out, olen = buffer.create(16384), 0
    local function grow(n)
        if olen + n > buffer.len(out) then
            local nb = buffer.create(math.max(buffer.len(out) * 2, olen + n))
            buffer.copy(nb, 0, out, 0, olen)
            out = nb
        end
    end
    local bb, bc, lastY = 0, 0, 0
    local function bits(n)
        while bc < n do bb = bb + bit32.lshift(buffer.readu8(src, pos), bc) pos = pos + 1 bc = bc + 8 end
        local v = bit32.band(bb, bit32.lshift(1, n) - 1)
        bb = bit32.rshift(bb, n) bc = bc - n
        return v
    end
    local function build(lens, n)
        local count, offs, sym = {}, {}, {}
        for i = 0, 15 do count[i] = 0 end
        for i = 0, n - 1 do count[lens[i] or 0] = count[lens[i] or 0] + 1 end
        count[0] = 0
        offs[1] = 0
        for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
        for i = 0, n - 1 do local l = lens[i] or 0 if l ~= 0 then sym[offs[l]] = i offs[l] = offs[l] + 1 end end
        return { count = count, sym = sym }
    end
    local function decode(h)
        local code, first, index = 0, 0, 0
        for len = 1, 15 do
            code = bit32.bor(code, bits(1))
            local c = h.count[len]
            if code - c < first then return h.sym[index + (code - first)] end
            index, first = index + c, (first + c) * 2
            code = code * 2
        end
        error("inflate: bad code")
    end
    local LB = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
    local LE = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
    local DB = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
    local DE = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
    local function codes(lc, dc)
        while true do
            local sym = decode(lc)
            if sym < 256 then grow(1) buffer.writeu8(out, olen, sym) olen = olen + 1
            elseif sym == 256 then return true
            else
                sym = sym - 257
                local len = LB[sym + 1] + bits(LE[sym + 1])
                local ds = decode(dc)
                local dist = DB[ds + 1] + bits(DE[ds + 1])
                grow(len)
                for _ = 1, len do buffer.writeu8(out, olen, buffer.readu8(out, olen - dist)) olen = olen + 1 end
            end
            if olen - lastY > 2048 then
                lastY = olen
                if S.budget() and alive and not alive() then return false end
            end
        end
    end
    local fixedL, fixedD
    repeat
        local final, typ = bits(1), bits(2)
        if typ == 0 then
            bb, bc = 0, 0
            local len = buffer.readu16(src, pos)
            pos = pos + 4
            grow(len) buffer.copy(out, olen, src, pos, len) olen, pos = olen + len, pos + len
        elseif typ == 1 then
            if not fixedL then
                local l = {}
                for i = 0, 143 do l[i] = 8 end for i = 144, 255 do l[i] = 9 end
                for i = 256, 279 do l[i] = 7 end for i = 280, 287 do l[i] = 8 end
                local d = {} for i = 0, 29 do d[i] = 5 end
                fixedL, fixedD = build(l, 288), build(d, 30)
            end
            if not codes(fixedL, fixedD) then return nil end
        elseif typ == 2 then
            local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
            local ORD = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
            local cl = {}
            for i = 0, 18 do cl[i] = 0 end
            for i = 1, hclen do cl[ORD[i]] = bits(3) end
            local ch = build(cl, 19)
            local lens, n = {}, 0
            while n < hlit + hdist do
                local sym = decode(ch)
                if sym < 16 then lens[n] = sym n = n + 1
                else
                    local rep, val = 0, 0
                    if sym == 16 then val, rep = lens[n - 1], 3 + bits(2)
                    elseif sym == 17 then rep = 3 + bits(3)
                    else rep = 11 + bits(7) end
                    for _ = 1, rep do lens[n] = val n = n + 1 end
                end
            end
            local ll, dl = {}, {}
            for i = 0, hlit - 1 do ll[i] = lens[i] end
            for i = 0, hdist - 1 do dl[i] = lens[hlit + i] end
            if not codes(build(ll, hlit), build(dl, hdist)) then return nil end
        else error("inflate: bad block") end
        if S.budget() and alive and not alive() then return nil end
    until final == 1
    return out, olen
end
-- a keybind row's full name: an optional fixed prefix (Spotlight: "Ctrl + ") + the key
function S.rowKeyName(row) return (row.keyPrefix or "") .. S.keyName(row.vk) end
-- PNG -> { w, h, px = BGRA buffer, top row first } (8-bit grey / RGB / palette / grey+alpha / RGBA, not interlaced)
function S.pngDecode(png, alive)
    if type(png) ~= "string" or #png < 45 or png:sub(2, 4) ~= "PNG" then return nil end
    local b = buffer.fromstring(png)
    local function u32(o) return buffer.readu8(b, o) * 16777216 + buffer.readu8(b, o + 1) * 65536 + buffer.readu8(b, o + 2) * 256 + buffer.readu8(b, o + 3) end
    local w, h, depth, ctype = u32(16), u32(20), buffer.readu8(b, 24), buffer.readu8(b, 25)
    local bpp = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[ctype]
    if depth ~= 8 or not bpp or buffer.readu8(b, 28) ~= 0 then return nil end
    local parts, o, plte, trns = {}, 8, nil, nil
    while o + 8 <= buffer.len(b) do
        local len = u32(o)
        local typ = buffer.readstring(b, o + 4, 4)
        if typ == "IDAT" then parts[#parts + 1] = buffer.readstring(b, o + 8, len)
        elseif typ == "PLTE" then plte = buffer.readstring(b, o + 8, len)
        elseif typ == "tRNS" then trns = buffer.readstring(b, o + 8, len)
        elseif typ == "IEND" then break end
        o = o + 12 + len
    end
    local raw = S.inflate(buffer.fromstring(table.concat(parts)), 2, alive) -- skip the 2-byte zlib header
    if not raw then return nil end
    local stride = w * bpp
    local img = buffer.create(stride * h)
    for y = 0, h - 1 do
        local ft, ri, oi = buffer.readu8(raw, y * (stride + 1)), y * (stride + 1) + 1, y * stride
        for x = 0, stride - 1 do
            local v = buffer.readu8(raw, ri + x)
            local a = x >= bpp and buffer.readu8(img, oi + x - bpp) or 0
            local up = y > 0 and buffer.readu8(img, oi - stride + x) or 0
            local c = (x >= bpp and y > 0) and buffer.readu8(img, oi - stride + x - bpp) or 0
            if ft == 1 then v = v + a elseif ft == 2 then v = v + up elseif ft == 3 then v = v + math.floor((a + up) / 2)
            elseif ft == 4 then
                local pp = a + up - c
                local pa, pb, pc = math.abs(pp - a), math.abs(pp - up), math.abs(pp - c)
                v = v + ((pa <= pb and pa <= pc) and a or (pb <= pc and up or c))
            end
            buffer.writeu8(img, oi + x, v % 256)
        end
        if S.budget() and alive and not alive() then return nil end
    end
    local out = buffer.create(w * h * 4)
    for i = 0, w * h - 1 do
        local r, g, bl, al
        local si = i * bpp
        if ctype == 6 then r, g, bl, al = buffer.readu8(img, si), buffer.readu8(img, si + 1), buffer.readu8(img, si + 2), buffer.readu8(img, si + 3)
        elseif ctype == 2 then r, g, bl, al = buffer.readu8(img, si), buffer.readu8(img, si + 1), buffer.readu8(img, si + 2), 255
        elseif ctype == 4 then r = buffer.readu8(img, si) g, bl, al = r, r, buffer.readu8(img, si + 1)
        elseif ctype == 0 then r = buffer.readu8(img, si) g, bl, al = r, r, 255
        else
            local k = buffer.readu8(img, si)
            r, g, bl = (plte and plte:byte(k * 3 + 1) or 0), (plte and plte:byte(k * 3 + 2) or 0), (plte and plte:byte(k * 3 + 3) or 0)
            al = (trns and trns:byte(k + 1)) or 255
        end
        buffer.writeu32(out, i * 4, bl + g * 256 + r * 65536 + al * 16777216)
        if i % 2048 == 2047 and S.budget() and alive and not alive() then return nil end
    end
    return { w = w, h = h, px = out }
end
function S.iconSharp(png, T)
    local dec = S.pngDecode(png)
    if not dec then return nil end
    local w, h = dec.w, dec.h
    local function alpha(x, y) return buffer.readu8(dec.px, (y * w + x) * 4 + 3) / 255 end
    local sx, sy = w / T, h / T
    local px = buffer.create(T * T * 2)
    for ty = 0, T - 1 do
        local y0, y1 = ty * sy, (ty + 1) * sy
        for tx = 0, T - 1 do
            local x0, x1 = tx * sx, (tx + 1) * sx
            local sum = 0
            for yy = math.floor(y0), math.min(h - 1, math.ceil(y1) - 1) do
                local wy = math.min(y1, yy + 1) - math.max(y0, yy)
                for xx = math.floor(x0), math.min(w - 1, math.ceil(x1) - 1) do
                    sum = sum + alpha(xx, yy) * wy * (math.min(x1, xx + 1) - math.max(x0, xx))
                end
            end
            local i = (ty * T + tx) * 2
            buffer.writeu8(px, i, 255)
            buffer.writeu8(px, i + 1, math.clamp(math.floor(sum / (sx * sy) * 255 + 0.5), 0, 255))
        end
    end
    return S.FX.png(T, T, px)
end
-- Images are cropped at the scroll edge. S.cropSet(o, png)
-- decodes the picture once (call it from a loader thread: the decode yields); S.clipObj then shows only the rows inside
-- the view as a TGA (header + copied rows, no checksums: cheap per frame) and moves / shrinks the image to match.
S.Crop = setmetatable({}, { __mode = "k" })
function S.cropSet(o, png, dec)
    if not o or S.Env.matcha then return end
    local c = { data = png }
    S.Crop[o] = c
    if dec then c.w, c.h, c.px = dec.w, dec.h, dec.px return end
    local ok, d = pcall(S.pngDecode, png)
    if ok and d then c.w, c.h, c.px = d.w, d.h, d.px end
end
-- Decode the first image of a standalone GIF frame (the Nyan URLs serve GIF89a, not PNG).
function S.gifDecode(data, alive)
    if #data < 14 or (data:sub(1, 6) ~= "GIF89a" and data:sub(1, 6) ~= "GIF87a") then return nil end
    local function u16(i) return data:byte(i) + data:byte(i + 1) * 256 end
    local w, h, flags, pos = u16(7), u16(9), data:byte(11), 14
    local function palette(bits)
        local colors = {}
        for i = 0, 2 ^ (bits + 1) - 1 do
            local r, g, b = data:byte(pos, pos + 2)
            colors[i], pos = b + g * 256 + r * 65536 + 0xff000000, pos + 3
        end
        return colors
    end
    local colors = bit32.band(flags, 128) ~= 0 and palette(bit32.band(flags, 7)) or nil
    local transparent
    local function blocks()
        local parts = {}
        while pos <= #data do
            local n = data:byte(pos) pos += 1
            if n == 0 then return table.concat(parts) end
            if pos + n - 1 > #data then return nil end
            parts[#parts + 1], pos = data:sub(pos, pos + n - 1), pos + n
        end
        return nil
    end
    while pos <= #data do
        local tag = data:byte(pos) pos += 1
        if tag == 0x21 then
            local kind = data:byte(pos) pos += 1
            local ext = blocks()
            if not ext then return nil end
            if kind == 0xf9 and #ext == 4 then transparent = bit32.band(ext:byte(1), 1) ~= 0 and ext:byte(4) or nil end
        elseif tag == 0x2c then
            local left, top, iw, ih, f = u16(pos), u16(pos + 2), u16(pos + 4), u16(pos + 6), data:byte(pos + 8)
            pos += 9
            if iw < 1 or ih < 1 or left + iw > w or top + ih > h then return nil end
            if bit32.band(f, 128) ~= 0 then colors = palette(bit32.band(f, 7)) end
            if not colors then return nil end
            if transparent then colors[transparent] = 0 end
            local minimum = data:byte(pos) pos += 1
            if minimum < 2 or minimum > 8 then return nil end
            local packed = blocks()
            if not packed then return nil end
            local clear = 2 ^ minimum
            local dict, nextCode, size, previous = {}, clear + 2, minimum + 1, nil
            for i = 0, clear - 1 do dict[i] = string.char(i) end
            local rows = {}
            if bit32.band(f, 64) ~= 0 then
                for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
                    for y = pass[1], ih - 1, pass[2] do rows[#rows + 1] = y end
                end
            else for y = 0, ih - 1 do rows[#rows + 1] = y end end
            local px = buffer.create(w * h * 4)
            local bits, value, at, out = 0, 0, 1, 0
            while true do
                while bits < size do
                    local byte = packed:byte(at)
                    if not byte then return nil end
                    value, bits, at = value + byte * 2 ^ bits, bits + 8, at + 1
                end
                local code = bit32.band(value, 2 ^ size - 1)
                value, bits = bit32.rshift(value, size), bits - size
                if code == clear then
                    nextCode, size, previous = clear + 2, minimum + 1, nil
                elseif code == clear + 1 then
                    return out == iw * ih and { w = w, h = h, px = px } or nil
                else
                    local entry = code < nextCode and dict[code] or (code == nextCode and previous and previous .. previous:sub(1, 1))
                    if not entry or out + #entry > iw * ih then return nil end
                    for i = 1, #entry do
                        local color = colors[entry:byte(i)]
                        if not color then return nil end
                        buffer.writeu32(px, ((top + rows[math.floor(out / iw) + 1]) * w + left + out % iw) * 4, color)
                        out += 1
                        if out % 2048 == 0 and S.budget() and alive and not alive() then return nil end
                    end
                    if previous and nextCode < 4096 then
                        dict[nextCode], nextCode = previous .. entry:sub(1, 1), nextCode + 1
                        if nextCode == 2 ^ size and size < 12 then size += 1 end
                    end
                    previous = entry
                end
            end
        else return nil end
    end
    return nil
end
-- picture resampled to its exact screen size (alpha-weighted box filter) -> { w, h, px = BGRA, data = TGA }. A big
-- picture drawn small (150 px avatar at 41 px) is shrunk by the renderer without filtering = pixelated.
function S.imgFit(png, W, H, alive)
    if S.Env.matcha or not S.FX.ok then return nil end
    -- big pictures (theme art) stay decoded: re-unpacking the PNG on every new size was a ~140 ms frame each while the
    -- window was resized with Theme image blur on. One slot: only the current big picture is kept.
    local big = #png > 50000
    if big then -- another thread already unpacking this picture: wait for it instead of doing it twice
        while S.DecBusy == png do
            task.wait()
            if alive and not alive() then return nil end
        end
    end
    local d = S.DecBig and S.DecBig.png == png and S.DecBig.dec
    if not d then
        if big then S.DecBusy = png end
        local ok
        ok, d = pcall(png:sub(1, 3) == "GIF" and S.gifDecode or S.pngDecode, png, alive)
        if big then S.DecBusy = nil end
        if not ok or not d then return nil end
        if big then S.DecBig = { png = png, dec = d } end
    end
    local w, h, src = d.w, d.h, d.px
    local sx, sy = w / W, h / H
    local px = buffer.create(W * H * 4)
    for ty = 0, H - 1 do
        local y0, y1 = ty * sy, (ty + 1) * sy
        for tx = 0, W - 1 do
            local x0, x1 = tx * sx, (tx + 1) * sx
            local sa, sr, sg, sb, area = 0, 0, 0, 0, 0
            for yy = math.floor(y0), math.min(h - 1, math.ceil(y1) - 1) do
                local wy = math.min(y1, yy + 1) - math.max(y0, yy)
                for xx = math.floor(x0), math.min(w - 1, math.ceil(x1) - 1) do
                    local wgt = wy * (math.min(x1, xx + 1) - math.max(x0, xx))
                    local i = (yy * w + xx) * 4
                    local a = buffer.readu8(src, i + 3) * wgt
                    sb, sg, sr, sa = sb + buffer.readu8(src, i) * a, sg + buffer.readu8(src, i + 1) * a, sr + buffer.readu8(src, i + 2) * a, sa + a
                    area = area + wgt
                end
            end
            local A = area > 0 and sa / area or 0
            local inv = sa > 0 and 1 / sa or 0
            buffer.writeu32(px, (ty * W + tx) * 4, math.floor(sb * inv + 0.5) + math.floor(sg * inv + 0.5) * 256
                + math.floor(sr * inv + 0.5) * 65536 + math.clamp(math.floor(A + 0.5), 0, 255) * 16777216)
        end
        if S.budget() and alive and not alive() then return nil end
    end
    local b = buffer.create(18 + W * H * 4)
    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, W) buffer.writeu16(b, 14, H)
    buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28)
    buffer.copy(b, 18, px, 0, W * H * 4)
    return { w = W, h = H, px = px, data = buffer.tostring(b) }
end
function S.devPx(logical) return math.max(1, math.floor(logical * (S.K or 1) + 0.5)) end
-- picture blurred for "Theme image blur": the resized picture is cached per size, the blur runs at HALF resolution
-- (a quarter of the work; a blurred picture has no detail to lose) as 3 running-sum box passes per axis on
-- premultiplied colour with fractional edge weights. Small radii are upscaled bilinearly into the TGA.
-- alive() is checked between steps so a newer slider value cancels this one. Call from a thread.
S.BlurBase = {}
function S.blurImg(png, W, H, radius, alive)
    alive = alive or function() return true end
    local Y = S.budget
    local bk = #png .. ":" .. W .. "x" .. H
    local fit = S.BlurBase[bk]
    if not fit or fit.png ~= png then
        fit = S.imgFit(png, W, H, alive)
        if not fit then return nil end
        fit.png = png -- equal-length animation frames must not share resized pixels
        S.BlurBase = { [bk] = fit } -- keep only the current size
    end
    if not alive() then return nil end
    local sc = 2
    local w2, h2 = math.max(1, math.floor(W / sc)), math.max(1, math.floor(H / sc))
    local n = w2 * h2
    local nn = sc * sc
    -- the shrunken premultiplied channels don't depend on the radius: made once per size + scale, copied per render
    fit.small = fit.small or {}
    local base = fit.small[sc]
    local ch = { buffer.create(n * 4), buffer.create(n * 4), buffer.create(n * 4), buffer.create(n * 4) } -- f32 b, g, r, a (premultiplied)
    if base then
        for c = 1, 4 do buffer.copy(ch[c], 0, base[c], 0, n * 4) end
    else
    local src = fit.px
    for y = 0, h2 - 1 do
        for x = 0, w2 - 1 do
            local sb, sg, sr, sa = 0, 0, 0, 0
            for dy = 0, sc - 1 do
                for dx = 0, sc - 1 do
                    local v = buffer.readu32(src, (math.min(H - 1, y * sc + dy) * W + math.min(W - 1, x * sc + dx)) * 4)
                    local a = bit32.rshift(v, 24)
                    sb, sg, sr, sa = sb + bit32.band(v, 255) * a, sg + bit32.band(bit32.rshift(v, 8), 255) * a, sr + bit32.band(bit32.rshift(v, 16), 255) * a, sa + a
                end
            end
            local o = (y * w2 + x) * 4
            buffer.writef32(ch[1], o, sb / (255 * nn)) buffer.writef32(ch[2], o, sg / (255 * nn)) buffer.writef32(ch[3], o, sr / (255 * nn)) buffer.writef32(ch[4], o, sa / nn)
        end
        if Y() and not alive() then return nil end
    end
    base = {}
    for c = 1, 4 do base[c] = buffer.create(n * 4) buffer.copy(base[c], 0, ch[c], 0, n * 4) end
    fit.small[sc] = base
    end
    local scaledRadius = radius / (3 * sc) -- reduced resolution, 3 passes; never round a small blur up to a full texel
    local r = math.floor(scaledRadius)
    local edge = scaledRadius - r
    local tmp = buffer.create(n * 4)
    local inv = 1 / (2 * r + 1 + 2 * edge)
    local function pass(buf, len, count, step, stride)
        for line = 0, count - 1 do
            local base = line * stride
            local sum = 0
            for k = -r, r do sum = sum + buffer.readf32(buf, (base + math.clamp(k, 0, len - 1) * step) * 4) end
            local left = buffer.readf32(buf, base * 4)
            for i = 0, len - 1 do
                local right = buffer.readf32(buf, (base + math.min(i + r + 1, len - 1) * step) * 4)
                buffer.writef32(tmp, (base + i * step) * 4, (sum + edge * (left + right)) * inv)
                local leaving = buffer.readf32(buf, (base + math.max(i - r, 0) * step) * 4)
                sum, left = sum + right - leaving, leaving
            end
            if Y() and not alive() then return false end
        end
        buffer.copy(buf, 0, tmp, 0, n * 4)
        return true
    end
    for c = 1, 4 do
        for _ = 1, 3 do
            if not pass(ch[c], w2, h2, 1, w2) or not pass(ch[c], h2, w2, w2, 1) then return nil end
        end
        Y()
        if not alive() then return nil end
    end
    if radius >= 4 then -- small picture as is: blurred, it has no detail the stretch could lose (1/4 the upload)
        local q = buffer.create(18 + n * 4)
        buffer.writeu8(q, 2, 2) buffer.writeu16(q, 12, w2) buffer.writeu16(q, 14, h2)
        buffer.writeu8(q, 16, 32) buffer.writeu8(q, 17, 0x28)
        for i = 0, n - 1 do
            local a = buffer.readf32(ch[4], i * 4)
            local k = a > 0.5 and 255 / a or 0
            local o = 18 + i * 4
            buffer.writeu8(q, o, math.clamp(math.floor(buffer.readf32(ch[1], i * 4) * k + 0.5), 0, 255))
            buffer.writeu8(q, o + 1, math.clamp(math.floor(buffer.readf32(ch[2], i * 4) * k + 0.5), 0, 255))
            buffer.writeu8(q, o + 2, math.clamp(math.floor(buffer.readf32(ch[3], i * 4) * k + 0.5), 0, 255))
            buffer.writeu8(q, o + 3, math.clamp(math.floor(a + 0.5), 0, 255))
            if i % 1024 == 1023 and Y() and not alive() then return nil end -- final write-out on the frame budget too
        end
        return buffer.tostring(q)
    end
    local b = buffer.create(18 + W * H * 4)
    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, W) buffer.writeu16(b, 14, H)
    buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28)
    local c1, c2, c3, c4 = ch[1], ch[2], ch[3], ch[4]
    for y = 0, H - 1 do
        local sy = math.clamp((y + 0.5) / sc - 0.5, 0, h2 - 1)
        local y0 = math.floor(sy) local y1, fy = math.min(y0 + 1, h2 - 1), sy - y0
        for x = 0, W - 1 do
            local sx = math.clamp((x + 0.5) / sc - 0.5, 0, w2 - 1)
            local x0 = math.floor(sx) local x1, fx = math.min(x0 + 1, w2 - 1), sx - x0
            local i00, i10, i01, i11 = (y0 * w2 + x0) * 4, (y0 * w2 + x1) * 4, (y1 * w2 + x0) * 4, (y1 * w2 + x1) * 4
            local w00, w10, w01, w11 = (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy
            local function at(c) return buffer.readf32(c, i00) * w00 + buffer.readf32(c, i10) * w10 + buffer.readf32(c, i01) * w01 + buffer.readf32(c, i11) * w11 end
            local a = at(c4)
            local k = a > 0.5 and 1 / a * 255 or 0
            local o = 18 + (y * W + x) * 4
            buffer.writeu8(b, o, math.clamp(math.floor(at(c1) * k + 0.5), 0, 255))
            buffer.writeu8(b, o + 1, math.clamp(math.floor(at(c2) * k + 0.5), 0, 255))
            buffer.writeu8(b, o + 2, math.clamp(math.floor(at(c3) * k + 0.5), 0, 255))
            buffer.writeu8(b, o + 3, math.clamp(math.floor(a + 0.5), 0, 255))
        end
        if S.budget() and not alive() then return nil end
    end
    return buffer.tostring(b)
end
function S.cropTGA(c, r0, r1)
    local n, w = r1 - r0, c.w
    local b = buffer.create(18 + w * n * 4)
    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, w) buffer.writeu16(b, 14, n)
    buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28) -- 8 alpha bits, top-left origin
    buffer.copy(b, 18, c.px, r0 * w * 4, w * n * 4)
    return buffer.tostring(b)
end
S.ICON_URL = "https://raw.githubusercontent.com/latte-soft/lucide-roblox/master/icons/compiled/48px/"
-- base64 -> bytes (embedded Icon pictures). Executor crypt when present, else plain Luau.
S.B64 = {}
for i = 1, 64 do S.B64[string.byte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", i)] = i - 1 end
function S.b64decode(s)
    local fn = (crypt and (crypt.base64decode or crypt.base64_decode)) or base64_decode
    if type(fn) == "function" then
        local ok, r = pcall(fn, s)
        if ok and type(r) == "string" and #r > 0 then return r end
    end
    local B64 = S.B64
    s = s:gsub("[^%w%+/]", "")
    local out, n = buffer.create(math.floor(#s * 3 / 4)), 0
    for i = 1, #s - 3, 4 do
        local a, b, c, d = B64[s:byte(i)], B64[s:byte(i + 1)], B64[s:byte(i + 2)], B64[s:byte(i + 3)]
        local v = a * 262144 + b * 4096 + c * 64 + d
        buffer.writeu8(out, n, bit32.rshift(v, 16)) buffer.writeu8(out, n + 1, bit32.band(bit32.rshift(v, 8), 255)) buffer.writeu8(out, n + 2, bit32.band(v, 255))
        n = n + 3
    end
    local rem = #s % 4 -- unpadded tail: 2 chars = 1 byte, 3 chars = 2 bytes
    if rem >= 2 then
        local i = #s - rem + 1
        local a, b, c = B64[s:byte(i)], B64[s:byte(i + 1)], rem == 3 and B64[s:byte(i + 2)] or 0
        local v = a * 262144 + b * 4096 + c * 64
        buffer.writeu8(out, n, bit32.rshift(v, 16)) n = n + 1
        if rem == 3 then buffer.writeu8(out, n, bit32.band(bit32.rshift(v, 8), 255)) n = n + 1 end
    end
    return buffer.readstring(out, 0, n)
end
assert(S.b64decode("TWFu") == "Man" and S.b64decode("TWE=") == "Ma" and S.b64decode("TQ==") == "M", "b64decode self-check")
-- newer Lucide names the 48 px icon set (older Lucide) doesn't have
S.ICON_ALIAS = { house = "home" }
function S.loadIcon(name, applyFn, again, px) -- px = on-screen size in logical px (default 16)
    name = S.ICON_ALIAS[name] or name
    if not again then S.onRescale(function() S.loadIcon(name, applyFn, true, px) end) end
    task.spawn(function()
        local path = S.CACHE .. "/icons48/" .. name .. ".txt"
        local data = nil
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 100 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return S.httpGet(S.ICON_URL .. name .. ".png") end)
            if ok and d and #d > 100 then
                data = d
                S.ensureDir(S.CACHE .. "/icons48")
                pcall(writefile, path, d)
            end
        end
        if data and S.FX.ok and not S.Env.matcha then
            -- resampled to the 16 px icon's exact screen size (see S.iconSharp); the raw 48 px PNG stays the fallback
            S.budget() -- ~40 icons resample right after load: share the frame budget instead of all in one frame
            local okS, sharp = pcall(S.iconSharp, data, math.max(8, math.floor((px or 16) * (S.K or 1) + 0.5)))
            if okS and sharp then
                data = sharp
            elseif not okS then
                S.perfError("icon", sharp)
                if not S.iconErr then
                    S.iconErr = true
                    print("LEGOSENSE|icon: " .. tostring(sharp))
                end
            end
        end
        if data and applyFn then pcall(applyFn, data) end
    end)
end

function S.loadAvatar(applyFn, again)
    if not again then S.onRescale(function() S.loadAvatar(applyFn, true) end) end
    task.spawn(function()
        -- Cache by user ID so each account loads its own avatar.
        local okId, uid = pcall(function() return game:GetService("Players").LocalPlayer.UserId end)
        if not okId or not uid then return end
        local path = S.CACHE .. "/avatar150_" .. tostring(uid) .. ".txt"
        if isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 100 then pcall(applyFn, d) return end
        end
        local okJ, j = pcall(function()
            return S.httpGet("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. tostring(uid) .. "&size=150x150&format=Png&isCircular=false")
        end)
        if not okJ or not j then return end
        local url = tostring(j):match('"imageUrl"%s*:%s*"([^"]+)"')
        if not url then return end
        local okP, png = pcall(function() return S.httpGet(url) end)
        if okP and png and #png > 100 then
            pcall(writefile, path, png)
            pcall(applyFn, png)
        end
    end)
end

-- theme background images, one per themed preset.
-- cached in memory per preset so switching back never refetches; applied in relayout to decode.
S.THEME_IMG = {
    Matcha = "https://raw.githubusercontent.com/nvqren/Matcha-Waifu/refs/heads/main/waifu.png",
}
UI.themeImg = {}
UI.themeImgRatio = {}   -- image identity -> width/height
UI.themeImgPending = {}
function S.normalizeThemeImageUrl(text)
    if type(text) ~= "string" then return nil end
    local url = text:match("^%s*(.-)%s*$")
    if url == "" then return "" end
    if url:find("[%s%c]") or url:find("\\", 1, true) then return nil end
    local scheme, authority, rest = url:match("^([%a]+)://([^/%?#]+)(.*)$")
    if not scheme or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then return nil end
    if authority:sub(1, 1) == ":" or authority:sub(-1) == ":" then return nil end
    return scheme:lower() .. "://" .. authority .. rest
end
function S.themeImageKey(preset)
    local custom = S.normalizeThemeImageUrl(S.Cfg.themeImgUrl)
    return custom and custom ~= "" and ("url:" .. custom) or preset
end
-- Validate image signatures before caching bytes, including small icons. The Drawing renderer decodes
-- the original image; headers supply its aspect ratio without assuming the image is a PNG.
local function imgRatio(d)
    if type(d) ~= "string" or #d < 10 then return nil end
    local b = string.byte
    local function le16(i) return b(d, i) + b(d, i + 1) * 256 end
    local function le24(i) return le16(i) + b(d, i + 2) * 65536 end
    local function le32(i) return le24(i) + b(d, i + 3) * 16777216 end
    local function be16(i) return b(d, i) * 256 + b(d, i + 1) end
    local function be32(i) return be16(i) * 65536 + be16(i + 2) end
    local w, h
    if #d >= 45 and d:sub(1, 8) == "\137PNG\r\n\26\n" and d:sub(13, 16) == "IHDR"
        and be32(9) == 13 and d:find("IEND", 33, true) then
        w, h = be32(17), be32(21)
    elseif #d >= 14 and (d:sub(1, 6) == "GIF87a" or d:sub(1, 6) == "GIF89a") and b(d, #d) == 59 then
        w, h = le16(7), le16(9)
    elseif #d >= 4 and d:sub(1, 2) == "\255\216" and d:find("\255\217", 3, true) then
        local i = 3
        while i + 3 <= #d do
            if b(d, i) ~= 255 then return nil end
            repeat i = i + 1 until i > #d or b(d, i) ~= 255
            local marker = b(d, i)
            i = i + 1
            if not marker or marker == 0xDA or marker == 0xD9 then break end
            if marker ~= 0x01 and not (marker >= 0xD0 and marker <= 0xD8) then
                if i + 1 > #d then return nil end
                local length = be16(i)
                if length < 2 or i + length - 1 > #d then return nil end
                if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    if length < 8 then return nil end
                    h, w = be16(i + 3), be16(i + 5)
                    break
                end
                i = i + length
            end
        end
    elseif #d >= 26 and d:sub(1, 2) == "BM" then
        local header, pixels = le32(15), le32(11)
        if header > #d - 14 or pixels >= #d then return nil end
        if header == 12 then w, h = le16(19), le16(21)
        elseif header >= 40 then
            w, h = le32(19), le32(23)
            if w >= 2147483648 then w = w - 4294967296 end
            if h >= 2147483648 then h = 4294967296 - h end -- top-down bitmap
        end
    elseif #d >= 20 and d:sub(1, 4) == "RIFF" and d:sub(9, 12) == "WEBP" then
        local finish, i = le32(5) + 8, 13
        if finish > #d then return nil end
        while i + 7 <= finish do
            local kind, length = d:sub(i, i + 3), le32(i + 4)
            local start = i + 8
            if start + length - 1 > finish then return nil end
            if kind == "VP8X" and length >= 10 then
                w, h = le24(start + 4) + 1, le24(start + 7) + 1
                break
            elseif kind == "VP8 " and length >= 10 and d:sub(start + 3, start + 5) == "\157\1\42" then
                w, h = le16(start + 6) % 16384, le16(start + 8) % 16384
                break
            elseif kind == "VP8L" and length >= 5 and b(d, start) == 0x2F then
                local bits = le32(start + 1)
                w, h = bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
                break
            end
            i = start + length + length % 2
        end
    end
    if w and h and w > 0 and h > 0 then return w / h end
    return nil
end
function S.loadThemeImage(preset)
    if S.unloaded or UI.unloaded then return end
    local custom = S.normalizeThemeImageUrl(S.Cfg.themeImgUrl)
    local hasCustom = custom and custom ~= ""
    local url = hasCustom and custom or S.THEME_IMG[preset]
    if not url then return end
    local key = S.themeImageKey(preset)
    if UI.themeImg[key] then S.Win.dirty = true return end
    if UI.themeImgPending[key] then return end
    local request = {}
    UI.themeImgPending[key] = request
    task.spawn(function()
        S.perfBootMark("themeImageLoadStart")
        local ok, data, ratio = pcall(function()
            local path = not hasCustom and (S.CACHE .. "/themeimg_" .. preset .. ".txt") or nil
            if path and isfile(path) then
                local readOk, cached = pcall(readfile, path)
                local cachedRatio = readOk and imgRatio(cached)
                if cachedRatio then return cached, cachedRatio end
            end
            local fetched = S.httpGet(url)
            local fetchedRatio = imgRatio(fetched)
            if not fetchedRatio or S.unloaded or UI.unloaded then return nil end
            if path then
                pcall(S.ensureDir, S.CACHE)
                pcall(writefile, path, fetched)
            end
            return fetched, fetchedRatio
        end)
        if S.unloaded or UI.unloaded or UI.themeImgPending[key] ~= request then return end
        UI.themeImgPending[key] = nil
        if ok and data then
            if hasCustom then
                if S.themeImageKey(S.Cfg.preset) ~= key then return end
                local previous = UI.themeImgCustomKey
                if previous and previous ~= key then
                    UI.themeImg[previous], UI.themeImgRatio[previous] = nil, nil
                end
                UI.themeImgCustomKey = key
            end
            UI.themeImg[key], UI.themeImgRatio[key] = data, ratio
            if S.themeImageKey(S.Cfg.preset) == key then
                UI.themeImgApplied = nil
                S.Win.dirty = true
            end
        elseif S.themeImageKey(S.Cfg.preset) == key and UI.created and S.toast then
            S.toast("Theme image", "Could not load that image. Use a direct image link.", 4)
        end
        S.perfBootMark("themeImageLoadEnd")
    end)
end

S.loadYield()
-- ========== shell ==========
S.perfMark("drawingBuildStart")
S.D = {}
S.D.winGlow = S.FX.newGlow(28) -- its image is replaced by the window-shaped halo (S.updateWinGlow)
S.D.main    = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = S.Const.ALPHA_BG, ZIndex = 29, Corner = 8, Visible = true })
S.D.themeImg   = S.New("Image",  { Transparency = 1, ZIndex = 30, Visible = false, Size = Vector2.new(300, 300) })
S.D.nyan    = S.New("Image",  { Transparency = 1, ZIndex = 30, Visible = false })
S.D.topbar  = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 31, Corner = 8, Visible = true })
S.D.sidebar = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 32, Corner = 8, Visible = true })
S.D.seam    = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 33, Corner = 0, Visible = true })
-- default logo: "ls" (drawn twice 1px apart for weight) with an accent underline (S.D.logo)
S.D.logo    = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 34, Corner = 2, Visible = true, Size = Vector2.new(18, 4) })
S.D.logoTxt = S.New("Text",   { Text = "ls", Color = S.Theme.Text, Transparency = 1, ZIndex = 35, Font = 0, Size = 24, Visible = true })
S.D.logoTxt2= S.New("Text",   { Text = "ls", Color = S.Theme.Text, Transparency = 1, ZIndex = 35, Font = 0, Size = 24, Visible = true })
S.D.logoImg = S.New("Image",  { Transparency = 1, ZIndex = 36, Visible = false, Size = Vector2.new(32, 32), Rounding = 0 })
-- logo glyph (replaces the "ls" mark): the intro's comet ring in miniature: faint ring, an accent arc orbiting
-- it (brightest at the head), a small white centre dot with a tiny glow. Animated in S.updateGlyph.
S.Glyph = { ang = 0, arc = {},
    glow = S.FX.newGlow(34),
    ring = S.New("Circle", { Filled = false, Radius = 12, NumSides = 48, Thickness = 1.5, Color = S.Theme.C1, Transparency = 0, ZIndex = 35, Visible = false }),
    dot = S.New("Circle", { Filled = true, Radius = 2.2, NumSides = 20, Color = S.Theme.White, Transparency = 0, ZIndex = 37, Visible = false }) }
for i = 1, 14 do S.Glyph.arc[i] = S.New("Line", { Thickness = 2, Color = S.Theme.C1, Transparency = 0, ZIndex = 36, Visible = false }) end
S.D.brand   = S.New("Text",   { Text = "", Color = S.Theme.C1, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true })
S.D.brandSub= S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = true })
S.D.title   = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true })
S.D.searchGlow = S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0, ZIndex = 32, Corner = 8, Visible = false })
S.D.search  = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = S.Const.ALPHA_BG, ZIndex = 32, Corner = 8, Visible = true })
S.D.searchT = S.New("Text",   { Text = "Search", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = true })
S.D.searchIco = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(12, 12), Color = S.Theme.Dim })
S.D.pencil = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(14, 14), Color = S.Theme.Dim })
S.D.layReset = S.New("Text", { Text = "Reset", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false })
S.D.close   = S.New("Text",   { Text = "x", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = 15, Visible = true })
-- resize grip: a short arc hugging the window's bottom-right corner; dim until hovered / dragged (S.updateGrip)
S.Const.GRIP_SEGS = 7
S.gripT = 0
S.D.gripArc = {}
for i = 1, S.Const.GRIP_SEGS do
    S.D.gripArc[i] = S.New("Line", { Color = S.Theme.Dim, Transparency = 0.35, ZIndex = 33, Visible = false, Thickness = 2 })
end
-- off Matcha the grip is a true quarter ring drawn by S.roundRect (outline, bottom-right corner only)
S.Const.GRIP_R = 11
S.D.gripRing = { S.New("Square", { Filled = false, Thickness = 2, Color = S.Theme.Dim, Transparency = 0.35, ZIndex = 33, Corner = S.Const.GRIP_R, Visible = false }) }
if S.Env.drawing and not S.Env.matcha then
    S.D.gripRing[1].CornerMask = { br = true }
    S.D.gripRing[1].ArcOnly = true
end
S.D.hiliteGlow = S.FX.newGlow(33)
-- active tab wash: accent fading out to the right (alpha ramp image, tinted, natively rounded)
do
    local ramp = S.FX.get("tabRamp", 256, 2, function(x) return (1 - x / 256) ^ 1.6 end)
    if ramp then S.D.hiliteGrad = S.New("Image", { Data = ramp, Color = S.Theme.C1, Transparency = 0.5, ZIndex = 33, Visible = true, Size = Vector2.new(1, 1) }) end
end
S.D.overGlow = S.FX.newGlow(30) -- between the window bg (29) and the cards (31): the bulge shows in the gaps, never over cards or text
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
-- sidebar pin (top right of the open sidebar): a tilted pushpin, filled accent when pinned (Sidebar = Expanded)
-- pin = "sidebar panel" icon: outlined frame (pinHead), column divider (pinLine), left column fill when pinned (pinFill)
S.D.pinLine = S.New("Line",   { Thickness = 1.5, Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Visible = false })
S.D.pinHead = S.New("Square", { Filled = false, Thickness = 1.5, Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Corner = 3, Visible = false })
S.D.pinFill = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 33, Corner = 2, Visible = false })
-- Render the anti-aliased distance field at the icon's exact screen size (14 x 12 * UI scale).
-- The renderer downsamples without filtering, which can drop pixels from thin frame lines.
-- The frame and divider share one image. The left column fill uses a separate image for accent tinting.
do
    local SC = S.K or 1
    local W, H = math.floor(14 * SC + 0.5), math.floor(12 * SC + 0.5)
    local st = 1.5 * SC / 2 -- half stroke
    local function frameSD(x, y) return S.FX.rrSD(x + 0.5, y + 0.5, W / 2, H / 2, W / 2 - st, H / 2 - st, 3.5 * SC - st) end
    local divX = 5 * SC
    local frame = S.FX.ok and S.FX.get("pinFrame" .. W, W, H, function(x, y)
        local sd = frameSD(x, y)
        local a = math.clamp(st + 0.5 - math.abs(sd), 0, 1)
        if sd < 0 then a = math.max(a, math.clamp(st + 0.5 - math.abs(x + 0.5 - divX), 0, 1)) end
        return a
    end)
    local fill = S.FX.ok and S.FX.get("pinCol" .. W, W, H, function(x, y)
        local inside = math.clamp(-(frameSD(x, y) + st) + 0.5, 0, 1)
        return inside * math.clamp(divX - st - (x + 0.5) + 0.5, 0, 1) * 0.9
    end)
    if frame and fill then
        S.D.pinImg = S.New("Image", { Data = frame, Color = S.Theme.Dim, Transparency = 0, ZIndex = 34, Visible = false, Size = Vector2.new(14, 12) })
        S.D.pinImgFill = S.New("Image", { Data = fill, Color = S.Theme.C1, Transparency = 0, ZIndex = 33, Visible = false, Size = Vector2.new(14, 12) })
    end
end
S.D.gearGlow = S.FX.newGlow(32) -- accent glow under the gear while Settings is open (same look as the toggle knob glow)
S.D.gear    = S.New("Image",  { Transparency = 1, ZIndex = 33, Visible = false, Size = Vector2.new(18, 18), Color = S.Theme.Dim })
S.D.verTag  = S.New("Text",   { Text = "v1.3", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 2, Visible = false })
S.D.pageTxt = S.New("Text",   { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = true })
-- ========== shared Drawing scrollbars ==========
-- Pages, capped/resized sections and dropdowns use this one renderer and input model.
-- Each region owns only its offset/range; theme, clipping, glow, speed and drag math live here.
S.Scroll = { bars = {} }
do
    S.Scroll.glowData = S.FX.ok and not S.Env.matcha and S.FX.get("sbGlowV", 2, 128, function(_, y)
        local a = 1 - math.abs((y + 0.5) / 128 - 0.5) * 2
        a = a * (2 - a)
        return 0.35 + 0.6 * a
    end)
end
function S.Scroll.new(z)
    local bar = { z = z, glow = {}, glowT = 0, pulse = 0 }
    bar.track = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 0.8, ZIndex = z, Corner = 2, Visible = false })
    bar.thumb = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = z + 1, Corner = 2, Visible = false })
    S.Scroll.bars[#S.Scroll.bars + 1] = bar
    return bar
end
function S.Scroll.hideGlow(bar)
    if bar.glowHidden then return end
    bar.glowHidden = true
    if bar.image then bar.image.Visible = false end
    for _, o in ipairs(bar.glow) do o.Visible = false end
end
function S.Scroll.hide(bar)
    bar.geo, bar.pulse, bar.glowT = nil, 0, 0
    bar.track.Visible, bar.thumb.Visible = false, false
    S.Scroll.hideGlow(bar)
end
function S.Scroll.paint(bar)
    local g = bar.geo
    if not g or not S.Win.visible then
        bar.track.Visible, bar.thumb.Visible = false, false
        S.Scroll.hideGlow(bar)
        return
    end
    local alpha = (bar.alpha or 1) * S.Cfg.opacity
    if not S.glowsOn() or S.Cfg.scrollGlow == false or S.Cfg.perfMode then bar.glowT = 0 end
    if S.drawClip then
        S.drawClip(bar.track, g.y, g.y + g.h)
        S.drawClip(bar.thumb, g.y, g.y + g.h)
    end
    -- Both logical edges must land on the same physical pixels for every scrollbar.
    -- At 115% scale an unsnapped 2px region otherwise alternated between 2 and 3 screen pixels.
    local scale = S.K or 1
    local drawX = math.floor(g.drawX * scale + 0.5) / scale
    local width = math.max(1, math.floor(2 * scale + 0.5)) / scale
    bar.track.Position, bar.track.Size = Vector2.new(drawX, g.y), Vector2.new(width, g.h)
    bar.track.Color, bar.track.Transparency = S.Theme.Panel, 0.8 * alpha
    bar.track.Visible = alpha > 0 and g.h > 0
    local top, bot = math.max(g.ty, g.y), math.min(g.ty + g.thumbH, g.y + g.h)
    bar.thumb.Visible = alpha > 0 and bot > top
    if not bar.thumb.Visible then S.Scroll.hideGlow(bar) return end
    bar.thumb.Position, bar.thumb.Size = Vector2.new(drawX, top), Vector2.new(width, bot - top)
    bar.thumb.Transparency = alpha
    bar.thumb.Color = S.lerpColor(S.Theme.Track, S.lerpColor(S.Theme.Track, S.Theme.C1, 0.5), bar.glowT)
    -- Pool the glow once, only for regions that actually overflow. No per-frame allocations.
    if bar.glowT > 0.02 and not bar.glowReady then
        bar.glowReady = true
        if S.Scroll.glowData then
            bar.image = S.New("Image", { Data = S.Scroll.glowData, Color = S.Theme.C1, Transparency = 0, ZIndex = bar.z + 2, Visible = false, Size = Vector2.new(1, 1) })
        else
            for i = 1, 400 do bar.glow[i] = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = bar.z + 2, Corner = 0, Visible = false }) end
        end
    end
    local glowT = bar.glowT * (bar.alpha or 1)
    if glowT > 0.02 then
        bar.glowHidden = false
        S.thumbGlow(bar.glow, bar.thumb.Position, bar.thumb.Size, glowT, bar.image)
    else
        S.Scroll.hideGlow(bar)
    end
end
function S.Scroll.layout(bar, x, y, height, view, content, offset, maximum, visible, clipTop, clipBot, alpha)
    maximum = math.max(0, maximum or (content - view))
    local top, bot = math.max(y, clipTop or y), math.min(y + height, clipBot or (y + height))
    if not visible or maximum <= 0 or height <= 0 or view <= 0 or content <= 0 or bot <= top then
        S.Scroll.hide(bar)
        return nil
    end
    local thumbH = math.min(height, math.max(24, math.floor(height * view / content)))
    local ty = math.floor(y + math.clamp(offset / maximum, 0, 1) * (height - thumbH) + 0.5)
    bar.alpha = alpha or 1
    bar.geo = { x = x - 4, y = top, w = 10, h = bot - top, drawX = x,
        top = y, track = height, thumbH = thumbH, ty = ty, maxScroll = maximum }
    S.Scroll.paint(bar)
    return bar.geo
end
function S.Scroll.grab(bar, mouseY)
    local g = bar.geo
    if not g then return 0 end
    local off = mouseY - g.ty
    return (off >= 0 and off <= g.thumbH) and off or g.thumbH / 2
end
function S.Scroll.drag(bar, mouseY, off, discrete)
    local g = bar.geo
    if not g then return nil end
    local ratio = (mouseY - g.top - (off or g.thumbH / 2)) / math.max(1, g.track - g.thumbH)
    local value = math.clamp(ratio, 0, 1) * g.maxScroll
    return discrete and math.floor(value + 0.5) or value
end
function S.Scroll.move(bar, value, delta, maximum, discrete)
    local change = delta * (S.Cfg.scrollSpeed or 100) / 100
    if discrete and change ~= 0 then change = (change < 0 and -1 or 1) * math.max(1, math.floor(math.abs(change) + 0.5)) end
    local raw = value + change
    local nextValue = math.clamp(raw, 0, math.max(0, maximum))
    if nextValue ~= value then bar.pulse = 0.45 S.Win.dirty = true end
    return nextValue, raw
end
function S.Scroll.step(state, targetKey, currentKey, velocityKey, maximum, dt, direct)
    state[targetKey] = math.clamp(state[targetKey] or 0, 0, maximum)
    local current = math.clamp(state[currentKey] or 0, 0, maximum)
    local diff = state[targetKey] - current
    local velocity = state[velocityKey] or 0
    if direct or not S.animOn() or S.Cfg.smoothScroll == false then
        current, velocity = state[targetKey], 0
    elseif math.abs(diff) > 0.05 or math.abs(velocity) > 1 then
        velocity = (velocity + diff * 260 * dt) * math.exp(-2 * math.sqrt(260) * dt)
        current = math.clamp(current + velocity * dt, 0, maximum)
        if math.abs(state[targetKey] - current) < 0.05 and math.abs(velocity) < 1 then current, velocity = state[targetKey], 0 end
    else
        current, velocity = state[targetKey], 0
    end
    if current ~= state[currentKey] then S.Win.dirty = true end
    state[currentKey], state[velocityKey] = current, velocity
end
function S.Scroll.update(bar, dt, dragging)
    bar.pulse = math.max(0, bar.pulse - dt)
    local enabled = not S.Cfg.perfMode and S.glowsOn() and S.Cfg.scrollGlow ~= false
    if not enabled then bar.glowT = 0 S.Scroll.hideGlow(bar) end
    local hot = bar.geo and enabled and (dragging or bar.pulse > 0)
    local ease = S.animOn() and (1 - (0.00001 ^ dt)) or 1
    bar.glowT = bar.glowT + ((hot and 1 or 0) - bar.glowT) * ease
    S.Scroll.paint(bar)
end
S.PageBar = S.Scroll.new(36)
S.D.sbTrack, S.D.sbThumb = S.PageBar.track, S.PageBar.thumb
function S.hideSbGlow() S.Scroll.hideGlow(S.PageBar) end
-- ========== end shared Drawing scrollbars ==========
-- tooltip = small glass panel like the overlays: window bg + DoF blur behind + faint accent rim; fades + rises in.
-- Kept out of S.D (S.setVisible shows every S.D drawing, which flashed the old flat tip box on menu open).
S.Tip = { lines = {}, t = 0, shown = false }
S.Tip.bg = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = 0, ZIndex = 110, Corner = 6, Visible = false })
S.Tip.ol = S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0, ZIndex = 111, Corner = 6, Thickness = 1, Visible = false })
for i = 1, 6 do S.Tip.lines[i] = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 0, ZIndex = 112, Font = 0, Size = S.FS - 1, Visible = false }) end
-- seam wedges: 1px slivers that fill the rounded-corner gaps where sidebar meets topbar.
-- they only cover pixels the bars leave empty, so nothing overlaps and nothing darkens.
-- off Matcha the corners are drawn by S.roundRect, which can square individual corners: the bars meet flush
if S.Env.drawing and not S.Env.matcha then
    S.D.topbar.CornerMask = { tr = true, br = true }           -- left side touches the sidebar
    S.D.sidebar.CornerMask = { tl = true, bl = true, br = true } -- top-right touches the topbar
end
-- inward rounded corner where the sidebar and topbar meet the content (a group so menu show/hide leaves
-- it to the layout). Off Matcha it's a Fillet square; on Matcha the same shape is drawn with wedge slivers.
S.D.fillet = { S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 31, Corner = 8, Visible = false }) }
if S.Env.drawing and not S.Env.matcha then S.D.fillet[1].Fillet = true end
S.Const.WEDGE_MAX = 20
S.D.wedges = {}
for i = 1, S.Const.WEDGE_MAX * 4 do
    S.D.wedges[i] = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = S.Const.ALPHA_BAR, ZIndex = 31, Corner = 0, Visible = false })
end

S.DGroups = { S.D.sbDiv1, S.D.sbDiv2, S.D.wedges, S.D.gripArc, S.D.fillet, S.D.gripRing }
function S.isDGroup(o)
    for _, g in ipairs(S.DGroups) do if g == o then return true end end
    return false
end

S.Items = {}
for i, tab in ipairs(S.Tabs) do
    S.Items[i] = {
        icon  = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = true, Size = Vector2.new(16, 16), Color = S.Theme.Dim }),
        label = S.New("Text",  { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = true }),
    }
    S.loadIcon(tab.icon, function(data) S.Items[i].icon.Data = data end)
end
S.SB_LIFT = 20
function S.liftZ(o)
    if type(o) == "table" and not o.ZIndex then for _, v in ipairs(o) do S.liftZ(v) end return end
    if o then pcall(function() o.ZIndex = (o.ZIndex or 33) + S.SB_LIFT end) end
end
function S.liftItem(it) S.liftZ(it.icon) S.liftZ(it.label) end
do
    for _, k in ipairs({ "sidebar", "logo", "logoTxt", "logoTxt2", "logoImg", "brand", "brandSub", "hiliteGrad", "hiliteGlow", "hilite",
        "hiliteBar", "hiliteEdge", "navHover", "sbDiv1", "sbDiv2", "avCirc", "avatar", "footName", "footSub", "pinLine", "pinHead",
        "pinFill", "pinImg", "pinImgFill", "gearGlow", "gear", "verTag" }) do if S.D[k] then S.liftZ(S.D[k]) end end
    local G = S.Glyph
    S.liftZ(G.glow) S.liftZ(G.ring) S.liftZ(G.dot) S.liftZ(G.arc)
    for _, it in ipairs(S.Items) do S.liftItem(it) end
end
S.okName, S.plrName = pcall(function() return game:GetService("Players").LocalPlayer.Name end)
S.playerName = S.okName and tostring(S.plrName) or "player"
S.okDisp, S.plrDisp = pcall(function() return game:GetService("Players").LocalPlayer.DisplayName end)
S.displayName = (S.okDisp and S.plrDisp and #tostring(S.plrDisp) > 0) and tostring(S.plrDisp) or S.playerName

-- window options (CreateWindow overrides; nil keeps the default)
S.BRAND = "LegoSense"
S.SUBTITLE = nil            -- nil -> use the fetched game name
S.VERSION = "v1.0"
S.WinIcon = nil             -- nil/false -> drawn "ls" mark; "game" -> this game's icon; string url or numeric asset id
S.LOGO_URL = "https://api.alo.ne/file/ngowge"

S.GameName = "..."
S.assetsStarted = false
function S.startAssets()
    if S.assetsStarted then return end
    S.assetsStarted = true
    S.loadIcon("settings", function(data) S.D.gear.Data = data end)
    S.loadIcon("search", function(data) S.D.searchIco.Data = data end)
    S.loadIcon("pencil", function(data) S.D.pencil.Data = data end)
    S.loadAvatar(function(data)
        S.perfBootMark("avatarTgaStart")
        local f = S.imgFit(data, S.devPx(36), S.devPx(36))
        S.D.avatar.Data = f and f.data or data
        S.perfBootMark("avatarTgaEnd")
    end)

    task.spawn(function()
        local ok, info = pcall(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId) end)
        if ok and info and info.Name then S.GameName = tostring(info.Name) S.Win.dirty = true return end
        local okU, uj = pcall(function()
            return S.httpGet("https://apis.roblox.com/universes/v1/places/" .. tostring(game.PlaceId) .. "/universe")
        end)
        local uid = okU and tostring(uj):match('"universeId"%s*:%s*(%d+)') or nil
        if uid then
            local okG, gj = pcall(function() return S.httpGet("https://games.roblox.com/v1/games?universeIds=" .. uid) end)
            local nm = okG and tostring(gj):match('"name"%s*:%s*"([^"]-)"') or nil
            if nm then S.GameName = nm S.Win.dirty = true end
        end
    end)

    task.spawn(function()
        if not S.WinIcon then return end -- default: the drawn "ls" mark, nothing to fetch
        local path = S.CACHE .. "/logo2.txt"
        -- resolve the logo source: "game" -> this game's icon, numeric asset id -> thumbnail url, string -> direct url
        local url = S.LOGO_URL
        local usingCustom = false
        if S.WinIcon == "game" then
            -- any failed lookup keeps the drawn "ls" mark
            local okU, uj = pcall(function() return S.httpGet("https://apis.roblox.com/universes/v1/places/" .. tostring(game.PlaceId) .. "/universe") end)
            local uid = okU and tostring(uj):match('"universeId"%s*:%s*(%d+)')
            local okT, tj = false, nil
            if uid then okT, tj = pcall(function() return S.httpGet("https://thumbnails.roblox.com/v1/games/icons?universeIds=" .. uid .. "&returnPolicy=PlaceHolder&size=150x150&format=Png&isCircular=false") end) end
            local gurl = okT and tostring(tj):match('"imageUrl"%s*:%s*"([^"]+)"')
            if not gurl then return end
            url = gurl usingCustom = true
        elseif type(S.WinIcon) == "string" and S.WinIcon:sub(1, 5) == "data:" then
            -- embedded picture (Icon = "data:image/png;base64,..."): nothing to host or fetch
            usingCustom = true
            local okB, png = pcall(S.b64decode, S.WinIcon:match(",(.*)$") or "")
            if okB and png and #png > 8 then
                S.logoData = png
            else
                S.perfError("logo", "Bad Icon data")
                print("LEGOSENSE|logo: bad data: Icon")
                return
            end
        elseif type(S.WinIcon) == "string" and #S.WinIcon > 0 then url = S.WinIcon usingCustom = true
        elseif type(S.WinIcon) == "number" then
            usingCustom = true
            local okT, tj = pcall(function() return S.httpGet("https://thumbnails.roblox.com/v1/assets?assetIds=" .. tostring(S.WinIcon) .. "&size=150x150&format=Png&isCircular=false") end)
            url = (okT and tostring(tj):match('"imageUrl"%s*:%s*"([^"]+)"')) or S.LOGO_URL
        end
        local data = S.logoData
        if not data and not usingCustom and isfile(path) then
            local ok, d = pcall(readfile, path)
            if ok and d and #d > 200 then data = d end
        end
        if not data then
            local ok, d = pcall(function() return S.httpGet(url) end)
            if ok and d and #d > 200 then
                data = d
                S.ensureDir(S.CACHE)
                if not usingCustom then pcall(writefile, path, d) end
            else
                S.perfError("logo", "Logo fetch failed")
                print("LEGOSENSE|logo fetch failed, keeping LS text")
            end
        end
        if data then
            -- re-encode as a TGA at its exact screen size, aspect kept: Potassium can't draw some PNGs (grayscale
            -- Roblox decals showed a blank page) and a non-square logo was squashed into the 32 px slot
            S.perfBootMark("logoTgaStart")
            S.logoRaw = data
            local okD, dec = pcall(S.pngDecode, data)
            if okD and dec and dec.w > 0 and dec.h > 0 then
                local s = 32 / math.max(dec.w, dec.h)
                S.logoFit = { math.max(1, math.floor(dec.w * s + 0.5)), math.max(1, math.floor(dec.h * s + 0.5)) }
                local fit = S.imgFit(data, S.devPx(S.logoFit[1]), S.devPx(S.logoFit[2]))
                if fit then data = fit.data end
            end
            pcall(function() S.D.logoImg.Data = data end) UI.logoLoaded = true S.Win.dirty = true
            S.perfBootMark("logoTgaEnd")
            if not S.logoRescale then
                S.logoRescale = true
                S.onRescale(function()
                    local fit = S.logoRaw and S.logoFit and S.imgFit(S.logoRaw, S.devPx(S.logoFit[1]), S.devPx(S.logoFit[2]))
                    if fit then S.D.logoImg.Data = fit.data end
                end)
            end
        end
    end)

    S.loadThemeImage(S.Cfg.preset)   -- current theme's background image, if it has one
end

-- Fetch the shared animated art only when a theme can display it.
function S.loadNyan()
    if UI.nyanData or S.Cfg.perfMode then return end
    UI.nyanData = {}
    local frames = UI.nyanData
    local urls = (#S.Const.NYAN_FRAMES > 0) and S.Const.NYAN_FRAMES or { S.Const.NYAN_URL }
    for i, url in ipairs(urls) do
        task.spawn(function()
            if UI.nyanData ~= frames or S.unloaded then return end
            local path = S.CACHE .. "/nyan_" .. i .. ".txt"
            local data = nil
            if isfile(path) then
                local ok, d = pcall(readfile, path)
                if ok and d and #d > 200 then data = d end
            end
            if not data then
                local ok, d = pcall(function() return S.httpGet(url) end)
                if UI.nyanData ~= frames or S.unloaded then return end
                if ok and d and #d > 200 then
                    data = d
                    S.ensureDir(S.CACHE)
                    pcall(writefile, path, d)
                end
            end
            if data and UI.nyanData == frames and not S.unloaded then
                frames[i] = data
                if not UI.nyanData0 then UI.nyanData0 = data end
                if i == 1 then UI.nyanRatio = imgRatio(data) or 1 end
                S.Win.dirty = true
            end
        end)
    end
end

-- Rainbow's full background only; the Nyan preset flyby keeps using the sharp shared frames.
-- Keep the output small as well as the blur buffers: Drawing stretches the finished TGA.
function S.nyanBlurSize(W, H)
    local scale = math.max(6, W / 192, H / 192)
    return math.max(1, math.floor(W / scale + 0.5)), math.max(1, math.floor(H / scale + 0.5))
end
function S.nyanBlurFrame(d, W, H, radius, alive)
    if not alive() then return nil end
    local w, h = S.nyanBlurSize(W, H)
    local n, Y = w * h, S.budget
    local ch = { buffer.create(n * 4), buffer.create(n * 4), buffer.create(n * 4), buffer.create(n * 4) }
    -- Centre samples preserve the hard art pixels before blur; filtering a downsample first adds a minimum blur.
    for y = 0, h - 1 do
        local sy = math.min(d.h - 1, math.floor((y + 0.5) * d.h / h))
        for x = 0, w - 1 do
            local sx = math.min(d.w - 1, math.floor((x + 0.5) * d.w / w))
            local v = buffer.readu32(d.px, (sy * d.w + sx) * 4)
            local a, o = bit32.rshift(v, 24), (y * w + x) * 4
            buffer.writef32(ch[1], o, bit32.band(v, 255) * a / 255)
            buffer.writef32(ch[2], o, bit32.band(bit32.rshift(v, 8), 255) * a / 255)
            buffer.writef32(ch[3], o, bit32.band(bit32.rshift(v, 16), 255) * a / 255)
            buffer.writef32(ch[4], o, a)
        end
        if Y() and not alive() then return nil end
    end
    -- Match the theme blur's per-pass variance in display pixels. Simply scaling a fractional box radius
    -- over-blurs small values on a coarse grid (its variance is linear, rather than quadratic, near zero).
    local t = radius / 6 -- theme image: three box passes at half display resolution
    local r, e = math.floor(t), t - math.floor(t)
    local variance = 4 * (r * (r + 1) * (2 * r + 1) / 3 + 2 * e * (r + 1) ^ 2) / (2 * r + 1 + 2 * e)
    local tmp = buffer.create(n * 4)
    local function pass(buf, len, count, step, stride, scale)
        local v = variance * scale * scale
        local r = math.floor((math.sqrt(1 + 12 * v) - 1) / 2)
        local edge = (2 * r + 1) * (v - r * (r + 1) / 3) / (2 * ((r + 1) ^ 2 - v))
        local inv = 1 / (2 * r + 1 + 2 * edge)
        for line = 0, count - 1 do
            local base, sum = line * stride, 0
            for k = -r, r do sum += buffer.readf32(buf, (base + math.clamp(k, 0, len - 1) * step) * 4) end
            local left = buffer.readf32(buf, base * 4)
            for i = 0, len - 1 do
                local right = buffer.readf32(buf, (base + math.min(i + r + 1, len - 1) * step) * 4)
                buffer.writef32(tmp, (base + i * step) * 4, (sum + edge * (left + right)) * inv)
                local leaving = buffer.readf32(buf, (base + math.max(i - r, 0) * step) * 4)
                sum, left = sum + right - leaving, leaving
            end
            if Y() and not alive() then return false end
        end
        buffer.copy(buf, 0, tmp, 0, n * 4)
        return true
    end
    for c = 1, 4 do
        for _ = 1, 3 do
            if not pass(ch[c], w, h, 1, w, w / W) or not pass(ch[c], h, w, w, 1, h / H) then return nil end
        end
    end
    local b = buffer.create(18 + n * 4)
    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, w) buffer.writeu16(b, 14, h)
    buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28)
    for i = 0, n - 1 do
        local o, a = i * 4, buffer.readf32(ch[4], i * 4)
        local k = a > 0.5 and 255 / a or 0
        for c = 1, 3 do buffer.writeu8(b, 18 + o + c - 1, math.clamp(math.floor(buffer.readf32(ch[c], o) * k + 0.5), 0, 255)) end
        buffer.writeu8(b, 18 + o + 3, math.clamp(math.floor(a + 0.5), 0, 255))
        if i % 256 == 255 and Y() and not alive() then return nil end
    end
    return alive() and buffer.tostring(b) or nil
end
function S.blurNyan(W, H, blurPx)
    local frames = UI.nyanData
    local count = math.max(1, #S.Const.NYAN_FRAMES)
    local ready = frames ~= nil
    for i = 1, count do if not frames or not frames[i] then ready = false break end end
    local radius = blurPx * (S.K or 1)
    local key = W and H and ready and radius > 0 and S.FX.ok and not S.Env.matcha and not S.Cfg.perfMode
        and table.concat({ blurPx, radius, W, H }, "|") or nil
    -- One decoded set, independent of radius/size. Release it when the background is inactive.
    if not W or not H or not S.FX.ok or S.Env.matcha or S.Cfg.perfMode then UI.nyanDecoded = nil end
    if UI.nyanDecoded and UI.nyanDecoded.frames ~= frames then
        UI.nyanDecoded, UI.nyanBlurKey = nil, nil
    end
    if UI.nyanBlurKey == key then return end
    UI.nyanBlurKey, UI.nyanBlurJob, UI.nyanBlurFrames = key, nil, nil -- drop the previous set immediately
    UI.nyanApplied = nil -- keep cycling sharp frames until the entire replacement is ready
    if not key then return end
    local job = {}
    UI.nyanBlurJob = job
    local function alive()
        return UI.nyanBlurJob == job and UI.nyanBlurKey == key and UI.nyanData == frames
            and S.Cfg.themeImgBlur == blurPx and blurPx * (S.K or 1) == radius
            and not S.Cfg.perfMode and not S.Env.matcha and not S.unloaded
    end
    task.delay(0.2, function()
        if not alive() then return end
        local decoded = UI.nyanDecoded or { frames = frames }
        UI.nyanDecoded = decoded
        local blurred = {}
        for i = 1, count do
            local ok, data = pcall(function()
                local frame = frames[i]
                local cached = decoded[i]
                if not cached or cached.frame ~= frame then
                    local d = (frame:sub(1, 3) == "GIF" and S.gifDecode or S.pngDecode)(frame, alive)
                    if not d or not alive() then return nil end
                    cached = { frame = frame, dec = d }
                    decoded[i] = cached
                end
                return S.nyanBlurFrame(cached.dec, W, H, radius, alive)
            end)
            if not alive() then return end
            if not ok or not data then
                -- Silent: games upload client logs. Keep the sharp animation; no partial set or per-layout retry.
                return
            end
            blurred[i] = data
            S.budget()
            if not alive() then return end
        end
        UI.nyanBlurFrames, UI.nyanBlurJob, UI.nyanApplied = blurred, nil, nil
        S.Win.dirty = true
    end)
end

-- ========== Nyan preset FX ==========
-- Kept outside S.D so showing the window never flashes stale FX. S.New owns unload cleanup.
S.Nyan = { stars = {}, trail = {}, clock = 0, hidden = true }
function S.hideNyan()
    local F = S.Nyan
    if F.hidden then return end
    for _, star in ipairs(F.stars) do star.o.Visible = false end
    for _, band in ipairs(F.trail) do band.Visible = false end
    if F.cat then F.cat.Visible = false end
    F.hidden, F.flyShown = true, false
end
function S.updateNyan(dt)
    local F = S.Nyan
    if not S.Win.visible or S.Cfg.perfMode or S.Cfg.preset ~= "Nyan" or not S.Env.drawing or S.unloaded then
        S.hideNyan()
        return
    end
    if not F.cat then
        for i = 1, 10 do
            F.stars[i] = { x = ((i * 37) % 97) / 97, y = ((i * 23) % 89) / 89, phase = i * 2.4,
                o = S.New("Square", { Filled = true, Corner = 0, Color = S.Theme.White, Transparency = 0, ZIndex = 30, Visible = false }) }
        end
        local colors = { S.C3(255, 55, 70), S.C3(255, 157, 48), S.C3(255, 230, 65),
            S.C3(75, 220, 100), S.C3(65, 155, 255), S.C3(170, 85, 255) }
        for segment = 1, 3 do
            for band = 1, 6 do
                F.trail[#F.trail + 1] = S.New("Square", { Filled = true, Corner = 0, Color = colors[band], Transparency = 0, ZIndex = 32, Visible = false })
            end
        end
        F.cat = S.New("Image", { Transparency = 0, ZIndex = 32, Visible = false })
    end
    F.hidden = false
    F.clock = F.clock + dt -- visible time only: closing the window pauses the loop and twinkle
    local K, opacity = S.K or 1, S.Cfg.opacity or 1
    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    for i, star in ipairs(F.stars) do
        local pulse = (math.sin(F.clock * 1.15 + star.phase) + 1) * 0.5
        local size = ((i % 3 == 0 and 4 or 3) + (pulse > 0.85 and 1 or 0)) / K
        star.o.Position = Vector2.new(math.floor((x + 12 + star.x * (w - 24)) * K) / K,
            math.floor((y + S.TB + 12 + star.y * (h - S.TB - 24)) * K) / K)
        star.o.Size = Vector2.new(size, size)
        star.o.Transparency = (0.20 + pulse * 0.50) * opacity
        star.o.Visible = true -- Z30: above the background, below all card surfaces and text
    end
    local art = S.Cfg.themeImg ~= false and S.Cfg.themeImgUrl == ""
    if art then S.loadNyan() end -- shares Rainbow's cached PNGs; no buffer/Instance dependency on Matcha
    if not art or not UI.nyanData0 then
        F.pass = nil
    elseif not F.pass then
        F.pass = F.clock
    end
    local duration = 5
    local elapsed = F.pass and (F.clock - F.pass) % duration
    -- The cached 530x210 PNGs contain 10x source pixels: snap their 53x21 art grid to whole device pixels.
    local pixel = math.max(1, math.floor((S.TB - 8) * K / 21))
    local catW, catH = 53 * pixel / K, 21 * pixel / K
    local left = math.ceil((F.left or x) * K) / K
    local right = math.floor((F.right or x) * K) / K
    if not elapsed or right - left < catW then
        if F.flyShown then
            F.cat.Visible = false
            for _, band in ipairs(F.trail) do band.Visible = false end
            F.flyShown = false
        end
        return
    end
    local catX = math.floor((left + (right - left - catW) * elapsed / duration) * K) / K
    local catY = math.floor((y + (S.TB - catH) / 2) * K) / K
    F.cat.Size = Vector2.new(catW, catH)
    F.cat.Position = Vector2.new(catX, catY) -- geometry before Data, also required by Matcha
    local idx = (math.floor(elapsed * S.Const.NYAN_FPS) % math.max(1, #S.Const.NYAN_FRAMES)) + 1
    local data = (UI.nyanData and UI.nyanData[idx]) or UI.nyanData0
    if data ~= F.data then
        pcall(function()
            F.cat.Data = data
            F.cat.Position = Vector2.new(catX, catY)
        end)
        F.data = data
    end
    local alpha = opacity * (S.Cfg.themeImgA or 100) / 100
    -- There is no Drawing scissor: keep the whole image inside the free stretch and fade both loop edges.
    local fade = math.clamp(math.min(elapsed, duration - elapsed) / 0.3, 0, 1)
    F.cat.Transparency = alpha * fade
    F.cat.Visible = fade > 0
    for segment = 1, 3 do
        local a = math.max(left, catX - segment * 12 * pixel / K)
        local b = math.min(right, catX - (segment - 1) * 12 * pixel / K)
        local step = ((segment + math.floor(elapsed * 6)) % 2) * pixel / K
        for band = 1, 6 do
            local o = F.trail[(segment - 1) * 6 + band]
            o.Position = Vector2.new(a, catY + step + (band - 1) * 3 * pixel / K)
            o.Size = Vector2.new(math.max(0, b - a), 3 * pixel / K)
            o.Transparency = alpha * (1 - segment / 4) * fade
            o.Visible = b > a and fade > 0 -- title and controls sit outside these bounds
        end
    end
    F.flyShown = true
end

S.loadYield()
-- ========== snow ==========
-- dendrite snowflakes (6 arms, centre hex ring, angled side branches, a cap on each tip), drawn with
-- Lines so they can fall and spin at sub-pixel positions. Three detail levels: big flakes get every branch, small
-- ones only a pair, which keeps the Line count sane. Flakes rotate, twinkle and fade near every edge.
-- arm geometry in arm-local units (x along the arm, y across; 1 = flake radius); the next arm sits at +60 deg
function S.flakeArm(level)
    local c, s = 0.5, 0.8660254 -- cos / sin 60
    local segs = { { 0.14, 0, 1, 0 } } -- main spine
    local function branch(t, L) segs[#segs + 1] = { t, 0, t + L * c, L * s } segs[#segs + 1] = { t, 0, t + L * c, -L * s } end
    if level >= 2 then segs[#segs + 1] = { 0.17, 0, 0.17 * c, 0.17 * s } end -- centre hex ring
    if level == 3 then
        branch(0.26, 0.09) branch(0.40, 0.30) branch(0.60, 0.24) branch(0.77, 0.15)
        segs[#segs + 1] = { 0.92, -0.07, 0.92, 0.07 } -- tip cap
    elseif level == 2 then
        branch(0.48, 0.26) branch(0.72, 0.16)
        segs[#segs + 1] = { 0.92, -0.06, 0.92, 0.06 }
    else
        branch(0.58, 0.24)
    end
    return segs
end
local MAX_SNOW_FLAKES = 28
S.Const.SNOW_N = MAX_SNOW_FLAKES
S.Snow = { flakes = {}, hidden = true, elapsed = 0, arms = { S.flakeArm(1), S.flakeArm(2), S.flakeArm(3) } }
function S.newFlake(i)
    local level = (i % 6 == 0) and 3 or ((i % 3 == 0) and 2 or 1)
    -- biggest flakes top out around 17 px across at the default 115% scale
    local rad = (level == 3 and 6.5 or level == 2 and 5 or 3.3) + math.random() * (level == 3 and 1 or 0.8)
    local arm = S.Snow.arms[level]
    local lines = {}
    for k = 1, 6 * #arm do
        local spine = ((k - 1) % #arm) == 0
        lines[k] = S.New("Line", { Color = S.BaseC1, Thickness = (spine and level == 3) and 1.4 or 1, Transparency = 0, ZIndex = 32, Visible = false })
    end
    return {
        lines = lines, rad = rad, level = level,
        fx = math.random(), fy = math.random(),
        vy = (14 + math.random() * 8 + (3 - level) * 4) * 1.2, -- big flakes drift slower
        amp = 3 + math.random() * 6, freq = 0.3 + math.random() * 0.5,
        ph = math.random() * 6.28, br = math.random(),
        spin = (math.random() - 0.5) * (level == 3 and 0.35 or 0.8),
    }
end

function S.hideFlake(f)
    if not f.shown then return end
    for _, l in ipairs(f.lines) do l.Visible = false end
    f.shown = false
end

function S.hideSnow()
    local snow = S.Snow
    if snow.hidden then return end
    for _, f in ipairs(snow.flakes) do S.hideFlake(f) end
    snow.hidden, snow.elapsed = true, 0
end

function S.updateSnow(dt, t)
    if not S.Win.visible or S.Cfg.bgFx ~= "Snow" or S.Cfg.perfMode then
        S.hideSnow()
        return
    end
    local snow = S.Snow
    snow.elapsed += dt
    if not snow.hidden and snow.elapsed + 1e-6 < 1 / 30 then return end
    dt, snow.elapsed, snow.hidden = snow.elapsed, 0, false
    local base = S.Cfg.fxColor or S.Theme.C1
    local amount = S.Cfg.snowAmount or MAX_SNOW_FLAKES
    local speed = (S.Cfg.snowSpeed or 100) * (S.Cfg.animSpeed or 100) / 10000
    for i = 1, MAX_SNOW_FLAKES do
        local f = snow.flakes[i]
        if i > amount then
            if not f then break end
            S.hideFlake(f)
            continue
        end
        if not f then
            f = S.newFlake(i)
            snow.flakes[i] = f
        end
        f.py = (f.py or f.fy * S.Win.h) + f.vy * dt * speed
        if f.py > S.Win.h + 16 then
            f.py = -16
            f.fx = math.random()
        end
        local px = S.Win.x + f.fx * S.Win.w + math.sin(t * f.freq + f.ph) * f.amp
        local py = S.Win.y + f.py
        local topB = (px < S.Win.x + S.Sb.cur) and (S.Win.y + 4) or (S.Win.y + S.TB + 2)
        -- soft distance to the nearest edge; alpha ramps over ~16px so nothing snaps on/off
        local m = math.min(px - (S.Win.x + 4), (S.Win.x + S.Win.w - 10) - px, py - topB, (S.Win.y + S.Win.h - 8) - py)
        local edge = math.max(0, math.min(1, (m + f.rad * 0.5) / 18))
        edge = edge * edge * (3 - 2 * edge)
        local shown = m > -f.rad
        if shown then
            local twinkle = 0.45 + 0.35 * math.abs(math.sin(t * 1.4 + f.ph))
            if f.base ~= base then
                f.base = base
                local col = S.lerpColor(base, S.Theme.White, 0.25 + f.br * 0.35)
                for _, l in ipairs(f.lines) do l.Color = col end
            end
            local a = twinkle * edge * S.Cfg.opacity
            local rot = t * f.spin + f.ph
            local r = f.rad
            local arm = snow.arms[f.level]
            local li = 0
            for k = 0, 5 do
                local ang = rot + k * 1.0471976
                local ca, sa = math.cos(ang) * r, math.sin(ang) * r
                for si, sg in ipairs(arm) do
                    li = li + 1
                    local l = f.lines[li]
                    l.From = Vector2.new(px + sg[1] * ca - sg[2] * sa, py + sg[1] * sa + sg[2] * ca)
                    l.To = Vector2.new(px + sg[3] * ca - sg[4] * sa, py + sg[3] * sa + sg[4] * ca)
                    l.Transparency = (si == 1) and a or a * 0.85 -- spines a touch brighter than branches
                    if not f.shown then l.Visible = true end
                end
            end
            f.shown = true
        else
            S.hideFlake(f)
        end
    end
end

S.loadYield()
-- ========== dropdown popout ==========
S.Const.MAXOPT = 7
S.Drop = { open = nil, options = {}, hovT = {}, searchBuf = "", scroll = 0, animT = 0, closing = false }
S.Drop.bg = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0.985, ZIndex = 100, Corner = 5, Visible = false })
S.Drop.searchBox = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0.97, ZIndex = 101, Corner = 4, Visible = false })
S.Drop.searchTxt = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS - 1, Visible = false })
S.Drop.bar = S.Scroll.new(101)
S.Drop.sbT = S.Drop.bar.thumb
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
    S.Scroll.hide(S.Drop.bar)
    S.Drop.dropSb = nil
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

-- multi dropdowns hold an array of picked options; single ones a string
function S.dropHas(row, o)
    if not row.multi then return o == tostring(row.value) end
    for _, v in ipairs(row.value) do if v == o then return true end end
    return false
end
function S.dropText(row)
    if not row.multi then return tostring(row.value) end
    local n = #row.value
    if n == 0 then return "None" end
    if n == #row.options and n > 1 then return "All" end
    return table.concat(row.value, ", ")
end
-- returns true when the popout should stay open (multi keeps it open so several can be picked)
function S.dropPick(row, pick)
    if row.multi then
        local v, found = {}, false
        for _, x in ipairs(row.value) do
            if x == pick then found = true else v[#v + 1] = x end
        end
        if not found then v[#v + 1] = pick end
        row.value = v
    else
        row.value = pick
    end
    if row.onChange then pcall(row.onChange, row.value) end
    if row.flag then S.markChanged() end
    return row.multi
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

S.loadYield()
-- ========== color picker (smooth grid) ==========
S.Const.SV_COLS, S.Const.SV_ROWS, S.Const.SV_CELL = 66, 42, 2.34
S.Const.HUE_SEGS = 72
S.Pick = { open = nil, h = 0.3, s = 0.6, v = 0.8, hexFocus = false, hexBuf = "" }
-- The picker uses the window's glass fill (Theme.Bg at ALPHA_BG over a blur rect).
S.Pick.bg   = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = S.Const.ALPHA_BG, ZIndex = 100, Corner = 6, Visible = false })
-- seamless SV square: hue fill + white ramp (left solid -> right clear) + black ramp (top clear -> bottom solid),
-- the exact HSV mix (white at 1 - s, black at 1 - v). The old 66 x 42 grid of squares is only the no-image fallback.
do
    local wr = S.FX.ok and S.FX.get("svWhite", 128, 2, function(x) return 1 - x / 127 end)
    local wl = S.FX.ok and S.FX.get("rampIn", 128, 2, function(x) return x / 127 end)
    local br = S.FX.ok and S.FX.get("svBlack", 2, 128, function(_, y) return y / 127 end)
    local solid = S.FX.ok and S.FX.solid()
    if wr and wl and br and solid then
        S.Pick.useImg = true
        S.Pick.svBase  = S.New("Image", { Data = solid, Color = S.Theme.C1, Transparency = 1, ZIndex = 101, Visible = false, Size = Vector2.new(1, 1) })
        S.Pick.svWhite = S.New("Image", { Data = wr, Color = S.Theme.White, Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(1, 1) })
        S.Pick.svBlack = S.New("Image", { Data = br, Color = Color3.new(0, 0, 0), Transparency = 1, ZIndex = 103, Visible = false, Size = Vector2.new(1, 1) })
        S.Pick.hueImg  = S.New("Image", { Color = S.Theme.White, Transparency = 1, ZIndex = 101, Visible = false, Size = Vector2.new(1, 1) })
        S.Pick.alphaBack = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 101, Corner = 4, Visible = false })
        S.Pick.alphaImg = S.New("Image", { Data = wl, Color = S.Theme.C1, Transparency = 1, ZIndex = 102, Visible = false, Size = Vector2.new(1, 1) })
    end
end
-- round cursor: white ring with a dark rim so it reads on any colour; hue / alpha knobs are white pills
S.Pick.svCurO = S.New("Circle", { Filled = false, Thickness = 1, Radius = 7, NumSides = 32, Color = Color3.new(0, 0, 0), Transparency = 1, ZIndex = 104, Visible = false })
S.Pick.sv = {}
for r = 1, (S.Pick.useImg and 0 or S.Const.SV_ROWS) do
    S.Pick.sv[r] = {}
    for c = 1, S.Const.SV_COLS do
        S.Pick.sv[r][c] = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false, Size = Vector2.new(math.ceil(S.Const.SV_CELL), math.ceil(S.Const.SV_CELL)) })
    end
end
S.Pick.svCur = S.New("Circle", { Filled = false, Thickness = 2, Radius = 5.5, NumSides = 32, Color = S.Theme.White, Transparency = 1, ZIndex = 105, Visible = false })
S.Pick.hueSegs = {}
for i = 1, (S.Pick.useImg and 0 or S.Const.HUE_SEGS) do
    S.Pick.hueSegs[i] = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false })
end
S.Pick.hueCur = S.New("Square", { Filled = true, Color = S.Theme.White, Transparency = 1, ZIndex = 104, Corner = 2, Visible = false })
S.Pick.prev   = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
S.Pick.hexBox = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 101, Corner = 3, Visible = false })
S.Pick.hexTxt = S.New("Text",   { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 102, Font = 0, Size = S.FS - 1, Visible = false })
-- alpha bar (only for colour rows made with Alpha =): picked colour fading into the panel, left = clear, right = solid
S.Const.ALPHA_SEGS = 36
S.Pick.a = 1
S.Pick.alphaSegs = {}
for i = 1, (S.Pick.useImg and 0 or S.Const.ALPHA_SEGS) do
    S.Pick.alphaSegs[i] = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 1, ZIndex = 101, Visible = false })
end
S.Pick.alphaCur = S.New("Square", { Filled = true, Color = S.Theme.White, Transparency = 1, ZIndex = 104, Corner = 2, Visible = false })

S.loadYield()
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
    for _, r in ipairs(S.Pick.sv) do for _, c in ipairs(r) do c.Visible = v end end
    S.Pick.svCur.Visible, S.Pick.svCurO.Visible = v, v
    for _, sg in ipairs(S.Pick.hueSegs) do sg.Visible = v end
    if S.Pick.useImg then
        S.Pick.svBase.Visible, S.Pick.svWhite.Visible, S.Pick.svBlack.Visible, S.Pick.hueImg.Visible = v, v, v, v
    end
    S.Pick.hueCur.Visible = v
    S.Pick.prev.Visible = v
    S.Pick.hexBox.Visible = v
    S.Pick.hexTxt.Visible = v
    local av = v and S.Pick.open ~= nil and S.Pick.open.hasAlpha == true
    for _, sg in ipairs(S.Pick.alphaSegs) do sg.Visible = av end
    if S.Pick.useImg then S.Pick.alphaBack.Visible, S.Pick.alphaImg.Visible = av, av end
    S.Pick.alphaCur.Visible = av
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
    if S.Pick.open.hasAlpha then S.Pick.open.alpha = S.Pick.a end
    if S.Pick.open.onChange then pcall(S.Pick.open.onChange, c, S.Pick.open.alpha) end
    if S.Pick.open.flag then S.markChanged() end
end

function S.openPicker(row)
    S.hardCloseDropdown()
    S.Pick.open = row
    local h, s, v = S.rgb2hsv(row.color or S.Theme.C1)
    S.Pick.h, S.Pick.s, S.Pick.v = h, s, v
    S.Pick.a = row.alpha or 1
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
    S.loadYield() -- building many cards (Settings page, a script's tabs) spreads over frames
    S.Pages[tabIdx] = S.Pages[tabIdx] or { sections = {}, allSections = {}, scrollY = 0, scrollCur = 0, contentH = 0, maxScroll = 0 }
    local sec = {
        title = title, side = side, rows = {}, hovT = 0, vis = true,
        hdr  = S.New("Text", { Text = title, Color = S.Theme.Header, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }),
        hsegs= S.NewFadeSegs(33),
        panel= S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = S.Const.ALPHA_CARD, ZIndex = 31, Corner = 6, Visible = false }),
        glow = S.New("Square", { Filled = false, Thickness = 2, Color = S.Theme.C1, Transparency = 0, ZIndex = 32, Corner = 6, Visible = false }),
        -- layout editor: resize grip (bottom-right); ci = creation order, for Reset
        grip = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0.9, ZIndex = 36, Corner = 2, Visible = false, Size = Vector2.new(10, 10) }),
        bar = S.Scroll.new(35), scroll = 0, scrollCur = 0, scrollV = 0,
        ci = #S.Pages[tabIdx].allSections + 1, side0 = side, page = S.Pages[tabIdx],
    }
    sec.sbT = sec.bar.thumb
    table.insert(S.Pages[tabIdx].allSections, sec)
    table.insert(S.Pages[tabIdx].sections, sec)
    if S.savedCollapsed(tabIdx, title) then sec.collapsed = true sec.colT = 0 end
    return sec
end

-- UI state (collapsed cards, open tab) is saved with the settings as "_collapsed" = { "Tab/Card", ... } and "_tab"
function S.savedCollapsed(tabIdx, title)
    local list = S.Persisted and S.Persisted._collapsed
    if type(list) ~= "table" then return false end
    local key = S.tabNameOf(tabIdx) .. "/" .. tostring(title)
    for _, k in ipairs(list) do if k == key then return true end end
    return false
end
function S.uiStateSnapshot(t)
    local list, subs = {}, {}
    for idx, page in pairs(S.Pages) do
        for _, sec in ipairs(page.allSections or page.sections) do
            if sec.collapsed then list[#list + 1] = S.tabNameOf(idx) .. "/" .. tostring(sec.title) end
            if sec.subKey then subs[sec.subKey] = sec.subSel end
        end
    end
    table.sort(list)
    t._collapsed = list
    t._subtabs = subs
    if S.Favs then t._favs = S.Favs end
    -- card layout: only tabs the user arranged (the rest keep the script's own 2-column flow)
    local lay = {}
    local old = type(S.Persisted._layout) == "table" and S.Persisted._layout or {}
    local present = {}
    for idx, page in pairs(S.Pages) do
        local name = S.tabNameOf(idx)
        present[name] = true
        if page.custom and idx ~= S.SETTINGS_TAB then
            local l = {}
            for _, sec in ipairs(page.allSections or page.sections) do l[#l + 1] = { tostring(sec.title), sec.side, sec.fh or false, sec.fw or false } end
            lay[name] = l
        elseif old[name] and idx ~= S.SETTINGS_TAB then
            -- a saved layout is only applied when its tab is first drawn, so a tab not opened yet this session isn't
            -- "custom" yet: keep its saved entry (dropping it here wiped every edited tab except the open one on the
            -- first autosave). Reset removes the entry itself, so this never brings back a layout the user reset
            lay[name] = old[name]
        end
    end
    for name, l in pairs(old) do if not present[name] then lay[name] = l end end -- tabs this script didn't make
    t._layout = lay
    S.Persisted._layout = lay
    t._tab = S.tabNameOf(S.activeTab)
    local ov = {}
    for _, o in ipairs(S.Overlays) do ov[o.id] = { o.x, o.y } end
    t._overlays = ov
end

-- every value loaded from settings/config, kept so flags created AFTER CreateWindow (the normal
-- order: CreateWindow, then tabs/controls) still pick up their saved value when they register
S.Persisted = {}
S.Defaults = {}
function S.regFlag(row, flag)
    if flag then
        row.flag = flag
        S.FlagRows[flag] = row
        if S.Defaults[flag] == nil then local d = S.flagValue(row) S.Defaults[flag] = type(d) == "table" and table.clone(d) or d end
        local v = S.Persisted[flag]
        if v ~= nil then S.applyRow(row, v) end
    end
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
        -- The value box matches text inputs with a Control fill at the control alpha and a Track outline that warms
        -- to the accent on hover and uses the full accent while typing. The text uses Theme.Text.
        chip  = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false, Size = Vector2.new(52, 17) }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false, Size = Vector2.new(52, 17) }),
        chipT = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 35, Font = 0, Size = S.FS - 1, Visible = false }),
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

-- tile grid: defs = { { title, sub, onClick, wash, big }, ... } in `cols` columns, each tile `tileH` px tall.
-- A 1-column grid of big washed tiles is a banner card. Tiles are clickable when they have onClick (ripple + hover).
function S.addTiles(sec, defs, cols, tileH)
    local row = { kind = "tiles", defs = defs, cols = math.max(1, cols or 2), tileH = tileH or 46, hovT = 0, vis = true,
        hovTs = {}, boxes = {}, lbls = {}, segs = {}, tileRects = {} }
    local rows = math.ceil(#defs / row.cols)
    row.h = rows * row.tileH + math.max(0, rows - 1) * 8 + 8
    local ramp = S.FX.ok and S.FX.get("tabRamp", 256, 2, function(px) return (1 - px / 256) ^ 1.6 end)
    for i, d in ipairs(defs) do
        row.boxes[i] = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 6, Visible = false })
        if d.wash and ramp then row.segs[#row.segs + 1] = S.New("Image", { Data = ramp, Color = S.Theme.C1, Transparency = 0.5, ZIndex = 33, Visible = false, Size = Vector2.new(1, 1) }) d.washObj = row.segs[#row.segs] S.ClipCut[d.washObj] = true end
        row.lbls[2 * i - 1] = S.New("Text", { Text = d.title or "", Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = d.big and (S.FS + 6) or S.FS, Visible = false })
        row.lbls[2 * i] = S.New("Text", { Text = d.sub or "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 2, Visible = false })
        row.hovTs[i] = 0
    end
    -- Stat grids use thin dividers in place of tile boxes and a dim label above each value. Live values use the accent,
    -- and only clickable cells show an accent wash on hover.
    local big = false
    for _, d in ipairs(defs) do if d.big or d.wash then big = true end end
    if not big then
        row.div, row.divs = true, {}
        for k = 1, (row.cols - 1) * rows + (rows - 1) do
            row.divs[k] = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 0.35, ZIndex = 33, Visible = false })
        end
        for i, d in ipairs(defs) do
            row.boxes[i].Color, row.boxes[i].Transparency = S.Theme.C1, 0
            S.Bases[row.boxes[i]] = 0
            row.lbls[2 * i - 1].Size = S.FS - 2
            row.lbls[2 * i].Size = S.FS + 3
        end
        row.h = rows * row.tileH + 8
    end
    table.insert(sec.rows, row)
    return row
end
-- ========== Discord card ==========
-- section:CreateDiscord("discord.gg/code") or { Invite = ... }: banner (or splash, else an accent gradient) across the
-- top keeping 16:9, round server icon over its bottom-left, name, "N online - M members", Copy invite + Join.
-- Data: Discord's public invite API (GET discord.com/api/v10/invites/<code>?with_counts=true) + cdn.discordapp.com images.
-- Join: asks the Discord desktop app (local RPC on 127.0.0.1:6463) to open the invite; no app / no request() -> copies it.
function S.discordLink(row) return "https://discord.gg/" .. row.code end
-- colour the card actually shows (Panel at ALPHA_CARD over the window bg): the banner fades into this, not raw Panel
function S.cardColor() return S.lerpColor(S.Theme.Bg, S.Theme.Panel, S.Const.ALPHA_CARD) end
-- background / card / bar transparency + theme image opacity (Settings > Theme > Surfaces)
function S.applyAlphas()
    S.Const.ALPHA_BG = (S.Cfg.bgAlpha or 72) / 100
    S.Const.ALPHA_CARD = (S.Cfg.cardAlpha or 60) / 100
    S.Const.ALPHA_BAR = (S.Cfg.barAlpha or 72) / 100
    S.Bases[S.D.main], S.Bases[S.D.search] = S.Const.ALPHA_BG, S.Const.ALPHA_BG
    if S.Pick and S.Pick.bg then S.Bases[S.Pick.bg] = S.Const.ALPHA_BG end
    for _, o in ipairs({ S.D.topbar, S.D.sidebar, S.D.seam }) do S.Bases[o] = S.Const.ALPHA_BAR end
    for _, o in ipairs(S.D.fillet or {}) do S.Bases[o] = S.Const.ALPHA_BAR end
    for _, page in pairs(S.Pages) do
        for _, sec in ipairs(page.allSections or page.sections) do S.Bases[sec.panel] = S.Const.ALPHA_CARD end
    end
    if S.D.themeImg then S.Bases[S.D.themeImg] = (S.Cfg.themeImgA or 100) / 100 end
    S.setOpacity(S.Cfg.opacity or 1)
    S.Win.dirty = true
end
-- ===== window glass (Settings > Effects > BLUR "Glass") =====
-- A rendered Image at the window's exact device size replaces its flat fill.
-- Size, background tint or corner radius changes trigger a render that yields between rows.
-- The flat fill stays visible until the first texture is ready.
function S.glassOn() return S.Cfg.glass ~= false and not S.Cfg.perfMode and S.FX.ok and not S.Env.matcha end
-- Dark glass uses Theme.Bg with a top sheen (14%, squared falloff) and fine grain (+/-6 from a fixed 64x64 table).
-- Alpha is 0.44 plus the sheen, with anti-aliased corners. Per-row calculations are
-- hoisted, the rounded-corner distance only runs in the corner squares, and it pauses every ~6k pixels.
S.GlassNoise = nil
function S.glassRender(W, H, style, bgc, R, alive)
    if not S.GlassNoise then
        local t = buffer.create(64 * 64 * 4)
        for y = 0, 63 do for x = 0, 63 do
            local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
            buffer.writef32(t, (y * 64 + x) * 4, (h - math.floor(h) - 0.5) * 12)
        end end
        S.GlassNoise = t
    end
    local NZ = S.GlassNoise
    local br, bgg, bb = bgc.R * 255, bgc.G * 255, bgc.B * 255
    local b = buffer.create(18 + W * H * 4)
    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, W) buffer.writeu16(b, 14, H)
    buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28)
    local o, budget = 18, 0
    local floor, clamp, sqrt, min = math.floor, math.clamp, math.sqrt, math.min
    for y = 0, H - 1 do
        local v = y / H
        local sh = 0.14 * (1 - v) ^ 2
        local r0, g0, b0 = br + (255 - br) * sh, bgg + (255 - bgg) * sh, bb + (255 - bb) * sh
        local a0 = (0.44 + sh) * 255
        local py = y + 0.5
        local nrow = (y % 64) * 64
        local corner = py < R or py > H - R
        local dy = min(py, H - py)
        for x = 0, W - 1 do
            local px = x + 0.5
            local d
            if corner and (px < R or px > W - R) then
                local qx, qy = math.max(R - px, px - (W - R), 0), math.max(R - py, py - (H - R), 0)
                d = (qx > 0 and qy > 0) and (R - sqrt(qx * qx + qy * qy)) or min(px, W - px, dy)
            else
                d = min(px, W - px, dy)
            end
            if d <= -0.5 then
                buffer.writeu32(b, o, 0)
            else
                local cov = d < 0.5 and d + 0.5 or 1
                local n = buffer.readf32(NZ, (nrow + x % 64) * 4)
                local r, g, bl, a = r0 + n, g0 + n, b0 + n, a0
                buffer.writeu32(b, o, clamp(floor(bl + 0.5), 0, 255) + clamp(floor(g + 0.5), 0, 255) * 256
                    + clamp(floor(r + 0.5), 0, 255) * 65536 + clamp(floor(a * cov + 0.5), 0, 255) * 16777216)
            end
            o = o + 4
        end
        if S.budget() and not alive() then return nil end
    end
    return buffer.tostring(b)
end
S.Glass = {}
function S.glassLayout(x, y, w, h)
    local G = S.Glass
    local on = UI.created and S.glassOn()
    S.Bases[S.D.main] = (on and G.have) and 0 or S.Const.ALPHA_BG -- flat fill until the glass picture is ready
    S.D.main.Transparency = S.Bases[S.D.main] * (S.Cfg.opacity or 1)
    if not on then
        G.want = nil
        if G.img then G.img.Visible = false end
        return
    end
    if not G.img then G.img = S.New("Image", { Transparency = 1, ZIndex = 29, Visible = false, Size = Vector2.new(1, 1) }) end
    G.img.Position, G.img.Size = Vector2.new(x, y), Vector2.new(w, h)
    G.img.Visible = S.Win.visible and G.have == true
    G.img.Transparency = S.Cfg.opacity or 1
    local W, H = S.devPx(w), S.devPx(h)
    local key = table.concat({ W, H, S.hexOf(S.Theme.Bg), S.CR(8) }, "|")
    if G.want and G.want.key == key then return end
    local job = { key = key }
    G.want = job
    local function alive() return G.want == job and not S.unloaded and S.glassOn() end
    task.delay(0.25, function() -- settle (window drag-resize) before rendering
        if not alive() then return end
        S.perfBootMark("windowGlassTgaStart")
        local data = S.glassRender(W, H, "Dark", S.Theme.Bg, S.devPx(S.CR(8)), alive)
        if data and alive() then
            G.img.Data, G.have = data, true
            S.Win.dirty = true
        end
        S.perfBootMark("windowGlassTgaEnd")
    end)
end
-- the same glass behind any other panel (overlays, Spotlight, toasts, tooltip, picker, right-click menu). Call it every
-- frame the panel shows, after the panel set its fill: once the picture for this size is ready it draws it and turns the
-- fill (sq) off. Renders 0.12 s after the size settles (the last picture stretches meanwhile); S.glassSweep hides
-- pictures whose panel stopped calling and frees ones unused for ~10 s.
S.GlassP = {}
function S.glassPanel(id, sq, x, y, w, h, a, R)
    local P = S.GlassP[id]
    if not S.glassOn() then return end
    if not P then
        P = { img = S.New("Image", { Transparency = 0, ZIndex = sq.ZIndex, Visible = false, Size = Vector2.new(1, 1) }) }
        S.GlassP[id] = P
    end
    P.f = S.Blur.frame
    local W, H = S.devPx(w), S.devPx(h)
    local key = table.concat({ W, H, R, S.hexOf(S.Theme.Bg) }, "|")
    if not P.want or P.want.key ~= key then
        local job = { key = key }
        P.want = job
        local function alive() return P.want == job and not S.unloaded and S.glassOn() end
        task.delay(0.12, function()
            if not alive() then return end
            S.perfBootMark("panelGlassTgaStart")
            local d = S.glassRender(W, H, "Dark", S.Theme.Bg, S.devPx(R), alive)
            if d and alive() then pcall(function() P.img.Data = d end) P.have = true end
            S.perfBootMark("panelGlassTgaEnd")
        end)
    end
    P.img.Position, P.img.Size = Vector2.new(x, y), Vector2.new(w, h)
    P.img.Transparency = a
    P.img.Visible = P.have == true and a > 0.01
    if P.have then sq.Transparency = 0 end
end
function S.glassSweep()
    local f = S.Blur.frame
    local on = S.glassOn()
    for id, P in pairs(S.GlassP) do
        if not on or P.f < f - 600 then
            P.want = nil
            pcall(S.freeObj, P.img)
            S.GlassP[id] = nil
        elseif P.f < f - 1 and P.img.Visible then
            P.img.Visible = false
        end
    end
end
function S.addDiscord(sec, invite)
    local code = tostring(invite or ""):gsub("%s", ""):gsub("/+$", ""):match("([%w%-_]+)$") or ""
    local solid = S.FX.solid()
    local fade = S.FX.ok and S.FX.get("dcFade2", 2, 64, function(_, y) local t = y / 64 return t * t * (3 - 2 * t) end)
    local grad = S.FX.ok and S.FX.get("dcGrad", 64, 36, function(x, y) return 0.25 + 0.5 * (x / 64) * (1 - y / 72) end)
    local Z = 33
    local function img(z, col) return S.New("Image", { Data = solid, Color = col, Transparency = 1, ZIndex = z, Visible = false, Size = Vector2.new(1, 1) }) end
    local function txt(t, size, col) return S.New("Text", { Text = t, Color = col, Transparency = 1, ZIndex = Z + 2, Font = 0, Size = size, Visible = false }) end
    local row = { kind = "discord", code = code, h = 170, bh = 120, hovT = 0, vis = true, hovTs = { 0, 0 }, btnRects = {},
        name = (code ~= "" and "Loading..." or "Discord"), counts = (code ~= "" and "" or "No invite set"),
        img  = S.New("Image", { Data = grad or solid, Color = S.Theme.C1, Transparency = 1, ZIndex = Z, Visible = false, Size = Vector2.new(1, 1) }),
        glow = S.New("Image", { Data = fade or solid, Color = S.cardColor(), Transparency = 1, ZIndex = Z, Visible = false, Size = Vector2.new(1, 1) }),
        segs = {
            img(Z + 1, S.cardColor()),                 -- 1 icon ring
            img(Z + 2, S.Theme.C1),                    -- 2 icon
            img(Z + 2, Color3.fromRGB(67, 181, 129)),  -- 3 online dot
            img(Z + 2, Color3.fromRGB(128, 132, 142)), -- 4 members dot
            img(Z + 2, S.Theme.Text),                  -- 5 join icon
        },
        boxes = {
            S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0.16, ZIndex = Z, Corner = 6, Visible = false }),
        },
        olines = {
            S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0.55, ZIndex = Z + 1, Corner = 6, Thickness = 1, Visible = false }),
        },
        lbls = {
            txt("Discord", S.FS + 5, S.Theme.White), -- 1 name
            txt("", S.FS - 1, S.Theme.Dim),          -- 2 online
            txt("Join server", S.FS - 2, S.Theme.Text), -- 3 button
            txt("", S.FS - 1, S.Theme.Dim),          -- 4 members
        },
    }
    S.loadIcon("external-link", function(d) row.segs[5].Data = d S.cropSet(row.segs[5], d) row.icoJoin = true end)
    -- solid shapes are cut like rectangles; pictures are cut row by row (S.cropSet)
    for _, k in ipairs({ 1, 3, 4 }) do S.ClipCut[row.segs[k]] = true end
    if not grad then S.ClipCut[row.img] = true end
    if not fade then S.ClipCut[row.glow] = true end
    if not row.iconOk then S.ClipCut[row.segs[2]] = true end
    task.spawn(function()
        if grad then S.cropSet(row.img, grad) end
        if fade then S.cropSet(row.glow, fade) end
    end)
    table.insert(sec.rows, row)
    return row
end
function S.fmtCount(n)
    n = tostring(math.floor(tonumber(n) or 0))
    return (n:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
function S.layoutDiscord(row, x, w, ry)
    local by, bh = ry + 4, row.bh
    local cc = S.cardColor()
    row.img.Position, row.img.Size = Vector2.new(x, by), Vector2.new(w, bh)
    pcall(function() row.img.Rounding = S.CR(6) end)
    local fy = by + math.floor(bh * 0.35)
    row.glow.Position, row.glow.Size, row.glow.Color = Vector2.new(x, fy), Vector2.new(w, by + bh - fy + 1), cc
    local ring, ico, dOn, dAll = row.segs[1], row.segs[2], row.segs[3], row.segs[4]
    local ix, iy = x + 12, by + bh - 26
    ring.Position, ring.Size, ring.Color = Vector2.new(ix - 3, iy - 3), Vector2.new(54, 54), cc
    ring.Visible = false
    ico.Position, ico.Size = Vector2.new(ix, iy), Vector2.new(48, 48)
    pcall(function() ring.Rounding = 27 ico.Rounding = 24 end)
    local tx = ix + 60
    local nm, on, all = row.lbls[1], row.lbls[2], row.lbls[4]
    nm.Text = S.truncate(row.name, math.floor((x + w - tx - 6) * S.FS / (S.FS + 5)))
    nm.Position = Vector2.new(tx, by + bh + 4)
    local cy = by + bh + 4 + S.TH(nm, S.FS + 5) + 4
    local dh = S.TH(on, S.FS - 1)
    if row.on and row.all then
        on.Text, all.Text = S.fmtCount(row.on) .. " online", S.fmtCount(row.all) .. " members"
        dOn.Position, dOn.Size = Vector2.new(tx, cy + math.floor((dh - 7) / 2)), Vector2.new(7, 7)
        on.Position = Vector2.new(tx + 11, cy)
        local ax = tx + 11 + S.TW(on) + 10
        if ax + 11 + S.TW(all) > x + w then -- no room on one line: members goes under online
            ax, cy = tx, cy + dh + 3
        end
        dAll.Position, dAll.Size = Vector2.new(ax, cy + math.floor((dh - 7) / 2)), Vector2.new(7, 7)
        all.Position = Vector2.new(ax + 11, cy)
        pcall(function() dOn.Rounding = 3.5 dAll.Rounding = 3.5 end)
    else
        on.Text, all.Text = S.truncate(row.counts, x + w - tx - 6), ""
        on.Position = Vector2.new(tx, cy)
        dOn.Visible, dAll.Visible = false, false
    end
    -- button follows the text block: right under one line of counts, lower when members wrapped to a second line
    local BH = 22
    local byb = math.max(iy + 48 + 8, cy + dh + 12)
    row.btnRects[1] = { x, byb, w, BH }
    local b, t, ic = row.boxes[1], row.lbls[3], row.segs[5]
    b.Position, b.Size, b.Corner = Vector2.new(x, byb), Vector2.new(w, BH), S.CR(6)
    local iw = row.icoJoin and 16 or 0
    local cx0 = x + math.floor((w - S.TW(t) - iw) / 2)
    ic.Visible = ic.Visible and row.icoJoin and true or false
    ic.Position, ic.Size = Vector2.new(cx0, byb + 5), Vector2.new(12, 12)
    t.Position = Vector2.new(cx0 + iw, byb + math.floor((BH - S.TH(t, S.FS - 2)) / 2))
    local ol = row.olines[1]
    ol.Position, ol.Size, ol.Corner = Vector2.new(x, byb), Vector2.new(w, BH), S.CR(6)
    -- card height follows (the pre-pass reads row.hx next frame)
    local hx = byb + BH + 6 - (by + bh)
    if hx ~= row.hx then row.hx = hx S.cardAnim = true end
end
-- disk cache (config folder /discord): the card shows at once on later loads; the API is asked again after 5 min
-- server icon at its exact screen size; redone when the UI scale changes
function S.discordIcon(row, d)
    local f = S.imgFit(d, S.devPx(48), S.devPx(48))
    row.segs[2].Data, row.segs[2].Color, row.iconOk = f and f.data or d, Color3.new(1, 1, 1), true
    S.ClipCut[row.segs[2]] = nil
    S.cropSet(row.segs[2], f and f.data or d, f)
    if not row.icoRaw then S.onRescale(function() S.discordIcon(row, row.icoRaw) end) end
    row.icoRaw = d
end
function S.discordCache(code) return S.FOLDER .. "/discord/" .. code end
function S.discordApply(row, j)
    local g = j.guild or {}
    row.name = tostring(g.name or "Discord")
    row.on, row.all = j.approximate_presence_count, j.approximate_member_count
    S.Win.dirty = true
end
function S.discordLoad(row)
    if row.code == "" then return end
    task.spawn(function()
        local HS = game:GetService("HttpService")
        local base = S.discordCache(row.code)
        local function rd(p) local ok, d = pcall(function() return isfile(p) and readfile(p) or nil end) return ok and d or nil end
        local function wr(p, d) pcall(function()
            S.ensureDir(S.FOLDER .. "/discord")
            writefile(p, d)
        end) end
        local cached = rd(base .. ".json")
        local okC, cj = pcall(function() return cached and HS:JSONDecode(cached) end)
        if okC and type(cj) == "table" and type(cj.guild) == "table" then
            S.discordApply(row, cj)
            local ic, bn = rd(base .. "_icon.txt"), rd(base .. "_banner.txt")
            if ic and #ic > 64 then
                pcall(S.discordIcon, row, ic)
            end
            if bn and #bn > 64 then pcall(function() row.img.Data, row.img.Color, row.banOk = bn, Color3.new(1, 1, 1), true end) S.cropSet(row.img, bn) end
        end
        local first = true
        while not UI.unloaded do
            local fresh = okC and type(cj) == "table" and tonumber(cj._at) and os.time() - cj._at < 300
            if not (first and fresh) then
                local ok, body = pcall(S.httpGet, "https://discord.com/api/v10/invites/" .. row.code .. "?with_counts=true")
                local okJ, j = pcall(function() return HS:JSONDecode(body) end)
                if ok and okJ and type(j) == "table" and type(j.guild) == "table" then
                    S.discordApply(row, j)
                    j._at = os.time()
                    pcall(function() wr(base .. ".json", HS:JSONEncode(j)) end)
                    local g = j.guild
                    local function img(url, file, set)
                        local ok2, d = pcall(S.httpGet, url)
                        if ok2 and type(d) == "string" and #d > 64 then pcall(set, d) wr(file, d) S.Win.dirty = true return d end
                    end
                    if first or not row.iconOk then
                        if g.icon then
                            img(string.format("https://cdn.discordapp.com/icons/%s/%s.png?size=128", g.id, g.icon), base .. "_icon.txt", function(d)
                                S.discordIcon(row, d)
                            end)
                        end
                        local bn = (g.banner and string.format("https://cdn.discordapp.com/banners/%s/%s.png?size=512", g.id, g.banner))
                            or (g.splash and string.format("https://cdn.discordapp.com/splashes/%s/%s.png?size=512", g.id, g.splash))
                        if bn then img(bn, base .. "_banner.txt", function(d) row.img.Data, row.img.Color, row.banOk = d, Color3.new(1, 1, 1), true S.cropSet(row.img, d) end) end
                    end
                elseif not row.on then
                    row.name = "Discord"
                    row.counts = (ok and "Invite not found") or "Couldn't reach Discord"
                    S.Win.dirty = true
                    return
                end
            end
            first = false
            task.wait(300)
        end
    end)
end
function S.discordJoin(row)
    local req = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
        or (type(syn) == "table" and syn.request)
    local opened = false
    if req and row.code ~= "" then
        local HS = game:GetService("HttpService")
        local ok, r = pcall(req, { Url = "http://127.0.0.1:6463/rpc?v=1", Method = "POST",
            Headers = { ["Content-Type"] = "application/json", Origin = "https://discord.com" },
            Body = HS:JSONEncode({ cmd = "INVITE_BROWSER", args = { code = row.code }, nonce = HS:GenerateGUID(false) }) })
        opened = ok and type(r) == "table" and (r.Success == true or r.StatusCode == 200)
    end
    -- always copies the invite; also opens it in the Discord app when it's running
    local copied = pcall(setclipboard, S.discordLink(row))
    if opened then S.toast("Discord", copied and "Invite copied, opening it in Discord" or "Opening the invite in Discord", 2.5)
    else S.toast(copied and "Invite copied" or "Couldn't copy", copied and "Discord isn't open: paste the invite there" or "This executor has no clipboard access", 3) end
end
-- greeting header: avatar, big line, small line
function S.addHero(sec, title, sub)
    local row = { kind = "hero", label = title or "", subText = sub or "", -- not .sub: that marks sub-tab rows
        hovT = 0, vis = true, h = 64,
        img = S.New("Image", { Transparency = 1, ZIndex = 34, Visible = false, Size = Vector2.new(56, 56) }),
        lbl = S.New("Text", { Text = title or "", Color = S.Theme.White, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS + 6, Visible = false }),
        val = S.New("Text", { Text = sub or "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }) }
    S.loadAvatar(function(data)
        local f = S.imgFit(data, S.devPx(56), S.devPx(56))
        pcall(function() row.img.Data = f and f.data or data end)
        S.cropSet(row.img, f and f.data or data, f)
    end)
    table.insert(sec.rows, row)
    return row
end

function S.addDropdown(sec, label, options, default, flag, onChange, multi)
    if multi then default = table.clone(type(default) == "table" and default or {}) end
    local row = {
        kind = "dropdown", label = label, options = options, value = default, onChange = onChange, multi = multi,
        hovT = 0, vis = true, h = 34,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        box = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = S.Const.ALPHA_CTRL, ZIndex = 33, Corner = 4, Visible = false }),
        oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 34, Corner = 4, Visible = false }),
        val = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false }),
        arr = S.New("Text", { Text = "v", Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

function S.addColor(sec, label, default, flag, onChange)
    local row = {
        kind = "color", label = label, color = default, onChange = onChange, hovT = 0, vis = true, h = 34,
        hasAlpha = S.addColorAlpha ~= nil, alpha = S.addColorAlpha,
        lbl = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        sw  = S.New("Square", { Filled = true, Color = default, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(16, 16) }),
    }
    table.insert(sec.rows, row)
    return S.regFlag(row, flag)
end

S.KeybindRows = {}
function S.addKeybind(sec, label, defaultVk, flag, onChange)
    local row = {
        kind = "keybind", label = label, vk = defaultVk, onChange = onChange, hovT = 0, vis = true, h = 34,
        lbl  = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        chip = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 1, ZIndex = 33, Corner = 3, Visible = false, Size = Vector2.new(44, 17) }),
        chipT= S.New("Text", { Text = S.keyName(defaultVk), Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 1, Visible = false }),
    }
    table.insert(sec.rows, row)
    table.insert(S.KeybindRows, row)
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

-- Compact release groups accept structured entries and the older date/bullet/blank-line format.
S.UI_NEWS = {
    { Date = "11/16/2026", Changes = {
        "added a theme image URL box, paste your own image link in Settings",
        "glow switch now turns off control glows, notifications and intro glows too",
        "removed Columbina theme",
        "cleaned up the update log",
        "fixed flickering near scroll edges and uneven scrollbars",
        "fixed long tooltips running off screen",
    } },
}
function S.homeNews(opts)
    opts = opts or {}
    local source = opts.NewsSource
    if source == nil then source = opts.Changelog ~= nil and "Script" or "UI" end
    if source == "Script" then
        return type(opts.Changelog) == "table" and opts.Changelog or {}, "Script"
    end
    return S.UI_NEWS, "UI"
end
function S.newsEntries(input)
    local entries, current = {}, nil
    local function entry(date)
        current = { date = tostring(date or ""), changes = {} }
        entries[#entries + 1] = current
        return current
    end
    for _, item in ipairs(input or {}) do
        if type(item) == "table" then
            local lines = item.Changes or item.Lines or item[2]
            if type(lines) == "table" then
                local release = entry(item.Date or item[1])
                for _, text in ipairs(lines) do
                    if type(text) == "string" and text:match("%S") then release.changes[#release.changes + 1] = text end
                end
            end
        elseif type(item) == "string" then
            local text = item:match("^%s*(.-)%s*$")
            if text ~= "" then
                if text:match("^%d%d?/%d%d?/%d%d%d%d") or text:match("^%d%d%d%d%-%d%d%-%d%d") or text == "(no date)" then
                    entry(text)
                else
                    if not current then entry("") end
                    local bullet = text:match("^%-%s+(.+)$")
                    local changes = current.changes
                    if not bullet and item:match("^    %S") and #changes > 0 then
                        changes[#changes] = changes[#changes] .. " " .. text
                    else
                        changes[#changes + 1] = bullet or text
                    end
                end
            end
        end
    end
    return entries
end
function S.newsDate(date)
    local month, day, year, time = date:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)%s*(.-)%s*$")
    if not month then year, month, day, time = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s*(.-)%s*$") end
    local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
    local name = month and months[tonumber(month)]
    if not name then return date, "" end
    return name .. " " .. tostring(tonumber(day)), time
end
function S.addChangelog(sec, input)
    -- Let the final wrapped line clear the edge fade at maximum scroll.
    sec.contentPadBottom = math.max(sec.contentPadBottom or 0, (S.Const.CLIP_FADE or 8) + 4)
    for index, release in ipairs(S.newsEntries(input)) do
        if release.date ~= "" then
            local row = S.addNote(sec, release.date)
            local date, time = S.newsDate(release.date)
            row.noteStyle, row.newsDate, row.newsTime = "newsDate", date, time
            row.tip, row.newsTop = release.date, index == 1 and 4 or 14
            row.h = row.newsTop + 18
            row.lbl.Size = S.FS
            row.val = S.New("Text", { Text = time, Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 2, Visible = false })
            if index == 1 then
                row.chip = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0.9, ZIndex = 33, Corner = 3, Visible = false })
                row.chipT = S.New("Text", { Text = "Latest", Color = S.Theme.Header, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS - 2, Visible = false })
            else
                row.base = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 0.3, ZIndex = 33, Visible = false })
            end
        end
        for _, text in ipairs(release.changes) do
            local row = S.addNote(sec, text)
            row.noteStyle, row.h = "newsChange", 18
            row.arr = S.New("Text", { Text = "·", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false })
        end
    end
end

-- progress bar row: value 0..1, eased fill, percent on the right. Set(v) updates it.
function S.addProgress(sec, label, value)
    local row = { kind = "progress", label = label, value = value or 0, shown = value or 0, hovT = 0, vis = true, h = 36,
        lbl   = S.New("Text", { Text = label, Color = S.Theme.Text, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS, Visible = false }),
        val   = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false }),
        track = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 1, ZIndex = 33, Corner = 2, Visible = false }),
        bar   = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 34, Corner = 2, Visible = false }) }
    table.insert(sec.rows, row)
    return row
end

-- image row: src = image url or numeric asset id; Height in px (default 120). Fit inside the card width, aspect kept.
function S.addImage(sec, src, height)
    local row = { kind = "image", label = "", hovT = 0, vis = true, h = (height or 120) + 8, ratio = nil,
        img = S.New("Image", { Transparency = 1, ZIndex = 34, Visible = false, Size = Vector2.new(1, 1) }) }
    table.insert(sec.rows, row)
    task.spawn(function()
        local url = src
        if type(src) == "number" then
            local okT, tj = pcall(function() return S.httpGet("https://thumbnails.roblox.com/v1/assets?assetIds=" .. tostring(src) .. "&size=420x420&format=Png&isCircular=false") end)
            url = okT and tostring(tj):match('"imageUrl"%s*:%s*"([^"]+)"')
        end
        if type(url) ~= "string" then return end
        local ok, d = pcall(function() return S.httpGet(url) end)
        if ok and d and #d > 100 then
            pcall(function() row.img.Data = d end)
            row.ratio = imgRatio(d)
            S.Win.dirty = true
        end
    end)
    return row
end

-- remove a Drawing made with S.New for good (toasts / dialogs that come and go)
function S.freeObj(o)
    if not o then return end
    for i = #UI.Objects, 1, -1 do
        if UI.Objects[i] == o then
            table.remove(UI.Objects, i)
            S.Perf.freed = S.Perf.freed + 1
            break
        end
    end
    for i = #S.TextObjs, 1, -1 do if S.TextObjs[i] == o then table.remove(S.TextObjs, i) break end end
    S.Bases[o], S.Shapes[o] = nil, nil
    pcall(function() o:Remove() end)
end

function S.playerNames(excludeLocal)
    local out = {}
    for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
        if not (excludeLocal and p == S.LocalPlayer) then table.insert(out, p.Name) end
    end
    table.sort(out)
    return out
end
-- keeps a SpecialType = "Player" dropdown in sync. Polls every 2 s (PlayerAdded may not fire on every executor).
function S.trackPlayers(h, excludeLocal)
    task.spawn(function()
        local last = table.concat(S.playerNames(excludeLocal), "\0")
        while #UI.Objects > 0 do
            task.wait(2)
            local names = S.playerNames(excludeLocal)
            local key = table.concat(names, "\0")
            if key ~= last then last = key pcall(h.SetOptions, h, names) end
        end
    end)
end

-- ---- toasts: themed notifications stacked bottom-right, newest at the bottom ----
S.Toasts = {}
S.Const.TOAST_W = 280
function S.toast(title, msg, dur)
    local lines = S.wrapPx(tostring(msg or ""), S.Const.TOAST_W - 28)
    local t = { born = os.clock(), dur = dur or S.Cfg.notifyTime or 5, y = nil, nl = math.min(3, #lines), lines = {}, full = {}, typed = -1,
        xo = S.Const.TOAST_W + S.Const.EDGE + 24, xv = 0,
        bg   = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = 0, ZIndex = 60, Corner = 6, Visible = false }),
        ol   = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0, ZIndex = 61, Corner = 6, Visible = false }),
        acc  = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = 61, Corner = 1, Visible = false }),
        tt   = S.New("Text", { Text = S.truncate(tostring(title or ""), S.Const.TOAST_W - 28), Color = S.Theme.Text, Transparency = 0, ZIndex = 62, Font = 0, Size = S.FS, Visible = false }) }
    for i = 1, t.nl do
        t.full[i] = (i == 3 and #lines > 3) and (lines[i] .. "..") or lines[i]
        t.lines[i] = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 0, ZIndex = 62, Font = 0, Size = S.FS - 1, Visible = false })
    end
    t.h = 32 + t.nl * 14
    table.insert(S.Toasts, 1, t)
    local mx = S.Cfg.notifMax or 6
    for i = mx + 1, #S.Toasts do S.Toasts[i].born = math.min(S.Toasts[i].born, os.clock() - S.Toasts[i].dur) end
end
-- the card itself (all share one fade)
function S.toastBase(t)
    local o = { t.bg, t.ol, t.acc, t.tt }
    for _, l in ipairs(t.lines) do o[#o + 1] = l end
    return o
end
function S.toastObjs(t)
    local o = S.toastBase(t)
    if t.life then o[#o + 1] = t.life end
    if t.glow then o[#o + 1] = t.glow end
    if t.shim then for _, c in ipairs(t.shim) do o[#o + 1] = c end end
    return o
end
function S.updateToasts(dt)
    if #S.Toasts == 0 then return end
    local okV, vp = pcall(function() return S.vpLogical() end)
    if not okV or not vp then return end
    local now, W, E = os.clock(), S.Const.TOAST_W, S.Const.EDGE
    local anim = S.animOn()
    local perf, glows = S.Cfg.perfMode, S.glowsOn()
    local ease = anim and (1 - (0.00001 ^ dt)) or 1
    -- Settings > Overlays > Notification corner
    local corner = S.Cfg.notifCorner or "Bottom right"
    local top, left = corner:find("Top") ~= nil, corner:find("left") ~= nil
    local curY = top and E or (vp.Y - E)
    for i = 1, #S.Toasts do
        local t = S.Toasts[i]
        if not t then break end
        local age = now - t.born
        if age > t.dur + (perf and 0 or 0.25) then
            for _, o in ipairs(S.toastObjs(t)) do S.freeObj(o) end
            table.remove(S.Toasts, i)
            break -- the rest re-stack next frame
        end
        -- goo slide: in on an underdamped spring (overshoots, stretches while fast, settles); out on a smooth ease
        local fade
        if age > t.dur then
            local s = math.min(1, (age - t.dur) / 0.25)
            s = s * s * (3 - 2 * s)
            t.xo, t.xv, fade = s * (W + E + 24), 0, 1 - s
        elseif anim then
            t.xv = (t.xv - t.xo * 230 * dt) * math.exp(-15 * dt)
            t.xo = t.xo + t.xv * dt
            fade = math.min(1, age / 0.15)
        else
            t.xo, t.xv, fade = 0, 0, 1
        end
        local stretch = math.min(0.16, math.abs(t.xv) / 4000)
        local w, hh = W * (1 + stretch), t.h * (1 - stretch * 0.6)
        local ty = top and curY or (curY - t.h)
        t.y = t.y and (t.y + (ty - t.y) * ease) or ty
        curY = top and (ty + t.h + 8) or (ty - 8)
        local x = left and (E - t.xo) or (vp.X - E - W + t.xo)
        local y = t.y + (t.h - hh) / 2
        local a = fade * S.Cfg.opacity
        t.bg.Position, t.bg.Size = Vector2.new(x, y), Vector2.new(w, hh)
        if fade > 0.3 then S.Blur.rect(t, x, y, w, hh, S.Const.BLUR_INSET_SMALL) end -- small panel: same bloom margin as overlays
        t.ol.Position, t.ol.Size = Vector2.new(x, y), Vector2.new(w, hh)
        t.acc.Position, t.acc.Size = Vector2.new(x + 10, y + 12), Vector2.new(3, math.max(2, hh - 24))
        t.tt.Position = Vector2.new(x + 20, t.y + 9)
        -- typewriter body
        local n = anim and math.floor(math.max(0, age - 0.12) * 120) or 1e9
        if n ~= t.typed then
            t.typed = n
            local rest = n
            for k, l in ipairs(t.lines) do
                local s = t.full[k]
                l.Text = (rest >= #s) and s or s:sub(1, math.max(0, rest))
                rest = rest - #s
            end
        end
        for k, l in ipairs(t.lines) do l.Position = Vector2.new(x + 20, t.y + 13 + 14 * k) l.Color = S.Theme.Dim end
        if not perf then
            if not t.life then t.life = S.New("Square", { Filled = true, ZIndex = 61, Visible = false }) end
            local remaining = math.max(0, 1 - age / t.dur)
            local lw = math.floor((w - 12) * remaining)
            t.life.Position, t.life.Size = Vector2.new(x + 6, y + hh - 3), Vector2.new(lw, 2)
            t.life.Color, t.life.Transparency, t.life.Visible = S.Theme.C1, a, a > 0.01
        elseif t.life then
            t.life.Visible = false
        end
        t.bg.Color, t.ol.Color, t.acc.Color, t.tt.Color = S.Theme.Bg, S.Theme.Track, S.Theme.C1, S.Theme.Text
        for _, o in ipairs(S.toastBase(t)) do
            o.Transparency = (o == t.bg) and a * 0.95 or a
            o.Visible = a > 0.01
        end
        S.glassPanel(t, t.bg, x, y, w, hh, a, 6)
        if glows and S.FX.ok and not t.glow then t.glow = S.FX.newGlow(59) end
        if t.glow then
            if glows then
                S.FX.place(t.glow, x + w / 2, y + hh / 2, w + 70, hh + 60)
                t.glow.Color, t.glow.Transparency = S.Theme.C1, a * 0.28
            end
            t.glow.Visible = glows and a > 0.01
        end
        -- arrival shimmer: one soft light band sweeps across the card (kept clear of the rounded corners)
        local sk = (age - 0.25) / 0.8
        if anim and sk > 0 and sk < 1 then
            if not t.shim then
                t.shim = {}
                for i = 1, math.floor((W - 12) / 8) do
                    t.shim[i] = S.New("Square", { Filled = true, Color = S.Theme.White, Transparency = 0, ZIndex = 61, Visible = false })
                end
            end
            for k, c in ipairs(t.shim) do
                local cx0 = x + 6 + (k - 1) * 8
                local d = (cx0 + 4 - (x - 40 + sk * (w + 80))) / 26
                local va = (cx0 + 8 <= x + w - 6) and 0.10 * math.exp(-d * d) * a or 0
                c.Position, c.Size = Vector2.new(cx0, y + 1), Vector2.new(8, hh - 2)
                c.Transparency, c.Visible = va, va > 0.004
            end
            t.shimmering = true
        elseif t.shimmering then
            for _, c in ipairs(t.shim) do c.Visible = false end
            t.shimmering = false
        end
        -- click a toast to dismiss it early
        if S.In.pressed and age < t.dur and S.inRect(S.In.x, S.In.y, x, y, w, hh) then t.born = now - t.dur end
    end
end

-- ---- dialog: a modal card over the window; blocks clicks to the window until a button is picked ----
S.Dlg = nil
function S.closeDialog()
    local d = S.Dlg
    if not d then return end
    S.Dlg = nil
    for _, o in ipairs(S.dialogObjs(d)) do S.freeObj(o) end
    S.Win.dirty = true
end
function S.dialogObjs(d)
    local o = { d.shade, d.bg, d.ol, d.tt }
    if d.icon then o[#o + 1] = d.icon end
    for _, l in ipairs(d.lines) do o[#o + 1] = l end
    for _, b in ipairs(d.buttons) do o[#o + 1] = b.box o[#o + 1] = b.oline o[#o + 1] = b.lbl end
    return o
end
function S.openDialog(o)
    if S.Dlg then S.closeDialog() end
    local d = { born = os.clock(), lines = {}, buttons = {}, W = 320,
        shade = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0, ZIndex = 70, Corner = 8, Visible = false }),
        bg    = S.New("Square", { Filled = true, Color = S.Theme.Panel, Transparency = 0, ZIndex = 71, Corner = 8, Visible = false }),
        ol    = S.New("Square", { Filled = false, Color = S.Theme.C1, Transparency = 0, ZIndex = 72, Corner = 8, Visible = false }),
        tt    = S.New("Text", { Text = S.truncate(tostring(o.Title or ""), 320 - 32), Color = S.Theme.Text, Transparency = 0, ZIndex = 72, Font = 0, Size = S.FS + 2, Visible = false }) }
    local wrapped = S.wrapPx(tostring(o.Content or ""), d.W - 32)
    for i = 1, math.min(6, #wrapped) do
        d.lines[i] = S.New("Text", { Text = wrapped[i], Color = S.Theme.Dim, Transparency = 0, ZIndex = 72, Font = 0, Size = S.FS - 1, Visible = false })
    end
    for i, b in ipairs(o.Buttons or { { Text = "OK" } }) do
        local txt = tostring(b.Text or b.Title or "OK")
        d.buttons[i] = { text = txt, cb = b.Callback, hov = 0, w = math.max(64, #txt * S.CHAR_W + 24),
            box   = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0, ZIndex = 72, Corner = 4, Visible = false }),
            oline = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0, ZIndex = 73, Corner = 4, Visible = false }),
            lbl   = S.New("Text", { Text = txt, Color = S.Theme.Text, Transparency = 0, ZIndex = 73, Font = 0, Size = S.FS, Visible = false }) }
    end
    -- Icon = lucide name (e.g. "alert-triangle"): drawn centred above the title, and the title + text centre under it
    if o.Icon then
        d.iconPx = 28
        d.icon = S.New("Image", { Transparency = 0, ZIndex = 72, Size = Vector2.new(d.iconPx, d.iconPx), Visible = false,
            Color = o.IconColor or Color3.fromRGB(245, 185, 60) })
        d.iconColor = o.IconColor or Color3.fromRGB(245, 185, 60)
        S.loadIcon(tostring(o.Icon), function(data) if S.Dlg == d then d.icon.Data = data end end, nil, d.iconPx)
    end
    d.top = d.icon and (d.iconPx + 10) or 0
    d.H = 54 + d.top + #d.lines * 15 + 44
    S.Dlg = d
    S.Win.dirty = true
end
-- runs right after input is read; eats the click so nothing behind the dialog reacts to it
function S.updateDialog(dt)
    local d = S.Dlg
    if not d then return end
    local show = S.Win.visible
    local s = math.min(1, (os.clock() - d.born) / 0.18)
    s = S.animOn() and s * s * (3 - 2 * s) or 1
    local wx, wy, ww, wh = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    local x = wx + math.floor((ww - d.W) / 2)
    local y = wy + math.floor((wh - d.H) / 2) + math.floor((1 - s) * 12)
    d.shade.Position, d.shade.Size = Vector2.new(wx, wy), Vector2.new(ww, wh)
    d.shade.Transparency, d.shade.Color = 0.55 * s * S.Cfg.opacity, S.Theme.Dark
    d.bg.Position, d.bg.Size, d.bg.Color = Vector2.new(x, y), Vector2.new(d.W, d.H), S.Theme.Panel
    d.ol.Position, d.ol.Size, d.ol.Color = Vector2.new(x, y), Vector2.new(d.W, d.H), S.Theme.C1
    local top = d.top or 0
    if d.icon then
        d.icon.Position, d.icon.Color = Vector2.new(x + math.floor((d.W - d.iconPx) / 2), y + 16), d.iconColor
        local cx = x + math.floor(d.W / 2)
        d.tt.Position, d.tt.Color = Vector2.new(cx - math.floor(S.TW(d.tt) / 2), y + 14 + top), S.Theme.Text
        for i, l in ipairs(d.lines) do
            l.Position = Vector2.new(cx - math.floor(S.TW(l, S.CHAR_W - 1) / 2), y + 26 + top + 15 * i) l.Color = S.Theme.Dim
        end
    else
        d.tt.Position, d.tt.Color = Vector2.new(x + 16, y + 14), S.Theme.Text
        for i, l in ipairs(d.lines) do l.Position = Vector2.new(x + 16, y + 26 + 15 * i) l.Color = S.Theme.Dim end
    end
    local bx = x + d.W - 16
    if d.icon then -- centred layout: buttons centred as a group
        local tw = -8
        for _, b in ipairs(d.buttons) do tw = tw + b.w + 8 end
        bx = x + math.floor((d.W + tw) / 2)
    end
    local by = y + d.H - 16 - 28
    local clicked = nil
    for i = #d.buttons, 1, -1 do
        local b = d.buttons[i]
        bx = bx - b.w
        local hov = S.inRect(S.In.x, S.In.y, bx, by, b.w, 28)
        b.hov = b.hov + ((hov and 1 or 0) - b.hov) * (S.animOn() and (1 - (0.000001 ^ dt)) or 1)
        b.box.Position, b.box.Size = Vector2.new(bx, by), Vector2.new(b.w, 28)
        b.oline.Position, b.oline.Size = Vector2.new(bx, by), Vector2.new(b.w, 28)
        b.box.Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), b.hov)
        b.oline.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, b.hov)
        b.lbl.Position, b.lbl.Color = Vector2.new(bx + math.floor((b.w - S.TW(b.lbl)) / 2), by + math.floor((28 - S.TH(b.lbl)) / 2)), S.Theme.Text
        if hov and S.In.pressed then clicked = b end
        bx = bx - 8
    end
    for _, o in ipairs(S.dialogObjs(d)) do
        if o ~= d.shade then o.Transparency = s * S.Cfg.opacity end
        o.Visible = show
    end
    if show and S.In.pressed then
        S.In.pressed = false -- nothing behind the dialog gets this click
        if clicked then
            S.closeDialog()
            if clicked.cb then pcall(clicked.cb) end
        end
    end
end

-- sub-tab strip at the top of a card; rows made through a sub-tab handle carry row.sub and
-- only show while sec.subSel == row.sub (reuses the showT fade/resize of conditional rows)
function S.addSubTabs(sec, names, tabIdx)
    local row = { kind = "subtabs", names = names, hovT = 0, vis = true, hovTs = {}, h = 30, lbls = {},
        bar = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 34, Corner = 1, Visible = false }),
        base = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 0.6, ZIndex = 33, Visible = false }) }
    for i, n in ipairs(names) do
        row.lbls[i] = S.New("Text", { Text = n, Color = S.Theme.Dim, Transparency = 1, ZIndex = 34, Font = 0, Size = S.FS, Visible = false })
        row.hovTs[i] = 0
    end
    local saved = S.Persisted and type(S.Persisted._subtabs) == "table" and S.Persisted._subtabs[S.tabNameOf(tabIdx) .. "/" .. tostring(sec.title)]
    sec.subSel = names[1]
    for _, n in ipairs(names) do if n == saved then sec.subSel = n end end
    sec.subKey = S.tabNameOf(tabIdx) .. "/" .. tostring(sec.title)
    table.insert(sec.rows, row)
    return row
end

function S.rowObjs(row)
    local t = {}
    for _, key in ipairs({"lbl", "track", "knob", "chip", "chipT", "box", "val", "arr", "sw", "txt", "oline", "bar", "base", "img", "glow"}) do
        if row[key] then table.insert(t, row[key]) end
    end
    if row.segs then for _, s in ipairs(row.segs) do table.insert(t, s) end end
    if row.boxes then for _, b in ipairs(row.boxes) do table.insert(t, b) end end
    if row.olines then for _, b in ipairs(row.olines) do table.insert(t, b) end end
    if row.segsL then for _, b in ipairs(row.segsL) do table.insert(t, b) end end
    if row.segsR then for _, b in ipairs(row.segsR) do table.insert(t, b) end end
    if row.lbls then for _, l in ipairs(row.lbls) do table.insert(t, l) end end
    if row.wlines then for _, l in ipairs(row.wlines) do table.insert(t, l) end end
    if row.shim then for _, l in ipairs(row.shim) do table.insert(t, l) end end
    if row.divs then for _, l in ipairs(row.divs) do table.insert(t, l) end end
    return t
end

function S.setPageVisible(tabIdx, v)
    local page = S.Pages[tabIdx]
    if not page then return end
    -- never show a page while the window is hidden (intro playing / menu closed): Home is built inside CreateWindow,
    -- before the intro hands over, and creating / selecting it drew its text with no window behind it.
    -- S.setVisible(true) shows the active page once the window is up.
    if v and not S.Win.visible then v = false end
    for _, sec in ipairs(page.sections) do
        sec.hdr.Visible = v
        for _, s in ipairs(sec.hsegs) do s.Visible = false end
        sec.panel.Visible = v
        sec.glow.Visible = false
        sec.grip.Visible = false
        S.Scroll.hide(sec.bar)
        sec.sbGeo = nil
        for _, row in ipairs(sec.rows) do
            local rv = v and (row.showT == nil or row.showT > 0.02) -- hidden sub-tab / conditional rows stay hidden
            for _, o in ipairs(S.rowObjs(row)) do o.Visible = rv end
        end
    end
    if not v then S.hardCloseDropdown() S.closePicker() end
end

-- ========== card layout editor ==========
-- S.LayoutEdit (pencil next to the search bar). Cards keep the normal two-column layout; while editing you can drag
-- a card to any spot in either column (the others make room, everything eases into place) and drag its bottom-right
-- grip to make it taller or shorter (fh, panel px; nil = fit the content). The first edit marks the tab page.custom.
-- Saved per tab as "_layout" = { Tab = { {title, side, fh or false}, ... } } in order. Untouched tabs keep the script's layout.
S.LayoutEdit = false
S.Const.CARD_MIN_H = 40

-- apply the saved layout once the tab's card count changes (cards are added after the settings load)
function S.applyLayout(tabIdx, page)
    page.layoutN = #page.sections
    if tabIdx == S.SETTINGS_TAB then return end -- Settings keeps its built-in layout
    local saved = type(S.Persisted._layout) == "table" and S.Persisted._layout[S.tabNameOf(tabIdx)]
    if type(saved) ~= "table" then return end
    -- shortcut: matched by card title, so two cards with the same title in one tab share a slot; use unique titles
    local rank = {}
    for i, e in ipairs(saved) do
        -- earlier test builds saved numbers in [2]; only {title, "left"/"right", fh} is used
        if type(e) == "table" and (e[2] == "left" or e[2] == "right") then
            rank[e[1]] = { i, e[2], type(e[3]) == "number" and e[3] or nil, type(e[4]) == "number" and e[4] or nil }
        end
    end
    if next(rank) == nil then return end
    for _, sec in ipairs(page.sections) do
        local r = rank[tostring(sec.title)]
        if r then sec.side, sec.fh, sec.fw = r[2], r[3], r[4] end
    end
    table.sort(page.sections, function(a, b)
        local ra, rb = rank[tostring(a.title)], rank[tostring(b.title)]
        if ra and rb and ra[1] ~= rb[1] then return ra[1] < rb[1] end
        if (ra == nil) ~= (rb == nil) then return ra ~= nil end -- cards the save doesn't know go last
        return a.ci < b.ci
    end)
    S.syncAll(page)
    page.custom = true
end
function S.resetLayout(tabIdx)
    local page = S.Pages[tabIdx]
    if not page then return end
    for _, sec in ipairs(page.sections) do
        sec.side, sec.fh, sec.fw, sec.scroll, sec.scrollCur, sec.scrollV = sec.side0, nil, nil, 0, 0, 0
    end
    table.sort(page.sections, function(a, b) return a.ci < b.ci end)
    if page.allSections then table.sort(page.allSections, function(a, b) return a.ci < b.ci end) end
    page.custom = false
    if type(S.Persisted._layout) == "table" then S.Persisted._layout[S.tabNameOf(tabIdx)] = nil end
    S.markChanged()
    S.Win.dirty = true
end
-- dragging: the card floats under the mouse. Its column is the side of the content the mouse is on; its spot is
-- decided by which neighbours it covers by half (see below).
function S.moveCard(page, sec)
    local g = page.geo
    if not g then return end
    page.custom = true
    if S.In.x == S.Drag.lastX and S.In.y == S.Drag.lastY then return end
    S.Drag.lastX, S.Drag.lastY = S.In.x, S.In.y
    S.Win.dirty = true
    local fTop = S.In.y - S.Drag.cardOy - g.startY
    local fBot = fTop + (sec.lay and sec.lay.h or 0)
    local side = (S.In.x < g.cx + g.cw / 2) and "left" or "right"
    local idxOf = {}
    for i, s in ipairs(page.sections) do idxOf[s] = i end
    local others = {}
    for _, s in ipairs(page.sections) do if s ~= sec then others[#others + 1] = s end end
    -- swap as soon as the floating card covers half of a neighbour: going up, its top passes their middle;
    -- going down, its bottom does. Into the other column: its middle decides.
    local at = #others + 1
    for i, s in ipairs(others) do
        if s.side == side and s.lay then
            local mid = s.lay.y + (s.lay.h or 0) / 2
            local before
            if side ~= sec.side then before = (fTop + fBot) / 2 < mid
            elseif idxOf[s] < idxOf[sec] then before = fTop < mid
            else before = fBot <= mid end
            if before then at = i break end
        end
    end
    table.insert(others, at, sec)
    local changed = side ~= sec.side
    for i, s in ipairs(others) do if page.sections[i] ~= s then changed = true break end end
    if changed then page.sections, sec.side = others, side S.syncAll(page) end
end
-- lift a card above the others while it's dragged (add = 20), put it back after (add = 0)
S.ZBase = {}
function S.cardZ(sec, add)
    local objs = { sec.panel, sec.glow, sec.hdr, sec.grip, sec.bar.track, sec.bar.thumb }
    if sec.bar.image then objs[#objs + 1] = sec.bar.image end
    for _, o in ipairs(sec.bar.glow) do objs[#objs + 1] = o end
    for _, s in ipairs(sec.hsegs) do objs[#objs + 1] = s end
    for _, row in ipairs(sec.rows) do for _, o in ipairs(S.rowObjs(row)) do objs[#objs + 1] = o end end
    for _, o in ipairs(objs) do
        if S.ZBase[o] == nil then S.ZBase[o] = o.ZIndex end
        o.ZIndex = S.ZBase[o] + add
    end
end
-- grip: height (snaps back to "fit content" within 10 px) and width. Width is fw = share of the content width, so it
-- follows window resizes; it snaps to the normal column width (nil) or full width (1) within 12 px. Wider than a
-- column = the card spans both columns and the other column's cards move below it.
S.Const.CARD_MIN_W = 180
function S.resizeCard(page, sec)
    local g = page.geo
    if not g or not sec.lay then return end
    page.custom = true
    local h = math.max(S.Const.CARD_MIN_H, math.floor(S.In.y - (g.startY + sec.lay.y + 18) + 6))
    local fh = h
    if sec.fitH and math.abs(h - sec.fitH) < 10 then fh = nil end
    -- width from how far the mouse moved since the grab (a right-column card grows leftward once it hits the edge)
    local w = (S.Drag.w0 or sec.lay.w) + S.In.x - (S.Drag.x0 or S.In.x)
    w = math.max(math.min(S.Const.CARD_MIN_W, g.cw), math.min(g.cw, w))
    local fw = w / g.cw
    if math.abs(w - g.colW) < 12 then fw = nil elseif g.cw - w < 12 then fw = 1 end
    if fh ~= sec.fh or fw ~= sec.fw then sec.fh, sec.fw = fh, fw S.Win.dirty = true end
end
do -- self-check: a 600 px content area, 289 px columns; dragging the grip 30 px right from the column width
    local sv = { In = S.In, Drag = S.Drag, dirty = S.Win.dirty }
    local sec = { lay = { y = 0, w = 289 } }
    S.In, S.Drag = { x = 130, y = 100 }, { w0 = 289, x0 = 100 }
    S.resizeCard({ geo = { cw = 600, colW = 289, startY = 0 } }, sec)
    assert(sec.fw and math.abs(sec.fw - 319 / 600) < 1e-6, "resizeCard width")
    S.In.x = 105 S.resizeCard({ geo = { cw = 600, colW = 289, startY = 0 } }, sec)
    assert(sec.fw == nil, "resizeCard snaps to column width")
    S.In.x = 400 S.resizeCard({ geo = { cw = 600, colW = 289, startY = 0 } }, sec)
    assert(sec.fw == 1, "resizeCard snaps to full width")
    S.In, S.Drag, S.Win.dirty = sv.In, sv.Drag, sv.dirty
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
        -- Matcha's loadstring drops a chunk's return values, so hand the table out via a global
        _G.__FALUI_LEGACY = nil
        local ok, chunk = pcall(loadstring, "_G.__FALUI_LEGACY = (function()\n" .. txt .. "\nend)()")
        if ok and chunk then pcall(chunk) end
        local d = _G.__FALUI_LEGACY
        _G.__FALUI_LEGACY = nil
        return type(d) == "table" and d or nil
    end
    return S.jsonParse(txt)
end

function S.flagValue(row)
    if row.kind == "color" then
        local c = row.color
        if row.hasAlpha then return { c.R, c.G, c.B, row.alpha or 1 } end
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
S.THEME_KEYS = { "Dark", "Bg", "Panel", "PanelHov", "Control", "Track", "Header", "C1", "C2", "Text", "Dim" }
-- UI appearance is saved globally and script settings are saved per script.
--   "ui"     -> LegoSense/ui.json: every Settings-page flag (S.UIFlags), the theme palette, window size / position
--   "script" -> LegoSense/<script>/settings.json and its configs: the script's own flags + per-script UI state
-- S.UIFlags = every flag that exists when the Settings page is built (script tabs come later).
S.UIFlags = {}
S.UI_PATH = S.ROOT .. "/ui.json"
function S.snapshot(scope)
    scope = scope or "script"
    local ui = scope == "ui"
    local t = ui and { w = S.Win.w, h = S.Win.h, x = S.Win.x, y = S.Win.y } or {}
    -- keep saved values for flags this session never created, so autosave doesn't wipe them
    for flag, v in pairs(S.Persisted) do
        if (S.UIFlags[flag] == true) == ui and not (ui and flag:sub(1, 1) == "_") then t[flag] = v end
    end
    for flag, row in pairs(S.FlagRows) do
        if (S.UIFlags[flag] == true) == ui then
            local v = S.flagValue(row)
            if v ~= nil then t[flag] = v end
        end
    end
    if ui then
        local th = {}
        for _, k in ipairs(S.THEME_KEYS) do local c = S.Theme[k] th[k] = { c.R, c.G, c.B } end
        t.theme = th
        -- built-in overlays (keybinds, watermark) belong to the look, not to one script: their spots live here
        local ov = {}
        for _, o in ipairs(S.Overlays) do if o.builtin then ov[o.id] = { o.x, o.y } end end
        t._uiOverlays = ov
    else
        S.uiStateSnapshot(t)
        t._savedAt = os.time()
    end
    return S.jsonEnc(t)
end

function S.applyRow(row, v)
    if row.kind == "progress" and type(v) == "number" then
        row.value = v
    elseif row.kind == "toggle" and type(v) == "boolean" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "slider" and type(v) == "number" then
        row.value = math.max(row.min, math.min(row.max, v))
        if row.onChange then pcall(row.onChange, row.value) end
    elseif row.kind == "dropdown" and (type(v) == "table") == (row.multi == true) then
        row.value = row.multi and table.clone(v) or v
        if row.onChange then pcall(row.onChange, row.value) end
    elseif row.kind == "color" and type(v) == "table" and v[1] then
        -- accept 0-1 floats (current) or legacy 0-255 ints
        local r, g, b = v[1], v[2] or 0, v[3] or 0
        if r <= 1 and g <= 1 and b <= 1 then r, g, b = r * 255, g * 255, b * 255 end
        row.color = S.C3(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
        if row.hasAlpha and type(v[4]) == "number" then row.alpha = math.clamp(v[4], 0, 1) end
        if row.onChange then pcall(row.onChange, row.color, row.alpha) end
    elseif row.kind == "keybind" and type(v) == "number" then
        row.vk = v
        row.chipT.Text = S.rowKeyName(row)
        if row.onChange then pcall(row.onChange, v) end
    elseif row.kind == "textbox" and type(v) == "string" then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
    end
end

-- flags applied in a fixed order: "preset" first (it retints the theme and overwrites the
-- colour swatches), then the colours (so a saved Custom colour wins), then everything else.
S.LOAD_ORDER = { preset = 1, color1 = 2, color2 = 2 }
-- scope nil = everything (old single-file settings), "script" = only the script's flags (configs never change the
-- look), "ui" = only UI flags + theme + window geometry
function S.loadSnapshot(txt, scope)
    local data = S.jsonDecode(txt)
    if type(data) ~= "table" then return false end
    if scope then
        local keepUI = scope == "ui"
        for flag in pairs(data) do
            local isUI = S.UIFlags[flag] == true or flag == "theme" or flag == "w" or flag == "h" or flag == "x" or flag == "y" or flag == "_uiOverlays"
            if isUI ~= keepUI then data[flag] = nil end
        end
    end
    -- A removed preset becomes a personal palette when one was saved; otherwise use the default.
    if data.preset ~= nil and data.preset ~= "Custom" and not S.Presets[data.preset] then
        data.preset = type(data.theme) == "table" and "Custom" or "Mono"
    end
    -- window geometry
    if type(data.w) == "number" and type(data.h) == "number" then
        S.Win.w = math.max(S.Const.MIN_W, data.w)
        S.Win.h = math.max(S.Const.MIN_H, data.h)
    end
    if type(data.x) == "number" then S.Win.x = data.x end
    if type(data.y) == "number" then S.Win.y = data.y end
    local ordered = {}
    for flag, v in pairs(data) do
        if flag ~= "theme" and flag ~= "w" and flag ~= "h" and flag ~= "x" and flag ~= "y" then S.Persisted[flag] = v end
        if S.FlagRows[flag] then table.insert(ordered, flag) end
    end
    table.sort(ordered, function(a, b)
        return (S.LOAD_ORDER[a] or 9) < (S.LOAD_ORDER[b] or 9)
    end)
    for _, flag in ipairs(ordered) do
        S.applyRow(S.FlagRows[flag], data[flag])
    end
    -- old "Collapse sidebar" toggle -> Sidebar = Collapsed
    if data.sidebarMode == nil and data.collapseSidebar == true and S.FlagRows.sidebarMode then
        S.applyRow(S.FlagRows.sidebarMode, "Collapsed")
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

function S.setPerfMode(on)
    if S.Cfg.perfMode == on then return end
    S.Cfg.perfMode = on
    S.Win.dirty = true
    for _, ov in ipairs(S.Overlays) do ov.dirty = true end
    if on then
        S.Casc, S.CascCards, S.CascSpeed = nil, nil, nil
        S.Sb.holdUntil = nil
        S.Glass.want, UI.themeBlurJob = nil, nil
        for _, panel in pairs(S.GlassP) do panel.want = nil end
        UI.nyanData, UI.nyanData0, UI.nyanApplied = nil, nil, nil
        UI.nyanBlurKey, UI.nyanBlurJob, UI.nyanBlurFrames = nil, nil, nil
        UI.nyanDecoded = nil
        S.hideNyan()
        S.hideSnow()
        S.updateRipples()
    end
    S.markChanged()
end

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

function S.cfgPath(nm) return S.cfgDir() .. "/" .. nm .. ".json" end
function S.cfgRefreshLists(scan)
    local names = S.configList()
    if scan then -- configs dropped into the folder by hand show up too
        local have = {}
        for _, n in ipairs(names) do have[n] = true end
        local ok, list = pcall(listfiles, S.cfgDir())
        if ok and type(list) == "table" then
            for _, f in ipairs(list) do
                local n = tostring(f):match("([^/\\]+)%.json$")
                if n and not have[n] then names[#names + 1] = n have[n] = true end
            end
        end
        for i = #names, 1, -1 do if not isfile(S.cfgPath(names[i])) then table.remove(names, i) end end
        S.writeIndex(names)
    end
    if S.rConfigDrop then S.rConfigDrop.options = names end
    if S.rAutoLoad then
        local o = { "none" }
        for _, n in ipairs(names) do o[#o + 1] = n end
        S.rAutoLoad.options = o
    end
    S.cfgInfo()
    S.Win.dirty = true
end
function S.cfgSaveAs(nm, data, quiet)
    local function write()
        S.ensureCfgDir()
        pcall(writefile, S.cfgPath(nm), data)
        local names = S.configList()
        if not table.find(names, nm) then names[#names + 1] = nm S.writeIndex(names) end
        if S.rConfigDrop then S.rConfigDrop.value = nm end
        S.cfgRefreshLists()
        if not quiet then S.toast("Config saved", nm, 2) end
    end
    if isfile(S.cfgPath(nm)) and not quiet then
        S.confirm("Overwrite " .. nm .. "?", "A config with this name already exists.", write)
    else
        write()
    end
end
function S.cfgSel() local v = S.rConfigDrop and S.rConfigDrop.value return (v and v ~= "" and v ~= "none") and v or nil end
function S.cfgName() local nm = S.rName and tostring(S.rName.value or ""):gsub("[^%w_%-]", "") or "" return #nm > 0 and nm or nil end
function S.cfgInfo()
    if not S.rCfgInfo then return end
    local sel, txt = S.cfgSel(), "No config selected: settings save to this script's default file."
    if sel then
        txt = "Selected: " .. sel
        local ok, data = pcall(function() return S.jsonDecode(readfile(S.cfgPath(sel))) end)
        if ok and type(data) == "table" and tonumber(data._savedAt) then txt = txt .. ". Last saved " .. os.date("%b %d, %H:%M", data._savedAt) end
    end
    S.rCfgInfo.label = txt
    S.Win.dirty = true
end
function S.cfgRename()
    local sel, nm = S.cfgSel(), S.cfgName()
    if not sel or not nm or nm == sel then S.toast("Rename", "Pick a config, type the new name in Name", 3) return end
    if isfile(S.cfgPath(nm)) then S.toast("Rename", nm .. " already exists", 3) return end
    local ok, data = pcall(readfile, S.cfgPath(sel))
    if not ok then return end
    pcall(writefile, S.cfgPath(nm), data)
    pcall(delfile, S.cfgPath(sel))
    local names = S.configList()
    for i, n in ipairs(names) do if n == sel then names[i] = nm end end
    S.writeIndex(names)
    if S.Cfg.autoLoad == sel then S.Cfg.autoLoad = nm S.writeAutoload(nm) if S.rAutoLoad then S.rAutoLoad.value = nm end end
    if S.rConfigDrop then S.rConfigDrop.value = nm end
    S.cfgRefreshLists()
    S.toast("Config renamed", sel .. " -> " .. nm, 2.5)
end
function S.cfgDuplicate()
    local sel, nm = S.cfgSel(), S.cfgName()
    if not sel or not nm or nm == sel then S.toast("Duplicate", "Pick a config, type the copy's name in Name", 3) return end
    local ok, data = pcall(readfile, S.cfgPath(sel))
    if ok then S.cfgSaveAs(nm, data) end
end
function S.cfgExport()
    local sel = S.cfgSel()
    local data = sel and select(2, pcall(readfile, S.cfgPath(sel))) or S.snapshot("script")
    S.homeCopy(data, sel and ("Config " .. sel) or "Current settings")
end
function S.clipRead()
    for _, f in ipairs({ "getclipboard", "readclipboard", "get_clipboard", "fromclipboard" }) do
        local fn = getfenv()[f] or (getgenv and getgenv()[f])
        if type(fn) == "function" then local ok, v = pcall(fn) if ok and type(v) == "string" then return v end end
    end
    return nil
end
function S.cfgImport()
    local nm = S.cfgName()
    if not nm then S.toast("Import", "Type a name for it in Name first", 3) return end
    -- clipboard, or (executors that can't read it, e.g. Potassium) <script folder>/configs/import.json
    local txt = S.clipRead()
    if not txt and isfile(S.cfgDir() .. "/import.json") then txt = readfile(S.cfgDir() .. "/import.json") end
    if not txt then S.toast("Import", "Can't read the clipboard: put the config in " .. S.cfgDir() .. "/import.json", 5) return end
    local data = S.jsonDecode(txt)
    if type(data) ~= "table" then S.toast("Import", "The clipboard doesn't hold a config", 3) return end
    S.cfgSaveAs(nm, txt)
end
-- theme code = the "ui" snapshot without the window geometry
function S.themeCode()
    local data = S.jsonDecode(S.snapshot("ui")) or {}
    data.w, data.h, data.x, data.y = nil, nil, nil, nil
    return S.jsonEnc(data)
end
function S.themeImport()
    -- clipboard, or LegoSense/theme.json where the clipboard can't be read
    local txt = S.clipRead()
    if not txt and isfile(S.ROOT .. "/theme.json") then txt = readfile(S.ROOT .. "/theme.json") end
    if not txt then S.toast("Paste theme", "Can't read the clipboard: put the code in " .. S.ROOT .. "/theme.json", 5) return end
    local data = S.jsonDecode(txt)
    if type(data) ~= "table" or type(data.theme) ~= "table" then S.toast("Paste theme", "The clipboard doesn't hold a theme code", 3) return end
    data.w, data.h, data.x, data.y = nil, nil, nil, nil
    local imageUrl = S.normalizeThemeImageUrl(data.themeImgUrl)
    local confirmImage = imageUrl and imageUrl ~= "" and imageUrl ~= S.normalizeThemeImageUrl(S.Cfg.themeImgUrl)
    if imageUrl == nil or confirmImage then data.themeImgUrl = nil end
    S.loadSnapshot(S.jsonEnc(data), "ui")
    S.applyAlphas()
    S.markChanged()
    S.toast("Theme applied", "From the clipboard", 2)
    if confirmImage then
        local authority = imageUrl:match("^%a+://([^/%?#]+)")
        local host = authority:gsub("^.*@", "")
        host = host:match("^(%[[^%]]+%])") or host:match("^([^:]+)") or host
        S.confirm("Load theme image?", "Load an image from " .. host .. "? This shares your IP address with that host.", function()
            if S.rThemeImgUrl then S.applyRow(S.rThemeImgUrl, imageUrl) end
        end)
    end
end
function S.confirm(title, body, yes)
    S.openDialog({ Title = title, Content = body, Buttons = { { Text = "Yes", Callback = yes }, { Text = "Cancel" } } })
end
function S.resetFlags(ui)
    for flag, row in pairs(S.FlagRows) do
        if (S.UIFlags[flag] == true) == ui and S.Defaults[flag] ~= nil then
            local d = S.Defaults[flag]
            S.applyRow(row, type(d) == "table" and table.clone(d) or d)
        end
    end
    if ui then S.applyAlphas() end
    S.markChanged()
    S.Win.dirty = true
    S.toast("Reset", ui and "UI settings are back to default" or "Script settings are back to default", 2.5)
end
function S.ensureCfgDir()
    S.ensureDir(S.cfgDir())
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
    Blossom = { c1 = S.C3(255, 132, 210), c2 = S.C3(202, 153, 255),
        Dark = S.C3(41, 33, 39), Bg = S.C3(109, 68, 113), Panel = S.C3(107, 82, 99), PanelHov = S.C3(116, 92, 108),
        Control = S.C3(72, 49, 70), Track = S.C3(98, 78, 96), Header = S.C3(255, 132, 210),
        Text = S.C3(255, 200, 241), Dim = S.C3(205, 156, 206) },
    -- Rose tints the glass from Bg and uses lighter card fills to separate them from the window.
    -- PanelHov and Track follow the swatch derivation (+6% and +14% toward white).
    Rose = { c1 = S.C3(255, 128, 200), c2 = S.C3(196, 150, 255),
        Dark = S.C3(30, 20, 32), Bg = S.C3(78, 46, 82), Panel = S.C3(96, 62, 98), PanelHov = S.C3(106, 73, 107),
        Control = S.C3(60, 38, 62), Track = S.C3(87, 68, 89), Header = S.C3(255, 160, 215),
        Text = S.C3(255, 228, 246), Dim = S.C3(214, 170, 210) },
    -- Rainbow uses Mono's light surfaces; the frame loop cycles the accent + sidebar/topbar hue
    Rainbow = { c1 = S.C3(228, 230, 234), c2 = S.C3(176, 180, 188),
        Dark = S.C3(30, 24, 40), Bg = S.C3(34, 35, 38), Panel = S.C3(43, 44, 48), PanelHov = S.C3(52, 53, 58),
        Control = S.C3(54, 55, 60), Track = S.C3(78, 80, 86), Header = S.C3(190, 193, 200) },
    Nyan = { c1 = S.C3(255, 130, 190), c2 = S.C3(130, 195, 255),
        Dark = S.C3(14, 14, 14), Bg = S.C3(26, 26, 26), Panel = S.C3(39, 39, 39), PanelHov = S.C3(49, 49, 49),
        Control = S.C3(55, 55, 55), Track = S.C3(78, 78, 78), Header = S.C3(205, 205, 205),
        Text = S.C3(255, 255, 255), Dim = S.C3(180, 180, 180) },
    Custom = nil,
}

function S.tabNameOf(idx)
    if idx == S.SETTINGS_TAB then return "Settings" end
    return (S.Tabs[idx] and S.Tabs[idx].name) or ("Tab " .. idx)
end
S.SETTINGS_SUBS = { "Theme", "Effects", "Interface", "Overlays", "Configs" }
-- hide every drawing of a card (used for Settings cards on another sub-tab)
function S.hideSection(sec)
    sec.hdr.Visible = false
    for _, s in ipairs(sec.hsegs) do s.Visible = false end
    sec.panel.Visible, sec.glow.Visible, sec.grip.Visible = false, false, false
    S.Scroll.hide(sec.bar)
    sec.sbGeo = nil
    for _, row in ipairs(sec.rows) do for _, o in ipairs(S.rowObjs(row)) do o.Visible = false end end
end
-- page.allSections = every card; page.sections = the ones shown (every loop that walks page.sections - layout,
-- clip, input, hover - then only sees those). A card is shown unless sec.off, and when the page has sub-tabs
-- (page.nav, a full-width bar card) only if sec.psub == page.psel.
function S.syncAll(page) -- page.sections was reordered (layout editor / saved layout): carry the order into allSections
    if not page.allSections then return end
    local vis, i, out = {}, 0, {}
    for _, sec in ipairs(page.sections) do vis[sec] = true end
    for _, sec in ipairs(page.allSections) do
        if vis[sec] then i = i + 1 out[#out + 1] = page.sections[i] else out[#out + 1] = sec end
    end
    page.allSections = out
end
function S.pageFilter(page)
    if not page or not page.allSections then return end
    local list = {}
    for _, sec in ipairs(page.allSections) do
        if not sec.off and (sec.psub == nil or not page.nav or sec.psub == page.psel) then list[#list + 1] = sec
        else S.hideSection(sec) end
    end
    page.sections = list
    if S.Pages[S.activeTab] == page and S.Win.visible then S.setPageVisible(S.activeTab, true) end
    S.Win.dirty = true
end
-- show / hide one card (e.g. Home's Favorites only while there are favorites)
function S.setCardOff(sec, off)
    off = off and true or nil
    if sec.off == off then return end
    sec.off = off
    S.pageFilter(sec.page)
end
-- page-level sub-tab bar: a full-width card on top of the page; its cards carry sec.psub
function S.makePageNav(tabIdx, names, title)
    local nav = S.addSection(tabIdx, title or "", "left")
    nav.span, nav.isNav = true, true
    S.addSubTabs(nav, names, tabIdx)
    local page = S.Pages[tabIdx]
    page.nav, page.psel = nav, nav.subSel
    nav.onSub = function(nm) S.setPageSub(page, nm) end
    return nav
end
function S.setPageSub(page, name)
    page.psel = name
    if page.nav then page.nav.subSel = name end
    for _, sec in ipairs(page.allSections) do if sec.psub == name then sec.ax, sec.ah = nil, nil end end
    page.scrollY, page.scrollCur, page.scrollV, page.momentum = 0, 0, 0, 0
    if S.Drop.open then pcall(S.hardCloseDropdown) end
    if S.Pick.open then pcall(S.closePicker) end
    S.pageFilter(page)
    if S.Win.visible and S.Pages[S.activeTab] == page then S.cascSwitch() end
end
function S.setSettingsSub(name)
    local page = S.Pages[S.SETTINGS_TAB]
    if page then S.setPageSub(page, name) end
end

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
    -- presets may set their own text colours (Blossom, Rose); the others put the default text colours back
    S.Theme.Text = p.Text or S.Const.TEXT_DEFAULT
    S.Theme.Dim = p.Dim or S.Const.DIM_DEFAULT
    S.Win.dirty = true
end
S.Const.TEXT_DEFAULT, S.Const.DIM_DEFAULT = S.C3(219, 225, 211), S.C3(130, 137, 118)

function S.applyAccent(c1, c2)
    S.Theme.C1 = c1
    S.Theme.C2 = c2
    S.Win.dirty = true
end

do
    -- A full-width bar at the top of Settings switches
    -- which cards are in page.sections (S.setSettingsSub); every card carries sec.psub = its sub-tab name.
    S.perfMark("settingsBuildStart")
    local sNav = S.makePageNav(S.SETTINGS_TAB, S.SETTINGS_SUBS, "SETTINGS")
    S.SettingsNav = sNav
    S.SwatchRows = {}
    local function sw(sec, label, key, flag, tip)
        local r = S.addColor(sec, label, S.Theme[key], flag, function(c)
            S.Theme[key] = c
            if key == "Panel" then S.Theme.PanelHov = S.lerpColor(c, S.Theme.White, 0.06) end
            if key == "Control" then S.Theme.Track = S.lerpColor(c, S.Theme.White, 0.14) end
            S.Win.dirty = true S.markChanged()
        end)
        r.tip = tip
        S.SwatchRows[key] = r
        return r
    end
    local function on(flag) return function(v) S.Cfg[flag] = v S.Win.dirty = true S.markChanged() end end
    S.loadYield()
    -- ===== Theme =====
    local sTheme = S.addSection(S.SETTINGS_TAB, "COLOURS", "left")
    sTheme.psub = "Theme"
    S.addDropdown(sTheme, "Preset", { "Matcha", "Midnight", "Ember", "Mono", "Blossom", "Rose", "Violet", "Gold", "Crimson", "Aqua", "Rainbow", "Nyan", "Custom" }, "Mono", "preset", function(v)
        S.Cfg.preset = v
        local p = S.Presets[v]
        if p then
            S.applyPreset(v)
            if S.rColor1 then S.rColor1.color = p.c1 end
            if S.rColor2 then S.rColor2.color = p.c2 end
            -- background swatch and snow colour follow the preset too
            if S.rBg then S.rBg.color = p.Bg end
            S.Cfg.fxColor = p.c1
            if S.rFx then S.rFx.color = p.c1 end
            for k, r in pairs(S.SwatchRows or {}) do r.color = S.Theme[k] end
        end
        S.loadThemeImage(v)
        S.markChanged()
    end).tip = "Pick a look, Rainbow to cycle, or Custom for your own colours"
    S.rColor1 = S.addColor(sTheme, "Color 1", S.BaseC1, "color1", function(c)
        -- only a real change makes it Custom: the saved colour re-applies on load and flipped every themed preset to
        -- Custom (theme image then never loaded on start)
        if S.hexOf(c) ~= S.hexOf(S.Theme.C1) then S.Cfg.preset = "Custom" end
        S.Theme.C1 = c S.Win.dirty = true S.markChanged()
    end)
    S.rColor2 = S.addColor(sTheme, "Color 2", S.BaseC2, "color2", function(c)
        -- only a real change makes it Custom: the saved colour re-applies on load and flipped every themed preset to
        -- Custom (theme image then never loaded on start)
        if S.hexOf(c) ~= S.hexOf(S.Theme.C2) then S.Cfg.preset = "Custom" end
        S.Theme.C2 = c S.Win.dirty = true S.markChanged()
    end)
    local rSpeed = S.addSlider(sTheme, "Rainbow speed", 10, 300, 100, " %", "rainbowSpeed", function(v) S.Cfg.rainbowSpeed = v S.markChanged() end)
    rSpeed.visFn = function() return S.Cfg.preset == "Rainbow" or S.Cfg.preset == "Nyan" end
    rSpeed.showT = rSpeed.visFn() and 1 or 0
    S.rBg = S.addColor(sTheme, "Background", S.Theme.Bg, "bgColor", function(c) S.Theme.Bg = c S.Win.dirty = true S.markChanged() end)
    -- in SwatchRows so a preset change refreshes it (else its stale value was saved and put the old text colour back on load)
    S.SwatchRows = S.SwatchRows or {}
    S.SwatchRows.Text = S.addColor(sTheme, "Text color", S.Theme.Text, "textColor", function(c) S.Theme.Text = c S.Win.dirty = true S.markChanged() end)

    sw(sTheme, "Description text", "Dim", "dimColor", "Greyed-out text: descriptions, values, hints")
    sw(sTheme, "Card titles", "Header", "headerColor")
    local sSurf = S.addSection(S.SETTINGS_TAB, "SURFACES", "left")
    sSurf.psub = "Theme"
    sw(sSurf, "Cards", "Panel", "panelColor")
    sw(sSurf, "Sidebar and top bar", "Dark", "barColor")
    sw(sSurf, "Controls", "Control", "controlColor", "Boxes, slider tracks and switches")
    S.addSlider(sSurf, "Background transparency", 0, 100, 72, " %", "bgAlpha", function(v) S.Cfg.bgAlpha = v S.applyAlphas() S.markChanged() end).tip = "How solid the window background is"
    S.addSlider(sSurf, "Card transparency", 0, 100, 60, " %", "cardAlpha", function(v) S.Cfg.cardAlpha = v S.applyAlphas() S.markChanged() end)
    S.addSlider(sSurf, "Bar transparency", 0, 100, 72, " %", "barAlpha", function(v) S.Cfg.barAlpha = v S.applyAlphas() S.markChanged() end).tip = "Sidebar and top bar"
    local sStyle = S.addSection(S.SETTINGS_TAB, "STYLE", "right")
    sStyle.psub = "Theme"
    local rFont
    rFont = S.addDropdown(sStyle, "Font", S.FontNames, "UI", "font", function(v)
        S.applyFont(v)
        -- a font saved on another executor fell back to UI: show that instead of the missing name
        if rFont and S.Cfg.font ~= v then S.applyRow(rFont, S.Cfg.font) end
        S.markChanged()
    end)
    if rFont.value ~= S.Cfg.font then S.applyRow(rFont, S.Cfg.font) end -- saved value applied during creation
    S.addSlider(sStyle, "Corner radius", 0, 200, 100, " %", "cornerRadius", function(v) S.Cfg.cornerRadius = v S.Win.dirty = true S.markChanged() end)
    S.addSlider(sStyle, "Menu opacity", 30, 100, 100, " %", "opacity", function(v) S.setOpacity(v / 100) S.markChanged() end)
    S.addSlider(sStyle, "UI scale", 75, 160, 115, " %", "uiScale", function(v) S.Cfg.uiScale = v S.setScale(v) S.markChanged() end)
    S.addToggle(sStyle, "Checkbox style", false, "checkbox", function(v) S.Cfg.checkbox = v S.Win.dirty = true S.markChanged() end).tip = "Square checkboxes instead of pills"

    S.addToggle(sStyle, "Theme image", true, "themeImg", on("themeImg")).tip = "Show the theme's picture or your own image"
    S.rThemeImgUrl = S.addTextbox(sStyle, "Image URL", "", "themeImgUrl", function(text)
        local url = S.normalizeThemeImageUrl(text)
        if url == nil then
            if S.rThemeImgUrl then S.rThemeImgUrl.value = S.Cfg.themeImgUrl end
            if UI.created then S.toast("Image URL", "Use a direct http or https image link.", 4) end
            return
        end
        S.Cfg.themeImgUrl = url
        if S.rThemeImgUrl then S.rThemeImgUrl.value = url end
        UI.themeImgApplied, UI.themeBlurKey = nil, nil
        S.loadThemeImage(S.Cfg.preset)
        S.Win.dirty = true
        S.markChanged()
    end)
    S.rThemeImgUrl.finished = true
    S.rThemeImgUrl.value = S.Cfg.themeImgUrl
    S.rThemeImgUrl.tip = "Paste a direct image link and press Enter. Leave blank to use the theme's image. Saved with your UI settings."
    S.addSlider(sStyle, "Theme image opacity", 0, 100, 100, " %", "themeImgA", function(v) S.Cfg.themeImgA = v S.applyAlphas() S.markChanged() end)
    if not S.Env.matcha then
        S.addSlider(sStyle, "Theme image blur", 0, 20, 0, " px", "themeImgBlur", function(v) S.Cfg.themeImgBlur = v S.Win.dirty = true S.markChanged() end).tip = "Blurs the theme's background picture"
    end
    local sShare = S.addSection(S.SETTINGS_TAB, "SHARE", "right")
    sShare.psub = "Theme"
    S.addButtonRow(sShare, {
        { label = "Copy theme", cb = function() S.homeCopy(S.themeCode(), "Theme code (colours, transparency, style)") end },
        { label = "Paste theme", cb = function() S.themeImport() end },
    })
    S.addNote(sShare, "Copy theme puts your look on the clipboard. Paste theme applies one copied from someone else.")
    S.loadYield()
    -- ===== Effects =====
    local sMotion = S.addSection(S.SETTINGS_TAB, "MOTION", "left")
    sMotion.psub = "Effects"
    S.addToggle(sMotion, "Animations", true, "animations", function(v) S.Cfg.animations = v S.markChanged() end)
    S.addToggle(sMotion, "Intro animation", true, "intro", function(v) S.Cfg.intro = v S.markChanged() end).tip = "Loading card before the menu first opens"
    if not S.Env.matcha then S.addButton(sMotion, "Replay intro", function() S.Library:PlayIntro() end) end -- no intro on Matcha
    S.addToggle(sMotion, "Hover effects", true, "hoverFx", function(v) S.Cfg.hoverFx = v S.markChanged() end)
    S.addToggle(sMotion, "Performance mode", false, "perfMode", S.setPerfMode).tip = "Skips the intro and animations, hover FX, ripples, snow, rainbow cycling and animated art, glows, glass and blur, notification effects, and the keybind and watermark overlays."

    S.addSlider(sMotion, "Animation speed", 25, 300, 100, " %", "animSpeed", function(v) S.Cfg.animSpeed = v S.markChanged() end)
    S.addToggle(sMotion, "Cascade on tab switch", true, "cascSwitch", on("cascSwitch")).tip = "Cards rise in one after another when a tab opens"
    S.addToggle(sMotion, "Click ripple", true, "ripples", on("ripples"))
    S.addToggle(sMotion, "Overscroll bounce", true, "overscroll", on("overscroll")).tip = "The stretch and bulge when you scroll past the end"
    local sGlow = S.addSection(S.SETTINGS_TAB, "GLOW", "right")
    sGlow.psub = "Effects"
    S.addToggle(sGlow, "Glows", true, "glows", on("glows")).tip = "Master switch for all glows, including controls, panels, notifications and the intro"
    S.addToggle(sGlow, "Window glow", false, "winGlow", function(v)
        S.Cfg.winGlow = v
        for _, o in ipairs(S.Overlays) do o.dirty = true end -- overlays re-check their glow
        S.markChanged()
    end).tip = "Soft accent glow around the window, every overlay and Spotlight"

    S.addToggle(sGlow, "Scroll glow", true, "scrollGlow", on("scrollGlow"))
    if not S.Env.matcha then
        local sBlur = S.addSection(S.SETTINGS_TAB, "BLUR", "left")
        sBlur.psub = "Effects"
        S.addToggle(sBlur, "Background blur", true, "bgBlur", function(v) S.Cfg.bgBlur = v S.markChanged() end).tip = "Blur the game behind the menu, notifications and Spotlight. Needs Roblox graphics 8+ (it switches itself off below that)"
        S.addSlider(sBlur, "Blur strength", 0, 100, 100, " %", "blurStrength", function(v) S.Cfg.blurStrength = v S.markChanged() end)
        S.addToggle(sBlur, "Window", true, "blurWin", on("blurWin")).tip = "Menu window and intro"
        S.addToggle(sBlur, "Glass", true, "glass", function(v) S.Cfg.glass = v S.Win.dirty = true for _, o in ipairs(S.Overlays) do o.dirty = true end S.markChanged() end).tip = "Frosted glass (grain, top sheen, bright rim) on the menu and every panel: overlays, Spotlight, notifications, tooltips, menus"
        S.addDropdown(sBlur, "Window blur area", { "Window", "Full screen" }, "Window", "blurMode", on("blurMode")).tip = "Full screen: the blur grows from the menu out over the whole game, like Spotlight"
        S.addToggle(sBlur, "Overlays and popups", true, "blurOv", on("blurOv")).tip = "Overlays, notifications, colour picker, right-click menu"
        S.addToggle(sBlur, "Tooltips", true, "blurTips", on("blurTips"))
        S.addToggle(sBlur, "Spotlight", true, "blurSpot", on("blurSpot"))
    end
    local sFx = S.addSection(S.SETTINGS_TAB, "BACKGROUND FX", "right")
    sFx.psub = "Effects"
    S.addDropdown(sFx, "Background FX", { "Off", "Snow" }, S.Cfg.bgFx, "bgFx", function(v) S.Cfg.bgFx = v S.markChanged() end).tip = "Snowflakes drifting inside the menu"
    S.rFx = S.addColor(sFx, "FX colour", S.BaseC1, "fxColor", function(c) S.Cfg.fxColor = c S.markChanged() end)
    S.addSlider(sFx, "Snow amount", 4, S.Const.SNOW_N, S.Const.SNOW_N, "", "snowAmount", function(v) S.Cfg.snowAmount = v S.markChanged() end)
    S.addSlider(sFx, "Snow speed", 25, 300, 100, " %", "snowSpeed", function(v) S.Cfg.snowSpeed = v S.markChanged() end)
    S.loadYield()
    -- ===== Interface =====
    local sMenu = S.addSection(S.SETTINGS_TAB, "MENU", "left")
    sMenu.psub = "Interface"
    S.addKeybind(sMenu, "Menu key", 0x24, "menuKey", function(vk) S.Cfg.menuKey = vk S.markChanged() end)
    -- Auto = opens on hover, Expanded = always open, Collapsed = icons only. The pin beside the sidebar title flips Auto <-> Expanded.
    -- S.Cfg.collapseSidebar stays as the derived "never opens" flag (gear placement reads it); old configs with it on load as Collapsed (S.loadSnapshot)
    S.addDropdown(sMenu, "Sidebar", { "Auto", "Expanded", "Collapsed" }, "Auto", "sidebarMode", function(v)
        S.Cfg.sidebarMode = v
        S.Cfg.collapseSidebar = (v == "Collapsed")
        S.Win.dirty = true
        S.markChanged()
    end).tip = "Auto opens on hover, Expanded stays open, Collapsed shows icons only"
    S.addDropdown(sMenu, "Search", { "Bar", "Off" }, "Bar", "search", function(v) S.Cfg.search = v S.Win.dirty = true S.markChanged() end)
    S.addDropdown(sMenu, "Tab layout", { "Sidebar" }, "Sidebar", "tabLayout", function(v) S.Cfg.tabLayout = v S.markChanged() end)
    S.addToggle(sMenu, "Inline dropdowns", false, "inlineDropdowns", function(v) S.Cfg.inlineDropdowns = v S.markChanged() end).tip = "Coming soon: expand in place instead of popout"
    S.addToggle(sMenu, "Block Roblox input", true, "blockInput", function(v)
        S.Cfg.blockInput = v
        S.setGameInput(not (v and S.Win.visible)) -- apply now if the menu is open
        S.markChanged()
    end).tip = "Stop Matcha's input reaching the game while the menu is open"
    S.addToggle(sMenu, "Anti-AFK", true, "antiAfk", on("antiAfk")).tip = "Stops Roblox kicking you for being idle 20 minutes"
    S.addToggle(sMenu, "Share performance data", true, "perfShare", function(v)
        S.Cfg.perfShare = v
        if S.Perf and S.Perf.consentReady then
            if v then S.perfPrepare() else S.perfCancelPending("disabled") end
        end
        S.Win.dirty = true S.markChanged()
    end).tip = "Share UI frame timing and graphics diagnostics with the LegoSense UI owner through its private sender. Includes your Roblox username, user ID and game. Only sends when the owner configures that sender; diagnostics are also saved locally."

    S.addDropdown(sMenu, "Open on", { "Last used", "Home" }, "Last used", "openTab", function(v) S.Cfg.openTab = v S.markChanged() end).tip = "Which tab shows when the menu loads"
    S.addToggle(sMenu, "Remember window position", false, "rememberPos", on("rememberPos")).tip = "Off: the window always opens centred"
    S.addSlider(sMenu, "Sidebar width", 20, 40, 27, " %", "sbWidth", function(v) S.Cfg.sbWidth = v S.Sb.max = S.sbMax() S.Win.dirty = true S.markChanged() end)
    local sSpot = S.addSection(S.SETTINGS_TAB, "SPOTLIGHT", "right")
    sSpot.psub = "Interface"
    S.addToggle(sSpot, "Spotlight", true, "spotOn", on("spotOn")).tip = "Ctrl + key opens a search over the game"
    -- The key box and keybind overlay both display "Ctrl + Space".
    S.addKeybind(sSpot, "Spotlight key", 0x20, "spotKey", function(vk) S.Cfg.spotKey = vk S.markChanged() end).keyPrefix = "Ctrl + "
    local sScroll = S.addSection(S.SETTINGS_TAB, "SCROLLING", "right")
    sScroll.psub = "Interface"
    S.addSlider(sScroll, "Scroll speed", 25, 300, 100, " %", "scrollSpeed", function(v) S.Cfg.scrollSpeed = v S.markChanged() end)
    S.addToggle(sScroll, "Smooth scrolling", true, "smoothScroll", on("smoothScroll"))
    local sTips = S.addSection(S.SETTINGS_TAB, "TOOLTIPS", "left")
    sTips.psub = "Interface"
    S.addSlider(sTips, "Info tip delay", 0, 2, 0.4, " s", "tipDelay", function(v) S.Cfg.tipDelay = v S.markChanged() end).inc = 0.1
    S.addSlider(sTips, "Full name delay", 0.5, 5, 2.5, " s", "truncDelay", function(v) S.Cfg.truncDelay = v S.markChanged() end).inc = 0.1
    S.loadYield()
    -- ===== Overlays =====
    local sOver = S.addSection(S.SETTINGS_TAB, "OVERLAYS", "left")
    sOver.psub = "Overlays"
    S.addToggle(sOver, "Keybind overlay", false, "keybindOverlay", function(v) S.Cfg.keybindOverlay = v S.markChanged() end).tip = "Shows every keybind; drag it by its title while the menu is open"
    S.addToggle(sOver, "Streamer mode", false, "streamer", function(v) S.Cfg.streamer = v S.Win.dirty = true S.markChanged() end).tip = "Hides your avatar and name, and every player's name the script shows (Library:IsStreamer())"

    S.addToggle(sOver, "Only active keybinds", false, "kbActiveOnly", on("kbActiveOnly")).tip = "Keybind overlay lists only binds that are on"
    S.addToggle(sOver, "Watermark", false, "watermark", on("watermark")).tip = "Small panel with FPS, ping and time"
    S.addSlider(sOver, "Overlay opacity", 20, 100, 100, " %", "ovOpacity", function(v) S.Cfg.ovOpacity = v S.markChanged() end)
    S.addToggle(sOver, "Lock overlay positions", false, "ovLock", on("ovLock")).tip = "Stops overlays being dragged"
    local sNote = S.addSection(S.SETTINGS_TAB, "NOTIFICATIONS", "right")
    sNote.psub = "Overlays"
    S.addSlider(sNote, "Notify time", 1, 15, 5, " s", "notifyTime", function(v) S.Cfg.notifyTime = v S.markChanged() end)
    S.addDropdown(sNote, "Corner", { "Bottom right", "Top right", "Bottom left", "Top left" }, "Bottom right", "notifCorner", function(v) S.Cfg.notifCorner = v S.markChanged() end)
    S.addSlider(sNote, "Max shown", 1, 10, 6, "", "notifMax", function(v) S.Cfg.notifMax = v S.markChanged() end)
    S.loadYield()
    -- ===== Configs (script settings only; the look above is global, in LegoSense/ui.json) =====
    local sCfgS = S.addSection(S.SETTINGS_TAB, "CONFIGS", "left")
    sCfgS.psub = "Configs"
    S.rName = S.addTextbox(sCfgS, "Name", "MyConfig", nil, nil)
    S.addButtonRow(sCfgS, {
        { label = "Save", cb = function()
            local nm = S.rName.value:gsub("[^%w_%-]", "")
            if #nm == 0 then return end
            S.cfgSaveAs(nm, S.snapshot("script"))
        end },
        { label = "Load", cb = function()
            local nm = (S.rConfigDrop and S.rConfigDrop.value) or ""
            if nm ~= "" and nm ~= "none" then
                local path = S.cfgDir() .. "/" .. nm .. ".json"
                if not isfile(path) and isfile(S.cfgDir() .. "/" .. nm .. ".lua") then path = S.cfgDir() .. "/" .. nm .. ".lua" end
                if isfile(path) then
                    local ok, txt = pcall(readfile, path)
                    if ok and txt then S.loadSnapshot(txt, "script") S.toast("Config loaded", nm, 2) end
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
                if S.rConfigDrop then S.rConfigDrop.value = names[1] or "none" end
                if S.Cfg.autoLoad == nm then S.Cfg.autoLoad = "none" S.writeAutoload("none") if S.rAutoLoad then S.rAutoLoad.value = "none" end end
                S.cfgRefreshLists()
            end
        end },
    })
    S.rConfigDrop = S.addDropdown(sCfgS, "Config", S.configList(), "none", nil, function() S.cfgInfo() end)
    S.addToggle(sCfgS, "Auto-save", true, "autoSave", function(v) S.Cfg.autoSave = v S.markChanged() end).tip = "Persist settings to disk automatically"
    local alOpts = { "none" }
    for _, n in ipairs(S.configList()) do table.insert(alOpts, n) end
    S.rAutoLoad = S.addDropdown(sCfgS, "Auto-load", alOpts, "none", nil, function(v) S.Cfg.autoLoad = v S.writeAutoload(v) end)

    S.rCfgInfo = S.addNote(sCfgS, "")
    local sMan = S.addSection(S.SETTINGS_TAB, "MANAGE", "right")
    sMan.psub = "Configs"
    S.addButtonRow(sMan, {
        { label = "Rename", cb = function() S.cfgRename() end },
        { label = "Duplicate", cb = function() S.cfgDuplicate() end },
        { label = "Refresh", cb = function() S.cfgRefreshLists(true) end },
    })
    S.addButtonRow(sMan, {
        { label = "Export", cb = function() S.cfgExport() end },
        { label = "Import", cb = function() S.cfgImport() end },
    })
    S.addNote(sMan, "Rename / Duplicate use the Name box. Export copies the selected config; Import saves the clipboard (or configs/import.json) as Name.")
    local sSys = S.addSection(S.SETTINGS_TAB, "WINDOW", "right")
    sSys.psub = "Configs"
    S.addButton(sSys, "Re-center window", function() S.centerWin() end)
    S.addButton(sSys, "Minimize", function() end)
    S.addButton(sSys, "Unload UI", function() UI.Unload() end)
    S.addButton(sSys, "Reset script settings", function() S.confirm("Reset script settings?", "Every option of this script goes back to its default. The look stays.", function() S.resetFlags(false) end) end)
    S.addButton(sSys, "Reset UI settings", function() S.confirm("Reset UI settings?", "Theme, effects, interface and overlay settings go back to their defaults, for every script.", function() S.resetFlags(true) end) end)
    -- everything made so far is a UI (global) setting; script tabs come later
    for flag in pairs(S.FlagRows) do S.UIFlags[flag] = true end
    S.pageFilter(S.Pages[S.SETTINGS_TAB])
    S.perfMark("settingsBuildEnd")
end

-- effective row height: conditional rows (row.showT) collapse to 0 so the card resizes smoothly
function S.rowEffH(row)
    local t = row.showT
    if t == nil then return row.h end
    t = t * t * (3 - 2 * t)
    return row.h * t
end

-- ========== layout (with scroll + culling) ==========
S.layoutGen = 0
function S.relayoutRaw()
    S.layoutGen = S.layoutGen + 1 -- lets S.clipObj tell "laid out again" from "still the rect I cut"
    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    local sw = math.floor(S.Sb.cur + 0.5)
    local expandT = (S.Sb.cur - S.Const.SB_MIN) / math.max(1, S.Sb.max - S.Const.SB_MIN)
    -- lw = where the topbar + content start: the content always makes room for the sidebar
    local lw = sw

    S.D.main.Position = Vector2.new(x, y)
    S.D.main.Size = Vector2.new(w, h)
    S.D.main.Color = S.Theme.Bg
    S.D.main.Corner = S.CR(8)
    S.glassLayout(x, y, w, h)
    -- topbar tucks well under the opaque sidebar so its rounded-left seam is hidden
    -- topbar butts against the sidebar (no overlap -> no double-transparency darkening)
    S.D.topbar.Position = Vector2.new(x + lw, y)
    S.D.topbar.Size = Vector2.new(w - lw, S.TB)
    S.D.topbar.Corner = S.CR(6)
    S.D.seam.Visible = false
    -- fill the rounded-corner gaps at the sidebar/topbar seam with 1px slivers.
    -- each sliver lands only on pixels the bars round away, so nothing overlaps -> no darkening.
    do
        local seamX = x + lw
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

            if not S.Env.matcha then return end -- off Matcha the bars' inner corners are square (CornerMask): no gap to fill
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
        -- inward corner below the topbar, right of the sidebar (Matcha; elsewhere S.D.fillet draws it)
        local rf = S.CR(8)
        for j = 0, rf - 1 do sliver(seamX, y + S.TB + j, inset(rf, j)) end
        for i = wi + 1, #S.D.wedges do S.D.wedges[i].Visible = false end
    end
    S.D.sidebar.Position = Vector2.new(x, y)
    S.D.sidebar.Size = Vector2.new(sw, h)
    S.D.sidebar.Corner = S.CR(8)

    S.D.sidebar.Color = S.Theme.Dark
    S.D.topbar.Color = S.Theme.Dark
    -- sidebar + topbar (+ the rounded inward corner joining them): a second layer on top of main on purpose, for
    -- their darker shade; the content area stays the one main layer = the intro bg 1:1. Rainbow: 0.9 over its busy bg.
    local openA = ((S.Cfg.preset == "Rainbow") and 0.9 or S.Const.ALPHA_BAR) * S.Cfg.opacity
    S.D.sidebar.Transparency = openA
    S.D.topbar.Transparency = openA
    do -- inward corner (off Matcha): same colour + fade as the bars it joins
        local f, rf = S.D.fillet[1], S.CR(8)
        f.Visible = S.Win.visible and not S.Env.matcha and rf >= 2
        f.Position, f.Size, f.Corner = Vector2.new(x + lw, y + S.TB), Vector2.new(rf, rf), rf
        f.Color, f.Transparency = S.Theme.Dark, openA
    end
    S.D.search.Color = S.Theme.Panel
    S.D.avCirc.Color = S.Theme.Control
    S.D.logo.Color = S.Theme.C1
    S.D.logo.Corner = 2 -- pill ends (half the 4 px height), independent of the corner-radius setting
    S.D.logoTxt.Color = S.Theme.Text
    S.D.logoTxt2.Color = S.Theme.Text
    -- the drawn "ls" mark is retired: the glyph (S.updateGlyph) sits in the logo slot instead
    S.D.logo.Visible, S.D.logoTxt.Visible, S.D.logoTxt2.Visible = false, false, false
    S.D.logoImg.Visible = S.Win.visible and UI.logoLoaded and true or false
    local lf = S.logoFit or { 32, 32 }
    S.D.logoImg.Position = Vector2.new(x + 12 + math.floor((32 - lf[1]) / 2), y + 6 + math.floor((32 - lf[2]) / 2))
    S.D.logoImg.Size = Vector2.new(lf[1], lf[2])
    -- centre the mark in the 32px logo slot; underline spans the word
    local okB, tb = pcall(function() return S.D.logoTxt.TextBounds end)
    local lsW = (okB and tb and tb.X > 0) and math.floor(tb.X + 0.5) or 16
    local lsX = x + 28 - math.floor((lsW + 1) / 2)
    S.D.logoTxt.Position = Vector2.new(lsX, y + 5)
    S.D.logoTxt2.Position = Vector2.new(lsX + 1, y + 5)
    S.D.logo.Size = Vector2.new(lsW + 5, 4) -- 2 px past the word on each side
    S.D.logo.Position = Vector2.new(lsX - 2, y + 33)
    S.D.brand.Position = Vector2.new(x + 52, y + 8)
    S.D.brand.Color = S.Theme.C1
    S.D.brand.Text = expandT > 0.05 and S.truncateB(S.BRAND, sw - 52 - (S.Cfg.collapseSidebar and 8 or 30)) or ""
    S.D.brandSub.Position = Vector2.new(x + 52, y + 28)
    S.D.brandSub.Text = expandT > 0.05 and S.truncate(S.SUBTITLE or S.GameName, sw - 52 - 8) or ""

    -- sidebar dividers: centered fades that grow from the middle as the sidebar opens
    -- shown at every width (collapsed too), so the logo / tabs / footer always read as separate blocks
    local midX = x + sw / 2
    local halfSpan = sw / 2 - 10
    S.layoutFade(S.D.sbDiv1, midX - halfSpan, midX + halfSpan, y + 47, "center", 0.5, S.Win.visible)
    S.layoutFade(S.D.sbDiv2, midX - halfSpan, midX + halfSpan, y + h - 66, "center", 0.5, S.Win.visible)

    local titleName = (S.activeTab == S.SETTINGS_TAB) and "Settings" or S.Tabs[S.activeTab].name
    S.D.title.Position = Vector2.new(x + lw + 16, y + 9)
    S.D.title.Color = S.Theme.Text
    local searchW = (S.Cfg.search == "Bar") and math.min(180, math.max(0, w - lw - 220)) or 0
    S.D.search.Visible = S.Win.visible and searchW > 40
    S.D.searchT.Visible = S.D.search.Visible
    S.D.searchIco.Visible = S.D.search.Visible
    S.D.searchGlow.Visible = S.D.search.Visible and S.glowsOn()
    if searchW > 40 then
        local sX = x + w - 36 - searchW
        S.D.search.Position = Vector2.new(sX, y + 8)
        S.D.search.Size = Vector2.new(searchW, 20)
        S.D.search.Corner = S.CR(8)
        -- faint accent rim around the field, brighter while typing
        if S.D.searchGlow.Visible then
            local sGlowA = math.min(1, 0.14 + (S.Search.active and 0.4 or 0)) * S.Cfg.opacity
            S.D.searchGlow.Position = Vector2.new(sX - 1, y + 7)
            S.D.searchGlow.Size = Vector2.new(searchW + 2, 22)
            S.D.searchGlow.Corner = S.CR(8)
            S.D.searchGlow.Color = S.Theme.C1
            S.D.searchGlow.Transparency = sGlowA
        end
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
    -- layout editor: pencil just left of the search bar (or where the bar would end), "Reset" left of it while editing
    local pX = ((searchW > 40) and (x + w - 36 - searchW) or (x + w - 36)) - 22
    S.D.pencil.Visible = S.Win.visible
    S.D.pencil.Position = Vector2.new(pX, y + 11)
    S.D.pencil.Color = S.LayoutEdit and S.Theme.C1 or S.Theme.Dim
    S.PencilRect = { x = pX - 4, y = y + 6, w = 22, h = 22 }
    S.D.layReset.Visible = S.Win.visible and S.LayoutEdit
    S.D.layReset.Position = Vector2.new(pX - 44, y + 12)
    S.ResetRect = S.LayoutEdit and { x = pX - 48, y = y + 6, w = 42, h = 22 } or nil
    S.D.title.Text = S.truncateB(titleName, w - lw - 16 - 50 - searchW - (S.LayoutEdit and 70 or 26))
    if S.Cfg.preset == "Nyan" and not S.Cfg.perfMode then
        -- Measure after title truncation; reserve the first control's entire hit area, including Reset while editing.
        S.Nyan.left = S.D.title.Position.X + S.TW(S.D.title, S.CHAR_WB) + 12
        S.Nyan.right = (S.ResetRect or S.PencilRect).x - 8
    end
    S.D.close.Position = Vector2.new(x + w - 20, y + 9)
    do
        -- quarter arc in the bottom-right corner, 5 px in from the window edges
        local R = S.Const.GRIP_R
        local ring = S.D.gripRing[1]
        if S.Env.matcha then
            local cx, cy, rr = x + w - 5 - R, y + h - 5 - R, R - 1
            local n = S.Const.GRIP_SEGS
            for i = 1, n do
                local a0, a1 = math.rad((i - 1) * 90 / n), math.rad(i * 90 / n)
                local l = S.D.gripArc[i]
                l.From = Vector2.new(cx + rr * math.cos(a0), cy + rr * math.sin(a0))
                l.To = Vector2.new(cx + rr * math.cos(a1), cy + rr * math.sin(a1))
                l.Visible = S.Win.visible
            end
            ring.Visible = false
        else
            for _, l in ipairs(S.D.gripArc) do l.Visible = false end
            -- a 2R square whose rounded bottom-right corner (radius R) is the arc
            ring.Position, ring.Size, ring.Corner = Vector2.new(x + w - 5 - 2 * R, y + h - 5 - 2 * R), Vector2.new(2 * R, 2 * R), R
            ring.Visible = S.Win.visible
        end
    end

    local iy = S.itemsTop()
    for i, it in ipairs(S.Items) do
        local top = iy + (i - 1) * S.Const.ITEM_H
        local k = S.cascK(i)
        local slide = math.floor((1 - k) * S.Const.CASC.SLIDE + 0.5)
        -- centred on the highlight (top + 2, ITEM_H - 8 tall): 16 px icon on whole pixels, label by its measured height
        local midY = top + 2 + (S.Const.ITEM_H - 8) / 2
        it.icon.Size = Vector2.new(16, 16)
        it.icon.Position = Vector2.new(x + S.Const.SB_MIN / 2 - 8 - slide, math.floor(midY - 8 + 0.5))
        it.label.Position = Vector2.new(x + 52 - slide, math.floor(midY - S.TH(it.label, S.FS + 4) / 2 + 0.5))
        it.icon.Transparency = (S.Bases[it.icon] or 1) * S.Cfg.opacity * k
        it.label.Transparency = (S.Bases[it.label] or 1) * S.Cfg.opacity * k
        it.label.Text = expandT > 0.05 and S.truncateB(S.Tabs[i].name, sw - 52 - 8) or ""
        it.icon.Color = (i == S.activeTab) and S.Theme.C1 or S.Theme.Dim
        it.label.Color = (i == S.activeTab) and S.Theme.White or S.Theme.Dim
    end
    local selShown = S.Win.visible and S.activeTab ~= S.SETTINGS_TAB
    S.D.hiliteEdge.Visible = false
    S.D.hilite.Visible = false -- no panel pill: the accent wash alone is the highlight (Spotlight look)
    -- The active tab's accent wash fades to the right and glides between tabs.
    local selX, selW = x + 6, math.max(8, sw - 12)
    local selY = math.floor(S.itemsTop() + S.hiliteY + 2 + 0.5)
    local selH = S.Const.ITEM_H - 8
    if S.D.hiliteGrad then
        S.D.hiliteGrad.Visible = selShown
        S.D.hiliteGrad.Position, S.D.hiliteGrad.Size = Vector2.new(selX, selY), Vector2.new(selW, selH)
        pcall(function() S.D.hiliteGrad.Rounding = S.CR(6) end)
        S.D.hiliteGrad.Color, S.D.hiliteGrad.Transparency = S.Theme.C1, 0.42 * S.Cfg.opacity
    else
        S.D.hilite.Visible = selShown
        S.D.hilite.Position, S.D.hilite.Size, S.D.hilite.Corner = Vector2.new(selX, selY), Vector2.new(selW, selH), S.CR(6)
        S.D.hilite.Color = S.lerpColor(S.Theme.Panel, S.Theme.C1, 0.25)
    end
    local gap = ((S.activeTab - 1) * S.Const.ITEM_H) - S.hiliteY
    local stretch = math.min(selH - 8, math.abs(gap) * 0.6)
    local dh = 3 + stretch
    local dcy = selY + selH / 2 + (gap > 0 and stretch / 2 or -stretch / 2)
    S.D.hiliteBar.Visible = false
    S.D.hiliteBar.Position = Vector2.new(selX + 6, math.floor(dcy - dh / 2 + 0.5))
    S.D.hiliteBar.Size = Vector2.new(3, math.floor(dh + 0.5))
    S.D.hiliteBar.Corner = 1.5
    S.D.hiliteBar.Color = S.Theme.White
    if S.D.hiliteGlow then S.D.hiliteGlow.Visible = false end

    S.D.avCirc.Position = Vector2.new(x + 28, y + h - 36)
    S.D.avatar.Position = Vector2.new(x + 10, y + h - 54)
    -- streamer mode: no avatar (the empty circle stays) and no name
    S.D.avatar.Visible = S.Win.visible and not S.Cfg.streamer
    local nameAvail = sw - 52 - 34
    S.D.footName.Position = Vector2.new(x + 52, y + h - 46)
    S.D.footName.Color = S.Theme.Text
    S.D.footName.Text = expandT > 0.05 and S.truncateB(S.Cfg.streamer and "Hidden" or S.displayName, nameAvail) or ""
    S.D.footSub.Position = Vector2.new(x + 52, y + h - 30)
    S.D.footSub.Text = expandT > 0.05 and S.truncate(S.Cfg.streamer and "@hidden" or ("@" .. S.playerName), nameAvail) or ""
    do -- pin: shown once the sidebar is mostly open (not in Collapsed mode); click = Auto <-> Expanded
        local pinned = S.Cfg.sidebarMode == "Expanded"
        local show = S.Win.visible and not S.Cfg.collapseSidebar and expandT > 0.6
        local px, py = x + sw - 20, y + 15
        S.PinRect = show and { x = px - 9, y = py - 9, w = 18, h = 18 } or nil
        local hov = show and S.inRect(S.In.x, S.In.y, px - 9, py - 9, 18, 18)
        local col = pinned and S.Theme.C1 or (hov and S.Theme.Text or S.Theme.Dim)
        local a = math.clamp((expandT - 0.6) / 0.4, 0, 1) * S.Cfg.opacity
        S.D.pinHead.Visible, S.D.pinLine.Visible, S.D.pinFill.Visible = show, show, show and pinned
        -- 14 x 12 frame centred on (px, py), divider 5 px in from the left
        S.D.pinHead.Position, S.D.pinHead.Size = Vector2.new(px - 7, py - 6), Vector2.new(14, 12)
        S.D.pinFill.Position, S.D.pinFill.Size = Vector2.new(px - 6, py - 5), Vector2.new(4, 10)
        S.D.pinLine.From, S.D.pinLine.To = Vector2.new(px - 2, py - 5), Vector2.new(px - 2, py + 5)
        S.D.pinHead.Color, S.D.pinLine.Color, S.D.pinFill.Color = col, col, S.Theme.C1
        S.D.pinHead.Transparency, S.D.pinLine.Transparency, S.D.pinFill.Transparency = a, a, a
        if S.D.pinImg then
            S.D.pinHead.Visible, S.D.pinLine.Visible, S.D.pinFill.Visible = false, false, false
            S.D.pinImg.Visible, S.D.pinImgFill.Visible = show, show and pinned
            S.D.pinImg.Position, S.D.pinImgFill.Position = Vector2.new(px - 7, py - 6), Vector2.new(px - 7, py - 6)
            S.D.pinImg.Size, S.D.pinImgFill.Size = Vector2.new(14, 12), Vector2.new(14, 12)
            S.D.pinImg.Color, S.D.pinImgFill.Color = col, S.Theme.C1
            S.D.pinImg.Transparency, S.D.pinImgFill.Transparency = a, a
        end
    end
    -- gear: beside the name, shown once the sidebar is open. With "Collapse sidebar" on the sidebar never
    -- opens, so the gear sits centred above the version label instead (Settings stays reachable).
    do
        local gx, gy
        if S.Cfg.collapseSidebar then
            gx, gy = x + math.floor((sw - 18) / 2), y + h - 112
            S.D.gear.Visible = S.Win.visible
        else
            gx, gy = x + sw - 30, y + h - 44
            S.D.gear.Visible = S.Win.visible and expandT > 0.6
        end
        S.D.gear.Position = Vector2.new(gx, gy)
        local gg = S.D.gearGlow
        if gg then
            local on = S.glowsOn() and S.D.gear.Visible and S.activeTab == S.SETTINGS_TAB
            local ga = on and 0.55 or 0
            S.Bases[gg] = ga
            gg.Visible = on
            gg.Color, gg.Transparency = S.Theme.C1, ga * S.Cfg.opacity
            S.FX.place(gg, gx + 9, gy + 9, 40)
        end
        S.GearRect = { x = gx - 4, y = gy - 4, w = 26, h = 26 }
    end
    S.D.gear.Color = (S.activeTab == S.SETTINGS_TAB) and S.Theme.C1 or S.Theme.Dim
    S.D.verTag.Visible = S.Win.visible
    S.D.verTag.Text = S.VERSION
    S.D.verTag.Position = Vector2.new(x + 14, y + h - 84)
    S.D.verTag.Color = S.Theme.Dim

    local cx = x + lw + S.PAD
    local cw = w - lw - S.PAD * 2 - 8
    -- theme background art: fit inside the content box (sidebar/topbar bounded), true aspect ratio
    do
        local imageKey = S.themeImageKey(S.Cfg.preset)
        local ratio = UI.themeImgRatio[imageKey] or S.Const.IMG_RATIO
        local maxH = h - S.TB - 6
        local maxW = cw
        -- fit within both dimensions preserving aspect -> never stretched, never spills the box
        local artW = maxH * ratio
        local artH = maxH
        if artW > maxW then
            artW = maxW
            artH = maxW / ratio
        end
        artW, artH = math.max(1, math.floor(artW)), math.max(1, math.floor(artH))
        local imgData = UI.themeImg[imageKey]
        local artX = cx + math.floor((cw - artW) / 2)
        local artY = y + S.TB + 2
        -- geometry stored so the crude post-load forcer can re-apply exact rect
        UI.themeImgRect = { x = artX, y = artY, w = artW, h = artH }
        S.D.themeImg.Visible = S.Win.visible and imgData ~= nil and S.Cfg.themeImg ~= false
        -- Size/Position MUST be set before Data or Matcha's Image never decodes on start
        S.D.themeImg.Position = Vector2.new(artX, artY)
        S.D.themeImg.Size = Vector2.new(artW, artH)
        -- only while the window shows: data set during the intro (window hidden) never decoded, and was marked applied
        if imgData and S.Win.visible and UI.themeImgApplied ~= imageKey then
            S.perfBootMark("themeImageApplyStart")
            pcall(function() S.D.themeImg.Data = imgData end)
            UI.themeImgApplied = imageKey
            S.perfBootMark("themeImageApplyEnd")
        end
        -- "Theme image blur" (Settings > Theme): a blurred copy at the image's screen size replaces the sharp one
        local blurPx = (S.Env.matcha or S.Cfg.perfMode) and 0 or (S.Cfg.themeImgBlur or 0)
        local bKey = imgData and imgData:sub(2, 4) == "PNG" and blurPx > 0 and table.concat({ imageKey, blurPx, S.devPx(artW), S.devPx(artH) }, "|") or nil
        if imgData and S.Win.visible and UI.themeImgApplied == imageKey and UI.themeBlurKey ~= bKey then
            UI.themeBlurKey = bKey
            UI.themeBlurJob = nil
            if not bKey then
                pcall(function() S.D.themeImg.Data = imgData end) -- blur back to 0: the sharp picture
            else
                local job = {}
                UI.themeBlurJob = job
                local function alive()
                    return UI.themeBlurJob == job and UI.themeBlurKey == bKey and not S.Cfg.perfMode and not S.unloaded
                end
                local W, H = S.devPx(artW), S.devPx(artH)
                local radius = blurPx * (S.K or 1) -- scale distances without snapping them to whole device pixels
                -- Keep the previous image until this finishes: a coarse live preview imposes its own minimum blur.
                task.delay(0.2, function() -- slider drag: only the value it settles on is rendered
                    if not alive() then return end
                    S.perfBootMark("themeTgaStart")
                    local data = S.blurImg(imgData, W, H, radius, alive)
                    if data and alive() then pcall(function() S.D.themeImg.Data = data end) end
                    S.perfBootMark("themeTgaEnd")
                end)
            end
        end
        -- nyan background on the Rainbow theme, fit to its real aspect ratio (never stretched)
        local nyan = S.Win.visible and not S.Cfg.perfMode and S.Cfg.themeImg ~= false and S.Cfg.themeImgUrl == "" and S.Cfg.preset == "Rainbow"
        if nyan then S.loadNyan() end
        S.D.nyan.Visible = nyan and UI.nyanData0 ~= nil
        local nW, nH
        if nyan then
            local nRatio = UI.nyanRatio or 1
            local nMaxH = h - S.TB - 6
            nW = math.max(1, math.floor(math.min(nMaxH * nRatio, cw)))
            nH = math.max(1, math.floor(math.min(nMaxH, cw / nRatio)))
            local nX = cx + math.floor((cw - nW) / 2)
            local nY = y + S.TB + 2 + math.floor((nMaxH - nH) / 2)
            UI.nyanRect = { x = nX, y = nY, w = nW, h = nH }
            S.D.nyan.Position = Vector2.new(nX, nY)
            S.D.nyan.Size = Vector2.new(nW, nH)
        end
        S.blurNyan(nW and S.devPx(nW), nH and S.devPx(nH), blurPx)
        if nyan and UI.nyanData0 and not UI.nyanApplied then
            local frames = UI.nyanBlurFrames or UI.nyanData
            local idx = UI.nyanCur or 1
            pcall(function() S.D.nyan.Data = frames[idx] or UI.nyanData0 end)
            UI.nyanApplied, UI.nyanCur = true, idx
        end
    end
    local page = S.Pages[S.activeTab]

    if not page then
        S.D.pageTxt.Position = Vector2.new(cx, y + S.TB + 20)
        S.D.pageTxt.Text = S.truncate(S.Tabs[S.activeTab].name .. " page -- components arrive soon", cw)
        S.Scroll.hide(S.PageBar)
        UI.sbRect = nil
    else
        S.D.pageTxt.Text = ""
        local visTop = y + S.TB + 2
        local visBot = y + h - 6
        local viewH = visBot - visTop
        -- clamp target using last known extent, before laying out
        local preMax = page.maxScroll or 0
        if page.scrollY < 0 then page.scrollY = 0 end
        if page.scrollY > preMax then page.scrollY = preMax end
        local startY = y + S.TB + 16 - page.scrollCur - (page.over or 0)
        local colGap = 22
        local colW = math.floor((cw - colGap) / 2)
        local colX = { left = cx, right = cx + colW + colGap }
        local colY = { left = startY, right = startY }
        if page.layoutN ~= #page.sections then S.applyLayout(S.activeTab, page) end
        -- content width changing (sidebar sliding): cards follow 1:1 so their right edge never pokes past the window
        local cwMoved = page.geo ~= nil and page.geo.cw ~= cw
        page.geo = { cx = cx, cw = cw, colW = colW, colX = colX, startY = startY, visTop = visTop, visBot = visBot }
        -- card motion: every card eases toward its target rect (relative to the content origin, so scrolling and
        -- moving the window never lag); the card under the mouse and window resizes stay 1:1
        local cardK = S.animOn() and (1 - (0.0000005 ^ (S.frameDt or 1 / 60))) or 1

        -- cards start once the sidebar is done moving after the intro (hold + collapse), so they move only once
        if S.Casc and not S.CascCards then
            local held = S.Sb.introHold or (S.Sb.holdUntil and os.clock() < S.Sb.holdUntil)
            if S.Cfg.sidebarMode == "Expanded" or (not held and math.abs(S.Sb.cur - S.Sb.target) < 1) then S.CascCards = os.clock() end
        end
        for ci, sec in ipairs(page.sections) do
            if S.Casc and not S.CascCards then S.cascLive = true sec.inK = 0
            elseif S.CascSpeed and sec.isNav then sec.inK = 1 -- the sub-tab bar you just clicked stays put
            else sec.inK = S.cascK((page.nav and S.CascSpeed) and ci - 1 or ci, S.CascCards) end
            local sx, sy, swid = colX[sec.side] or cx, colY[sec.side] or startY, colW
            -- custom width (fw = share of the content width). Wider than a column: the card spans both, starting below
            -- whatever is already in either column; a right-column card shifts left so it stays inside the content
            if sec.fw and page.custom then swid = math.floor(math.max(math.min(S.Const.CARD_MIN_W, cw), math.min(cw, sec.fw * cw)))
            elseif sec.span then swid = cw end
            local span = swid > colW + 1
            if span then
                sy = math.max(colY.left, colY.right)
                sx = math.min(sx, cx + cw - swid)
            end
            local tsy = sy
            sec.lay = { x = sx - cx, y = sy - startY, w = swid, h = sec.lay and sec.lay.h or 0 }
            -- the card being dragged floats under the mouse; its column spot (kept free above) is where it lands
            if S.Drag.mode == "card" and S.Drag.sec == sec then sx, sy = S.In.x - S.Drag.cardOx, S.In.y - S.Drag.cardOy end
            local instant = sec.ax == nil or cardK >= 1 or cwMoved or S.Drag.sec == sec or S.Drag.mode == "resize"
            if instant then
                sec.ax, sec.ay, sec.aw = sx - cx, sy - startY, swid
            else
                sec.ax = sec.ax + (sx - cx - sec.ax) * cardK
                sec.ay = sec.ay + (sy - startY - sec.ay) * cardK
                sec.aw = sec.aw + (swid - sec.aw) * cardK
                if math.abs(sec.ax - (sx - cx)) + math.abs(sec.ay - (sy - startY)) + math.abs(sec.aw - swid) < 0.6 then
                    sec.ax, sec.ay, sec.aw = sx - cx, sy - startY, swid
                else
                    S.cardAnim = true
                end
            end
            sx, sy, swid = math.floor(cx + sec.ax + 0.5), math.floor(startY + sec.ay + (1 - sec.inK) * (S.CascSpeed or S.Const.CASC).RISE + 0.5), math.floor(sec.aw + 0.5)
            if S.Drag.sec ~= sec then
                sx = math.max(sx, cx)
                swid = math.max(0, math.min(swid, cx + cw - sx))
            end

            local hdrVis = sy >= visTop - 2 and sy <= visBot - 12
            sec.hdr.Visible = S.Win.visible and hdrVis
            sec.hdr.Position = Vector2.new(sx + 2, sy)
            sec.hdr.Color = (S.Drag.sec == sec) and S.Theme.C1 or S.Theme.Header
            sec.hdr.Text = S.truncate(sec.title, swid - 4)
            local hlx = sx + 2 + S.TW(sec.hdr) + 6
            S.layoutFade(sec.hsegs, math.min(hlx, sx + swid), sx + swid, sy + 7, "left", 0.55 * sec.inK, S.Win.visible and hdrVis)

            local py = sy + 18
            local innerX = sx + 12
            local innerW = swid - 24

            -- section collapse: colTs 1=open, 0=collapsed (click the header to toggle). rows and
            -- the panel scale toward the header exactly like the sidebar expand, just vertical.
            local colTs = sec.colT == nil and 1 or sec.colT
            colTs = colTs * colTs * (3 - 2 * colTs)
            sec.headRect = { x = sx, y = sy - 2, w = swid, h = 18 }

            -- notes word-wrap to the card width; rewrap only when the width or text changes
            for _, row in ipairs(sec.rows) do
                local wrapW = row.noteStyle == "newsChange" and innerW - 10 or innerW
                if row.kind == "note" and row.noteStyle ~= "newsDate" and (row.wrapW ~= wrapW or row.wrapSrc ~= row.label) then
                    row.wrapW, row.wrapSrc = wrapW, row.label
                    local lines = S.wrapPx(row.label, wrapW)
                    -- one Text per line so each line clips at the window edge on its own
                    row.wrapLines = lines
                    row.wlines = row.wlines or {}
                    for k = #row.wlines + 1, #lines - 1 do
                        row.wlines[k] = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS - 1, Visible = false })
                    end
                    row.h = (row.noteStyle == "newsChange" and 18 or 24) + (#lines - 1) * 13
                end
            end
            for _, row in ipairs(sec.rows) do
                if row.kind == "discord" then row.bh = math.floor(math.clamp(innerW * 0.5625, 70, 170)) row.h = 4 + row.bh + (row.hx or 94) end
            end
            local rowsSum = 0
            for _, row in ipairs(sec.rows) do rowsSum = rowsSum + S.rowEffH(row) end
            -- custom height (fh): eases like the rect; content taller than the card scrolls inside it (wheel)
            sec.fitH = rowsSum + 6 + (sec.contentPadBottom or 0)
            -- MaxHeight cap (CreateSection{ MaxHeight = n }): card stops growing at n, rest scrolls inside it
            local capH = not (sec.fh and page.custom) and sec.maxH and sec.fitH > sec.maxH and sec.maxH or nil
            local limH = (sec.fh and page.custom) and sec.fh or capH
            sec.limH = limH
            local panelH
            if capH then
                panelH = math.floor(capH * colTs + 0.5)
                sec.ah = panelH
                sec.scroll = math.max(0, math.min(sec.scroll or 0, sec.fitH - capH))
            elseif sec.fh and page.custom then
                local th = sec.fh * colTs
                if sec.ah == nil or cardK >= 1 or S.Drag.sec == sec then sec.ah = th
                else
                    sec.ah = sec.ah + (th - sec.ah) * cardK
                    if math.abs(sec.ah - th) < 0.6 then sec.ah = th else S.cardAnim = true end
                end
                panelH = math.floor(sec.ah + 0.5)
                sec.scroll = math.max(0, math.min(sec.scroll or 0, sec.fitH - sec.fh))
            else
                panelH = sec.fitH * colTs
                sec.ah, sec.scroll = panelH, 0
            end
            local clipCard = limH ~= nil
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
                sec.panel.Transparency = (S.Bases[sec.panel] or S.Const.ALPHA_CARD) * S.Cfg.opacity * sec.inK
                sec.glow.Position = Vector2.new(sx - 1, pTop - 1)
                sec.glow.Size = Vector2.new(swid + 2, pBot - pTop + 2)
                sec.glow.Corner = S.CR(6)
            end
            sec.rect = { x = sx, y = pTop, w = swid, h = math.max(0, pBot - pTop) }
            -- resize grip on the bottom-right corner (width and height)
            local gy = py + panelH - 12
            local gripShown = S.LayoutEdit and S.activeTab ~= S.SETTINGS_TAB and S.Win.visible and gy >= visTop and gy + 10 <= visBot
            sec.grip.Visible = gripShown
            local gx = sx + swid - 12
            sec.gripRect = gripShown and { x = gx - 4, y = gy - 4, w = 18, h = 18 } or nil
            if gripShown then sec.grip.Position = Vector2.new(gx, gy) sec.grip.Color = S.Theme.C1 end
            -- Capped/resized cards use the same Drawing scrollbar as pages and dropdowns.
            local over = clipCard and sec.fitH - limH or 0
            sec.scrollCur = math.clamp(sec.scrollCur or 0, 0, math.max(0, over))
            sec.sbGeo = S.Scroll.layout(sec.bar, sx + swid - 6, py + 6, panelH - 12,
                limH or sec.fitH, sec.fitH, sec.scrollCur, over, S.Win.visible and panelShown,
                pTop, pBot, sec.inK)

            local ry = py + 4 - sec.scrollCur
            local cTop, cBot = py + 2, py + panelH - 3
            for _, row in ipairs(sec.rows) do
                row.cTop, row.cBot = clipCard and cTop or nil, clipCard and cBot or nil
                -- render any row that overlaps the viewport at full opacity; the clip pass
                -- (clipRows, run each frame) trims each object to the exact viewport edge so the
                -- part outside is invisible and the part inside stays crisp, revealed pixel by pixel.
                -- lay out (and keep Visible) a generous margin past the edge so nothing toggles
                -- Visible right at the boundary; clipRows does the exact hide/fade -> no 3px pop.
                local rvis = (ry + row.h > visTop) and (ry < visBot) and (not clipCard or (ry + row.h > cTop + 6 and ry < cBot - 6))
                local shownEnough = (row.showT == nil) or (row.showT > 0.02)
                local rlive = shownEnough and (ry + row.h > visTop - 60) and (ry < visBot + 60)
                row.vis = rvis and shownEnough and colTs > 0.5
                row.live = rlive
                local showSmooth = (row.showT == nil) and 1 or (row.showT * row.showT * (3 - 2 * row.showT))
                row.clipMul = colTs * showSmooth
                row.rect = { x = sx, y = ry, w = swid, h = row.h }
                -- write the cascade-faded alpha here, not full alpha: the executor draws on its own thread and can
                -- show the frame between this write and clipRows' fade = cards flashing solid while a tab cascades in
                local fadeK = row.clipMul * (sec.inK or 1)
                for _, o in ipairs(S.rowObjs(row)) do
                    o.Visible = S.Win.visible and rlive
                    o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * fadeK
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
                        row.chip.Corner = S.CR(4)
                        row.oline.Position, row.oline.Size, row.oline.Corner = Vector2.new(sx + swid - 12 - 52, ry + 4), Vector2.new(52, 17), S.CR(4)
                        row.chipRect = { x = sx + swid - 12 - 52, y = ry + 4, w = 52, h = 17 }
                        -- centred the same way as the per-frame update, or every scroll (re-layout) shoved the
                        -- value right for a frame before the frame loop pulled it back
                        row.chipT.Position = Vector2.new(row.chipRect.x + math.floor((row.chipRect.w - S.TW(row.chipT, S.CHAR_W - 1)) / 2), row.chipRect.y + 2)
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
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - S.TW(row.lbl)) / 2), ry + 4 + math.floor((row.h - 8 - S.TH(row.lbl)) / 2))
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
                            row.lbls[i].Position = Vector2.new(bx + math.floor((bw - S.TW(row.lbls[i])) / 2), ry + 4 + math.floor((row.h - 8 - S.TH(row.lbls[i])) / 2))
                        end
                    elseif row.kind == "tiles" and row.div then
                        local cols = row.cols
                        local cwf = innerW / cols
                        local nr = math.ceil(#row.defs / cols)
                        for i, d in ipairs(row.defs) do
                            local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
                            local bx, bx2 = math.floor(innerX + c * cwf + 0.5), math.floor(innerX + (c + 1) * cwf + 0.5)
                            local by = ry + 4 + rr * row.tileH
                            row.tileRects[i] = { bx, by, bx2 - bx, row.tileH }
                            local b = row.boxes[i]
                            b.Position, b.Size, b.Corner = Vector2.new(bx + 3, by + 3), Vector2.new(bx2 - bx - 6, row.tileH - 6), S.CR(6)
                            local t1, t2 = row.lbls[2 * i - 1], row.lbls[2 * i]
                            t1.Text = S.truncate(d.title or "", bx2 - bx - 20)
                            t2.Text = S.truncate(d.sub or "", math.floor((bx2 - bx - 20) * S.FS / (S.FS + 3)))
                            local h1, h2 = S.TH(t1, S.FS - 2), S.TH(t2, S.FS + 3)
                            local top = by + math.floor((row.tileH - h1 - h2 - 2) / 2 + 0.5)
                            t1.Position = Vector2.new(bx + 10, top)
                            t2.Position = Vector2.new(bx + 10, top + h1 + 2)
                        end
                        local k = 0
                        for rr = 0, nr - 1 do
                            for c = 1, cols - 1 do
                                k = k + 1
                                local o = row.divs[k]
                                o.Position = Vector2.new(math.floor(innerX + c * cwf + 0.5), ry + 4 + rr * row.tileH + 9)
                                o.Size = Vector2.new(1, row.tileH - 18)
                                S.Bases[o] = (rr * cols + c + 1 <= #row.defs) and 0.35 or 0 -- no line next to an empty cell
                            end
                        end
                        for rr = 1, nr - 1 do
                            k = k + 1
                            local o = row.divs[k]
                            o.Position, o.Size = Vector2.new(innerX + 6, ry + 4 + rr * row.tileH), Vector2.new(innerW - 12, 1)
                            S.Bases[o] = 0.35
                        end
                    elseif row.kind == "discord" then
                        S.layoutDiscord(row, innerX, innerW, ry)
                    elseif row.kind == "tiles" then
                        local cols, gap = row.cols, 8
                        local tw = math.floor((innerW - gap * (cols - 1)) / cols)
                        for i, d in ipairs(row.defs) do
                            local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
                            local bx, by = innerX + c * (tw + gap), ry + 4 + rr * (row.tileH + gap)
                            row.tileRects[i] = { bx, by, tw, row.tileH }
                            local b = row.boxes[i]
                            b.Position, b.Size, b.Corner = Vector2.new(bx, by), Vector2.new(tw, row.tileH), S.CR(6)
                            if d.washObj then
                                d.washObj.Position, d.washObj.Size = Vector2.new(bx, by), Vector2.new(tw, row.tileH)
                                pcall(function() d.washObj.Rounding = S.CR(6) end)
                            end
                            local t1, t2 = row.lbls[2 * i - 1], row.lbls[2 * i]
                            t1.Text = S.truncate(d.title or "", tw - 20)
                            t2.Text = S.truncate(d.sub or "", tw - 20)
                            local h1 = S.TH(t1, d.big and (S.FS + 6) or S.FS)
                            local h2 = (d.sub and d.sub ~= "") and S.TH(t2, S.FS - 2) or 0
                            local top = by + math.floor((row.tileH - h1 - (h2 > 0 and h2 + 3 or 0)) / 2 + 0.5)
                            t1.Position = Vector2.new(bx + 11, top)
                            t2.Position = Vector2.new(bx + 11, top + h1 + 3)
                        end
                    elseif row.kind == "hero" then
                        row.img.Position, row.img.Size = Vector2.new(innerX, ry + 4), Vector2.new(56, 56)
                        pcall(function() row.img.Rounding = S.CR(8) end)
                        row.lbl.Text = S.truncate(row.label, innerW - 72)
                        row.val.Text = S.truncate(row.subText, innerW - 72)
                        local h1, h2 = S.TH(row.lbl, S.FS + 6), S.TH(row.val, S.FS - 1)
                        local top = ry + 4 + math.floor((56 - h1 - h2 - 4) / 2 + 0.5)
                        row.lbl.Position = Vector2.new(innerX + 70, top)
                        row.val.Position = Vector2.new(innerX + 70, top + h1 + 4)
                    elseif row.kind == "subtabs" then
                        local n = #row.names
                        local cw2 = innerW / n
                        row.cellW = cw2
                        for i = 1, n do
                            local st = S.truncate(row.names[i], math.floor(cw2) - 6)
                            row.lbls[i].Text = st
                            row.lbls[i].Position = Vector2.new(innerX + math.floor((i - 1) * cw2 + (cw2 - S.TW(row.lbls[i])) / 2), ry + 6)
                        end
                        row.base.Position = Vector2.new(innerX, ry + row.h - 6)
                        row.base.Size = Vector2.new(innerW, 1)
                        local sel = 1
                        for i, nm in ipairs(row.names) do if nm == sec.subSel then sel = i end end
                        row.barTo = (sel - 1) * cw2
                        row.barOff = row.barOff or row.barTo
                        row.bar.Position = Vector2.new(innerX + math.floor(row.barOff + cw2 * 0.2), ry + row.h - 7)
                        row.bar.Size = Vector2.new(math.floor(cw2 * 0.6), 2)
                    elseif row.kind == "dropdown" then
                        row.lbl.Position = Vector2.new(innerX, ry + 10)
                        -- label first: the box takes what the full label leaves (up to 67.5%), never under ~110 px;
                        -- a fixed 67.5% / min 135 cut "Preset" to "Pr.." in a narrow card
                        row.lbl.Text = row.label
                        local lw = S.TW(row.lbl)
                        local boxW = math.floor(math.max(math.min(innerW * 0.675, innerW - lw - 16), math.min(110, innerW * 0.5)))
                        row.boxW = boxW
                        row.lbl.Text = S.truncate(row.label, innerW - boxW - 10)
                        row.box.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.box.Size = Vector2.new(boxW, 22)
                        row.box.Corner = S.CR(4)
                        row.oline.Position = Vector2.new(sx + swid - 12 - boxW, ry + 6)
                        row.oline.Size = Vector2.new(boxW, 22)
                        row.oline.Corner = S.CR(4)
                        row.val.Position = Vector2.new(sx + swid - 12 - boxW + 8, ry + 10)
                        row.val.Text = S.truncate(S.dropText(row), boxW - 28)
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
                        local kw = math.max(34, #S.rowKeyName(row) * S.CHAR_W + 14)
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
                        local tw = S.TW(row.lbl)
                        local mid = innerX + innerW / 2
                        row.lbl.Position = Vector2.new(innerX + math.floor((innerW - tw) / 2), ry + 6)
                        local gap = 8
                        S.layoutFade(row.segsL, innerX, mid - tw / 2 - gap, ry + 12, "right", 0.5, S.Win.visible and rvis)
                        S.layoutFade(row.segsR, mid + tw / 2 + gap, innerX + innerW, ry + 12, "left", 0.5, S.Win.visible and rvis)
                    elseif row.kind == "note" then
                        local news = row.noteStyle == "newsChange"
                        local textX, textY = innerX + (news and 10 or 0), ry + (news and 4 or 5)
                        row.lbl.Position = Vector2.new(textX, textY)
                        row.lbl.Color = news and S.Theme.Text or S.Theme.Dim
                        if row.noteStyle == "newsDate" then
                            local dy = ry + row.newsTop
                            local badgeTextW = row.chip and S.TW(row.chipT, S.CHAR_W - 1) or 0
                            local badgeTextH = row.chip and S.TH(row.chipT, S.FS - 2) or 0
                            local badgeW = row.chip and math.max(36, math.ceil(badgeTextW + 12)) or 0
                            local badgeH = math.max(14, math.ceil(badgeTextH + 4))
                            local timeW = S.TW(row.val, S.CHAR_W - 1)
                            local dateW = #row.newsDate * S.CHAR_W
                            local showTime = row.newsTime ~= "" and dateW + timeW + badgeW + 20 <= innerW
                            row.lbl.Text = S.truncate(row.newsDate, innerW - badgeW - (showTime and timeW + 8 or 8))
                            row.lbl.Position, row.lbl.Color = Vector2.new(innerX, dy), S.Theme.Header
                            row.val.Position = Vector2.new(innerX + #row.lbl.Text * S.CHAR_W + 8, dy + 1)
                            row.val.Color, row.val.Visible = S.Theme.Dim, S.Win.visible and rlive and showTime
                            if row.chip then
                                local bx, by = innerX + innerW - badgeW, dy - 2
                                row.chip.Position, row.chip.Size = Vector2.new(bx, by), Vector2.new(badgeW, badgeH)
                                row.chip.Color = S.Theme.Control
                                row.chipT.Position = Vector2.new(bx + math.floor((badgeW - badgeTextW) / 2 + 0.5), by + math.floor((badgeH - badgeTextH) / 2 + 0.5))
                                row.chipT.Color = S.Theme.Header
                            end
                            if row.base then
                                row.base.Position, row.base.Size = Vector2.new(innerX, ry + 4), Vector2.new(innerW, 1)
                                row.base.Color = S.Theme.Track
                            end
                        elseif row.wrapLines then
                            row.lbl.Text = row.wrapLines[1] or ""
                            for k, wl in ipairs(row.wlines) do
                                wl.Position = Vector2.new(textX, textY + 13 * k)
                                wl.Text = row.wrapLines[k + 1] or ""
                                wl.Color = news and S.Theme.Text or S.Theme.Dim
                                wl.Visible = S.Win.visible and rlive and row.wrapLines[k + 1] ~= nil
                            end
                        else
                            row.lbl.Text = S.truncate(row.label, innerW)
                        end
                        if row.arr then row.arr.Position, row.arr.Color = Vector2.new(innerX, textY), S.Theme.Dim end
                    elseif row.kind == "progress" then
                        row.lbl.Position = Vector2.new(innerX, ry + 5)
                        row.lbl.Text = S.truncate(row.label, innerW - 50)
                        row.barX, row.barY, row.barW = innerX, ry + 25, innerW
                        row.track.Position = Vector2.new(innerX, ry + 25)
                        row.track.Size = Vector2.new(innerW, 5)
                        row.track.Corner = S.CR(2)
                    elseif row.kind == "image" then
                        local ih = row.h - 8
                        local iw = math.min(innerW, row.ratio and math.floor(ih * row.ratio + 0.5) or innerW)
                        if row.ratio and iw < ih * row.ratio then ih = math.floor(iw / row.ratio + 0.5) end
                        row.img.Position = Vector2.new(innerX + math.floor((innerW - iw) / 2), ry + 4)
                        row.img.Size = Vector2.new(iw, ih)
                    end
                end
                ry = ry + S.rowEffH(row) * colTs
            end
            -- next card in the column starts below this card's target spot (not the animated or floating one)
            if capH then
                colY[sec.side] = tsy + 48 + (capH - 6) * colTs
            elseif sec.fh and page.custom then
                colY[sec.side] = tsy + 48 + sec.fh * colTs
            else
                colY[sec.side] = tsy + 48 + (rowsSum + (sec.contentPadBottom or 0)) * colTs
            end
            sec.lay.h = colY[sec.side] - tsy - 30
            if span then colY[sec.side == "left" and "right" or "left"] = colY[sec.side] end -- both columns continue below it
        end

        -- scroll bookkeeping
        local contentH = math.max(colY.left, colY.right) - startY
        page.contentH = contentH
        UI.viewH = viewH
        local maxScroll = math.max(0, contentH - viewH + 14)
        page.maxScroll = maxScroll
        if page.scrollY > maxScroll then page.scrollY = maxScroll end
        if page.scrollY < 0 then page.scrollY = 0 end

        -- Stops above the resize grip; all other scrollbar behavior is shared.
        page.scrollCur = math.clamp(page.scrollCur, 0, maxScroll)
        UI.sbRect = S.Scroll.layout(S.PageBar, x + w - 6, visTop + 2, viewH - 24,
            viewH, contentH, page.scrollCur, contentH > viewH and maxScroll or 0, S.Win.visible)
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
                r.chk.Visible = S.dropHas(row, filtered[idx])
                r.chk.Color = S.Theme.C1
            else
                r.bg.Visible = false
                r.txt.Visible = false
                r.chk.Visible = false
            end
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
        S.Drop.dropSb = S.Scroll.layout(S.Drop.bar, bx + bw - 7, oy + yoff, visN * 24,
            visN, total, S.Drop.scroll, maxSc, S.Win.visible, by + yoff, by + yoff + collapsedH, aT)
        for i = 1, S.Const.MAXOPT do
            applyAnim(S.Drop.rows[i].bg)
            applyAnim(S.Drop.rows[i].txt)
            applyAnim(S.Drop.rows[i].chk)
        end
    end

    if S.Pick.open and S.Pick.open.rect then
        local row = S.Pick.open
        local pw = S.Const.SV_COLS * S.Const.SV_CELL + 24
        local ph = S.Const.SV_ROWS * S.Const.SV_CELL + 24 + 20 + 32 + (row.hasAlpha and 20 or 0)
        local px = row.rect.x + row.rect.w - pw - 4
        local pyy = math.min(row.rect.y + 30, S.Win.y + S.Win.h - ph - 6)
        S.Pick.bg.Position = Vector2.new(px, pyy)
        S.Pick.bg.Size = Vector2.new(pw, ph)
        S.Pick.bg.Corner = S.CR(6)
        S.Pick.bg.Color = S.Theme.Bg
        S.Pick.gx = px + 12
        S.Pick.gy = pyy + 12
        local gridW, gridH = S.Const.SV_COLS * S.Const.SV_CELL, S.Const.SV_ROWS * S.Const.SV_CELL
        S.Pick.hy = S.Pick.gy + gridH + 8
        if S.Pick.useImg then
            for _, o in ipairs({ S.Pick.svBase, S.Pick.svWhite, S.Pick.svBlack }) do
                o.Position, o.Size = Vector2.new(S.Pick.gx, S.Pick.gy), Vector2.new(gridW, gridH)
                pcall(function() o.Rounding = S.CR(4) end)
            end
            S.Pick.svBase.Color = S.hsv2rgb(S.Pick.h, 1, 1)
            if not S.Pick.hueData then -- one 256 x 1 BGR TGA, made on first open
                local ok, d = pcall(function()
                    local W = 256
                    local b = buffer.create(18 + W * 3)
                    buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, W) buffer.writeu16(b, 14, 1)
                    buffer.writeu8(b, 16, 24) buffer.writeu8(b, 17, 0x20)
                    for k = 0, W - 1 do
                        local c = S.hsv2rgb(k / (W - 1), 0.92, 0.95)
                        buffer.writeu8(b, 18 + k * 3, math.floor(c.B * 255 + 0.5))
                        buffer.writeu8(b, 19 + k * 3, math.floor(c.G * 255 + 0.5))
                        buffer.writeu8(b, 20 + k * 3, math.floor(c.R * 255 + 0.5))
                    end
                    return buffer.tostring(b)
                end)
                S.Pick.hueData = ok and d or ""
                if ok then
                    S.Pick.hueImg.Data = d
                else
                    S.perfError("hue", d)
                    print("LEGOSENSE|hue image: " .. tostring(d))
                end
            end
            S.Pick.hueImg.Position, S.Pick.hueImg.Size = Vector2.new(S.Pick.gx, S.Pick.hy), Vector2.new(gridW, 12)
            pcall(function() S.Pick.hueImg.Rounding = 6 end)
        else
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
            local hw = gridW / S.Const.HUE_SEGS
            for k = 1, S.Const.HUE_SEGS do
                local xA = math.floor(S.Pick.gx + (k - 1) * hw)
                local xB = math.floor(S.Pick.gx + k * hw)
                S.Pick.hueSegs[k].Position = Vector2.new(xA, S.Pick.hy)
                S.Pick.hueSegs[k].Size = Vector2.new(math.max(1, xB - xA + 1), 12)
                S.Pick.hueSegs[k].Color = S.hsv2rgb((k - 1) / (S.Const.HUE_SEGS - 1), 0.92, 0.95)
            end
        end
        local cxp, cyp = S.Pick.gx + S.Pick.s * gridW, S.Pick.gy + (1 - S.Pick.v) * gridH
        S.Pick.svCur.Position, S.Pick.svCurO.Position = Vector2.new(cxp, cyp), Vector2.new(cxp, cyp)
        S.Pick.hueCur.Position = Vector2.new(S.Pick.gx + S.Pick.h * gridW - 2, S.Pick.hy - 2)
        S.Pick.hueCur.Size = Vector2.new(4, 16)
        local rowY = S.Pick.hy + 20
        if row.hasAlpha then
            S.Pick.ay = S.Pick.hy + 20
            local aw = gridW / S.Const.ALPHA_SEGS
            local pc = S.pickerColor()
            if S.Pick.useImg then -- picked colour fading in from clear (left) over the control colour
                S.Pick.alphaBack.Position, S.Pick.alphaBack.Size, S.Pick.alphaBack.Corner = Vector2.new(S.Pick.gx, S.Pick.ay), Vector2.new(gridW, 12), 6
                S.Pick.alphaImg.Position, S.Pick.alphaImg.Size = Vector2.new(S.Pick.gx, S.Pick.ay), Vector2.new(gridW, 12)
                pcall(function() S.Pick.alphaImg.Rounding = 6 end)
                S.Pick.alphaImg.Color = pc
            end
            for i = 1, #S.Pick.alphaSegs do
                local xA = math.floor(S.Pick.gx + (i - 1) * aw)
                local xB = math.floor(S.Pick.gx + i * aw)
                S.Pick.alphaSegs[i].Position = Vector2.new(xA, S.Pick.ay)
                S.Pick.alphaSegs[i].Size = Vector2.new(math.max(1, xB - xA + 1), 12)
                S.Pick.alphaSegs[i].Color = S.lerpColor(S.Theme.Panel, pc, (i - 1) / (S.Const.ALPHA_SEGS - 1))
            end
            S.Pick.alphaCur.Position = Vector2.new(S.Pick.gx + S.Pick.a * gridW - 2, S.Pick.ay - 2)
            S.Pick.alphaCur.Size = Vector2.new(4, 16)
            rowY = S.Pick.ay + 20
        end
        S.Pick.prev.Position = Vector2.new(S.Pick.gx, rowY)
        S.Pick.prev.Size = Vector2.new(30, 20)
        S.Pick.prev.Corner = S.CR(3)
        S.Pick.prev.Color = S.pickerColor()
        S.Pick.hexBox.Position = Vector2.new(S.Pick.gx + 38, rowY)
        S.Pick.hexBox.Size = Vector2.new(gridW - 38, 20)
        S.Pick.hexBox.Corner = S.CR(3)
        S.Pick.hexTxt.Position = Vector2.new(S.Pick.gx + 46, rowY + 4)
        S.Pick.hexTxt.Text = S.Pick.hexFocus and (S.Pick.hexBuf .. "_")
            or (S.hexOf(S.pickerColor()) .. (row.hasAlpha and ("   " .. math.floor(S.Pick.a * 100 + 0.5) .. "%") or ""))
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

    -- cascade still running: keep laying out every frame; done: drop it
    if S.Casc then
        if S.cascLive then S.cardAnim = true else S.Casc, S.CascCards, S.CascSpeed = nil, nil, nil end
        S.cascLive = false
    end
    -- a card still easing into place needs the next frame too (setting dirty during the layout would be cleared here)
    S.Win.dirty = S.cardAnim == true
    S.cardAnim = false
end

function S.relayout()
    local P = S.Perf
    local section = P.section
    local phase = P.ph[section and P.framePhase or S.perfPhase(os.clock())]
    phase.relayouts = phase.relayouts + 1
    S.perfSection("relayout")
    local owner = S.drawBegin()
    local ok, e = pcall(S.relayoutRaw)
    if not ok then S.perfError("relayout", e) end
    if S.clipRows then
        S.perfSection("clipRows")
        local clipped, clipError = pcall(S.clipRows)
        if not clipped then
            S.perfError("relayout", clipError)
            if ok then ok, e = false, clipError end
        end
        S.perfSection("relayout")
    end
    local flushed, flushError = pcall(S.drawEnd, owner)
    if not flushed then
        S.perfError("relayout", flushError)
        if ok then ok, e = false, flushError end
    end
    if not ok then print("LEGOSENSE|relayout ERROR: " .. tostring(e)) end
    S.perfSection(section)
end

-- ========== per-frame updates ==========
S.hoveredRow, S.hoverT = nil, 0
S.navHovT, S.navHovIdx = 0, 0
S.animClock = 0

function S.hideTip()
    local T = S.Tip
    T.bg.Visible, T.ol.Visible, T.shown = false, false, false
    for _, l in ipairs(T.lines) do l.Visible = false end
end
-- full text of whatever part of a row is cut short with ".." (label, dropdown value, tile title/sub under the mouse)
function S.truncFull(row, mx, my)
    local function cut(o, full)
        if not o or type(full) ~= "string" or full == "" then return false end
        local ok, t = pcall(function() return o.Text end)
        return ok and type(t) == "string" and t ~= full and t:sub(-2) == ".."
    end
    if cut(row.lbl, row.label) then return row.label end
    if row.kind == "dropdown" and not row.multi and row.value ~= nil and cut(row.val, tostring(row.value)) then return tostring(row.value) end
    if row.kind == "tiles" and row.tileRects then
        for i, r in ipairs(row.tileRects) do
            if S.inRect(mx, my, r[1], r[2], r[3], r[4]) then
                local d, out = row.defs[i], {}
                if cut(row.lbls[2 * i - 1], d.title) then out[#out + 1] = d.title end
                if cut(row.lbls[2 * i], d.sub) then out[#out + 1] = d.sub end
                if #out > 0 then return table.concat(out, " - ") end
            end
        end
    end
    return nil
end
function S.drawTip(title, body, mx, my, dt)
    local T = S.Tip
    local vp = S.vpLogical()
    local maxWidth = math.max(1, math.min(240, vp.X - 28))
    local items = {}
    if title then for _, l in ipairs(S.wrapPx(title, maxWidth, S.FS - 1)) do items[#items + 1] = { l, S.Theme.Text } end end
    if body then for _, l in ipairs(S.wrapPx(body, maxWidth, S.FS - 1)) do items[#items + 1] = { l, title and S.Theme.Dim or S.Theme.Text } end end
    local n = math.min(#items, #T.lines, math.max(1, math.floor((vp.Y - 20) / 14)))
    if n == 0 then S.hideTip() return end
    if #items > n then
        local last = items[n][1]
        while #last > 0 and S.textWidth(last .. "…", S.FS - 1) > maxWidth do
            local chars = S.textChars(last) chars[#chars] = nil last = table.concat(chars)
        end
        items[n][1] = last .. "…"
    end
    local tw = 0
    for i = 1, n do
        local o = T.lines[i]
        o.Text, o.Color = items[i][1], items[i][2]
        tw = math.max(tw, S.TW(o))
    end
    tw = math.min(vp.X - 8, math.ceil(tw + 20))
    local th = n * 14 + 12
    if not T.shown then T.shown, T.t = true, 0 end
    T.t = math.min(1, T.t + dt / 0.16)
    local k = S.animOn() and (1 - (1 - T.t) ^ 3) or 1
    local tx, ty = mx + 14, my + 18
    if tx + tw > vp.X - 4 then tx = mx - tw - 6 end
    if ty + th > vp.Y - 4 then ty = my - th - 8 end
    tx = math.clamp(math.floor(tx + 0.5), 4, math.max(4, vp.X - tw - 4))
    ty = math.clamp(math.floor(ty + (1 - k) * 4 + 0.5), 4, math.max(4, vp.Y - th - 4))
    local a = k * S.Cfg.opacity
    T.bg.Position, T.bg.Size, T.bg.Corner, T.bg.Color = Vector2.new(tx, ty), Vector2.new(tw, th), S.CR(6), S.Theme.Bg
    T.bg.Transparency, T.bg.Visible = 0.88 * a, true
    T.ol.Position, T.ol.Size, T.ol.Corner, T.ol.Color = Vector2.new(tx, ty), Vector2.new(tw, th), S.CR(6), S.Theme.C1
    T.ol.Transparency, T.ol.Visible = 0.22 * a, true
    for i, o in ipairs(T.lines) do
        if i <= n then o.Position, o.Transparency, o.Visible = Vector2.new(tx + 10, ty + 6 + (i - 1) * 14), a, true
        else o.Visible = false end
    end
    S.Blur.rect("tip", tx, ty, tw, th, S.Const.BLUR_INSET_SMALL)
    S.glassPanel("tip", T.bg, tx, ty, tw, th, a, 6)
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

function S.controlGlow(row, alpha, x, y, size)
    if alpha > 0 and not row.glow then row.glow = S.FX.newGlow(34) end
    local g = row.glow
    if not g then return end
    S.Bases[g] = alpha
    g.Visible = alpha > 0
    if alpha > 0 then
        g.Color, g.Transparency = S.Theme.C1, alpha * S.Cfg.opacity
        S.FX.place(g, x, y, size)
    end
end

function S.updateControls(dt, mx, my)
    S.animClock = S.animClock + dt
    local page = S.Pages[S.activeTab]
    local newHovered = nil
    local aeF = S.animOn() and (1 - (0.000001 ^ dt)) or 1
    local glows = S.glowsOn() and S.FX.ok
    local blockRows = S.Drop.open ~= nil or S.Pick.open ~= nil
    local secEase = S.animOn() and (1 - (0.0000001 ^ dt)) or 1
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
                if row.showIf or row.sub or row.visFn or row.hidden ~= nil then
                    row.showT = row.showT or 1
                    local on = (row.showIf == nil or S.Cfg.preset == row.showIf) and (row.sub == nil or sec.subSel == row.sub)
                        and (row.visFn == nil or row.visFn()) and not row.hidden
                    local target = on and 1 or 0
                    if row.showT ~= target then
                        row.showT = row.showT + (target - row.showT) * aeF
                        if math.abs(row.showT - target) < 0.004 then row.showT = target end
                        S.Win.dirty = true
                    end
                end
            end
            local secHov = S.hoverOn() and not blockRows and sec.vis and sec.rect and S.inRect(mx, my, sec.rect.x, sec.rect.y, sec.rect.w, sec.rect.h) and mx > (S.Win.x + S.Sb.cur)
            sec.hovT = sec.hovT + ((secHov and 1 or 0) - sec.hovT) * aeF
            sec.panel.Color = S.lerpColor(S.Theme.Panel, S.Theme.PanelHov, sec.hovT)
            local editing = S.LayoutEdit and S.activeTab ~= S.SETTINGS_TAB
            -- Card outlines appear only in layout-edit mode.
            local glowA = editing and math.min(1, 0.51 + 0.5 * sec.hovT) * S.Cfg.opacity or 0
            sec.glow.Color = S.Theme.C1
            sec.glow.Transparency = glowA * (sec.inK or 1)
            sec.glow.Visible = S.Win.visible and sec.vis and glowA > 0.03
            for _, row in ipairs(sec.rows) do
                -- every drawn row (live = in view or within the 60 px margin) moves its knobs etc. with the layout: rows
                -- scrolled just out of a card kept their old knob spot and floated after a sidebar / window change
                if row.live then
                    local r = row.rect
                    local hov = row.vis and not blockRows and r and S.inRect(mx, my, r.x, r.y, r.w, r.h) and mx > (S.Win.x + S.Sb.cur)
                    local hovTarget = (S.hoverOn() and hov) and 1 or 0
                    row.hovT = row.hovT + (hovTarget - row.hovT) * aeF
                    if hov and (row.tip or S.truncFull(row, mx, my)) then newHovered = row end
                    if row.kind == "toggle" then
                        local target = row.value and 1 or 0
                        row.knobT = row.knobT + (target - row.knobT) * aeF
                        if math.abs(row.knobT - target) < 0.01 then row.knobT = target end
                        local baseTrack = S.lerpColor(S.Theme.Track, S.Theme.C1, row.knobT)
                        local gcx, gcy
                        if S.Cfg.checkbox then
                            row.knob.Position = Vector2.new(row.trackX + 5, row.trackY + 5)
                            row.knob.Visible = S.Win.visible and row.vis and row.knobT > 0.1
                            gcx, gcy = row.trackX + 9, row.trackY + 9
                        else
                            -- goo knob: the head springs to the end (slight overshoot), the tail chases it, and the
                            -- knob is drawn as one capsule spanning both, a little squashed while it's stretched
                            local travel = 34 - 4 - 14
                            local goal = row.value and travel or 0
                            if S.animOn() then
                                row.gH, row.gT = row.gH or goal, row.gT or goal
                                row.gHv = ((row.gHv or 0) + (goal - row.gH) * 900 * dt) * math.exp(-30 * dt)
                                row.gH = row.gH + row.gHv * dt
                                row.gTv = ((row.gTv or 0) + (row.gH - row.gT) * 260 * dt) * math.exp(-20 * dt)
                                row.gT = row.gT + row.gTv * dt
                                if math.abs(row.gH - goal) + math.abs(row.gT - goal) < 0.05 and math.abs(row.gHv) + math.abs(row.gTv) < 1 then
                                    row.gH, row.gT, row.gHv, row.gTv = goal, goal, 0, 0
                                end
                            else
                                row.gH, row.gT, row.gHv, row.gTv = goal, goal, 0, 0
                            end
                            local a = math.clamp(math.min(row.gH, row.gT), -1, travel + 1)
                            local b = math.clamp(math.max(row.gH, row.gT), -1, travel + 1)
                            local sq = math.min(1, (b - a) / 10) * 3
                            row.knob.Visible = S.Win.visible and row.vis
                            row.knob.Position = Vector2.new(row.trackX + 2 + a, row.trackY + 2 + sq / 2)
                            row.knob.Size = Vector2.new(14 + (b - a), 14 - sq)
                            gcx, gcy = row.trackX + 9 + row.gH, row.trackY + 9
                        end
                        S.controlGlow(row, glows and row.knobT * (0.55 + 0.25 * row.hovT) or 0, gcx, gcy, 44)
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
                        local ga = glows and (0.3 + 0.45 * math.max(row.hovT, (S.Drag.mode == "slider" and S.Drag.row == row) and 1 or 0)) or 0
                        S.controlGlow(row, ga, row.barX + fw, row.barY + 1, 36)
                        if S.Focus.row == row then
                            row.chipT.Text = (row.buf or "") .. "_"
                        else
                            row.chipT.Text = S.fmtSlider(row) .. row.suffix
                        end
                        if row.chipRect then
                            row.chipT.Position = Vector2.new(row.chipRect.x + math.floor((row.chipRect.w - S.TW(row.chipT, S.CHAR_W - 1)) / 2), row.chipRect.y + 2)
                        end
                        local typing = S.Focus.row == row
                        row.chip.Color = typing and S.lerpColor(S.Theme.Control, S.Theme.White, 0.08) or S.Theme.Control
                        row.oline.Color = typing and S.Theme.C1 or S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.chipT.Color = S.Theme.Text
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
                            row.hovTs[i] = row.hovTs[i] + (((S.hoverOn() and bHov) and 1 or 0) - row.hovTs[i]) * aeF
                            row.boxes[i].Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), row.hovTs[i])
                            row.olines[i].Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovTs[i])
                            row.lbls[i].Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovTs[i])
                        end
                    elseif row.kind == "discord" then
                        -- The button uses the control fill at rest and adds a Theme.C1 wash and rim on hover.
                        local br = row.btnRects[1]
                        local hov = br and not blockRows and S.inRect(mx, my, br[1], br[2], br[3], br[4])
                        row.hovTs[1] = row.hovTs[1] + (((S.hoverOn() and hov) and 1 or 0) - row.hovTs[1]) * aeF
                        local k = row.hovTs[1]
                        row.boxes[1].Color = S.lerpColor(S.Theme.Control, S.Theme.C1, k)
                        S.Bases[row.boxes[1]] = S.Const.ALPHA_CTRL * (1 - k) + 0.28 * k
                        row.olines[1].Color = S.Theme.C1
                        S.Bases[row.olines[1]] = 0.75 * k
                        row.lbls[3].Color = S.lerpColor(S.Theme.Text, S.Theme.White, k)
                        row.segs[5].Color = row.lbls[3].Color
                        row.lbls[4].Color = S.Theme.Dim
                        row.lbls[1].Color, row.lbls[2].Color = S.Theme.White, S.Theme.Dim
                        row.glow.Color = S.Theme.Panel
                        if not row.banOk then row.img.Color = S.Theme.C1 end
                        if not row.iconOk then row.segs[2].Color = S.Theme.C1 end
                        row.segs[1].Color = S.Theme.Panel
                    elseif row.kind == "tiles" and row.div then
                        for i, d in ipairs(row.defs) do
                            local tr = row.tileRects[i]
                            local hov = d.onClick and tr and not blockRows and S.inRect(mx, my, tr[1], tr[2], tr[3], tr[4])
                            row.hovTs[i] = row.hovTs[i] + (((S.hoverOn() and hov) and 1 or 0) - row.hovTs[i]) * aeF
                            row.boxes[i].Color = S.Theme.C1
                            S.Bases[row.boxes[i]] = d.onClick and (0.07 + 0.13 * row.hovTs[i]) or 0
                            row.lbls[2 * i - 1].Color = S.lerpColor(S.Theme.Dim, S.Theme.Text, row.hovTs[i])
                            row.lbls[2 * i].Color = (d.live or d.on) and S.Theme.C1 or S.lerpColor(S.Theme.Text, S.Theme.White, row.hovTs[i])
                        end
                        for _, o in ipairs(row.divs) do o.Color = S.Theme.Track end
                    elseif row.kind == "tiles" then
                        for i, d in ipairs(row.defs) do
                            local tr = row.tileRects[i]
                            local hov = d.onClick and tr and not blockRows and S.inRect(mx, my, tr[1], tr[2], tr[3], tr[4])
                            row.hovTs[i] = row.hovTs[i] + (((S.hoverOn() and hov) and 1 or 0) - row.hovTs[i]) * aeF
                            row.boxes[i].Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.1), row.hovTs[i])
                            row.lbls[2 * i - 1].Color = S.lerpColor(d.on and S.Theme.White or S.Theme.Text, S.Theme.White, row.hovTs[i])
                            row.lbls[2 * i].Color = d.on and S.Theme.C1 or S.Theme.Dim
                            if d.washObj then d.washObj.Color = S.Theme.C1 end
                        end
                    elseif row.kind == "hero" then
                        row.lbl.Color, row.val.Color = S.Theme.White, S.Theme.Dim
                    elseif row.kind == "subtabs" then
                        local cw2 = row.cellW or 60
                        for i, nm in ipairs(row.names) do
                            local bHov = not blockRows and S.inRect(mx, my, row.rect.x + 12 + (i - 1) * cw2, row.rect.y, cw2, row.h)
                            row.hovTs[i] = row.hovTs[i] + (((S.hoverOn() and bHov) and 1 or 0) - row.hovTs[i]) * aeF
                            local base = (nm == sec.subSel) and S.Theme.C1 or S.Theme.Dim
                            row.lbls[i].Color = S.lerpColor(base, S.Theme.White, row.hovTs[i] * 0.6)
                        end
                        row.bar.Color = S.Theme.C1
                        row.base.Color = S.Theme.Track
                        if row.barTo and row.barOff ~= row.barTo then
                            row.barOff = row.barOff + (row.barTo - row.barOff) * aeF
                            if math.abs(row.barOff - row.barTo) < 0.5 then row.barOff = row.barTo end
                            S.Win.dirty = true
                        end
                    elseif row.kind == "dropdown" then
                        row.box.Color = S.lerpColor(S.Theme.Control, S.lerpColor(S.Theme.Control, S.Theme.White, 0.12), row.hovT)
                        row.oline.Color = S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                    elseif row.kind == "color" then
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                        row.sw.Color = row.color
                        if row.hasAlpha then row.sw.Transparency = math.max(0.15, row.alpha or 1) * S.Cfg.opacity end
                    elseif row.kind == "keybind" then
                        row.lbl.Color = S.lerpColor(S.Theme.Text, S.Theme.White, row.hovT)
                        row.chipT.Text = (S.Capture.row == row) and "..." or S.rowKeyName(row)
                        if row.chipX then
                            row.chipT.Position = Vector2.new(row.chipX + math.floor(((row.kw or 34) - S.TW(row.chipT, S.CHAR_W - 1)) / 2), row.chipY + 2)
                        end
                        row.chip.Color = (S.Capture.row == row) and S.lerpColor(S.Theme.Control, S.Theme.C1, 0.3) or S.Theme.Control
                    elseif row.kind == "textbox" then
                        row.box.Color = (S.Focus.row == row) and S.lerpColor(S.Theme.Control, S.Theme.White, 0.08) or S.Theme.Control
                        row.oline.Color = (S.Focus.row == row) and S.Theme.C1 or S.lerpColor(S.Theme.Track, S.Theme.C1, row.hovT)
                        row.txt.Text = S.truncate(row.value .. ((S.Focus.row == row) and "_" or ""), (row.rect.w - 24 - 16))
                    end
                    if row.kind == "progress" and row.barX then
                        row.shown = row.shown + (row.value - row.shown) * aeF
                        if math.abs(row.shown - row.value) < 0.001 then row.shown = row.value end
                        row.bar.Position = Vector2.new(row.barX, row.barY)
                        row.bar.Size = Vector2.new(math.floor(row.barW * math.clamp(row.shown, 0, 1) + 0.5), 5)
                        row.bar.Visible = S.Win.visible and row.shown > 0.002
                        row.bar.Color, row.bar.Corner, row.track.Color = S.Theme.C1, S.CR(2), S.Theme.Track
                        row.val.Text = math.floor(math.clamp(row.value, 0, 1) * 100 + 0.5) .. "%"
                        row.val.Position = Vector2.new(row.barX + row.barW - S.TW(row.val, S.CHAR_W - 1), row.barY - 20)
                        row.lbl.Color = S.Theme.Text
                        S.fxProgress(row)
                    elseif row.kind == "note" and row.title then
                        row.lbl.Color = S.Theme.Text
                    end
                    if row.disabled and row.lbl then row.lbl.Color = S.Theme.Dim end
                end
            end
        end
    end

    if S.Drop.open and S.Drop.geom then
        local g = S.Drop.geom
        for i = 1, g.visN do
            local hov = S.inRect(mx, my, g.bx + 4, g.oy + (i - 1) * 24, g.bw - 8, 22)
            S.Drop.hovT[i] = S.Drop.hovT[i] + (((S.hoverOn() and hov) and 1 or 0) - S.Drop.hovT[i]) * aeF
            S.Drop.rows[i].bg.Transparency = 0.85 * S.Drop.hovT[i] * S.Cfg.opacity
            S.Drop.rows[i].txt.Color = S.lerpColor(S.Theme.Text, S.Theme.White, S.Drop.hovT[i])
        end
    end

    if S.Search.active and S.Search.geom then
        local g = S.Search.geom
        for i = 1, g.n do
            local r = S.Search.rows[i]
            local hov = S.inRect(mx, my, g.px + 4, g.py + 4 + (i - 1) * g.rowH, g.pw - 8, g.rowH - 2)
            S.Search.hovT[i] = S.Search.hovT[i] + (((S.hoverOn() and hov) and 1 or 0) - S.Search.hovT[i]) * aeF
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
        local want = (hitIdx ~= 0 and hitIdx ~= S.activeTab and S.hoverOn()) and 1 or 0
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
    elseif S.hoveredRow then
        -- Info tips wait 0.4 s. Full-text tips for labels truncated with ".." wait 2.5 s.
        local row = S.hoveredRow
        local full = S.truncFull(row, mx, my)
        S.hoverT = S.hoverT + dt
        if (row.tip or full) and S.hoverT > (row.tip and (S.Cfg.tipDelay or 0.4) or (S.Cfg.truncDelay or 2.5)) then S.drawTip(full, row.tip, mx, my, dt)
        elseif S.Tip.shown then S.hideTip() end
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
    if S.Glass.img then S.Glass.img.Visible = v and S.glassOn() and S.Glass.have == true end
    for idx = 1, S.SETTINGS_TAB do S.setPageVisible(idx, false) end
    if v then S.setPageVisible(S.activeTab, true) end
    S.hardCloseDropdown()
    S.closePicker()
    S.closeSearch()
    S.hideTip()
    -- The frame loop pauses while hidden: clear every pooled scrollbar immediately.
    for _, bar in ipairs(S.Scroll.bars) do S.Scroll.hide(bar) end
    UI.sbRect = nil
    S.Capture.row = nil
    S.Focus.row = nil
    if not v then
        S.hideNyan()
        S.hideSnow()
        S.updateRipples()
    end
    if v then
        S.D.gear.Visible = false
        S.D.verTag.Visible = false
        S.D.search.Visible = false
        S.D.searchT.Visible = false
        S.D.sbTrack.Visible = false
        S.D.sbThumb.Visible = false
        S.hideSbGlow()
        S.D.navHover.Visible = false
        S.Win.dirty = true
    end
    S.setGameInput(not (v and S.Cfg.blockInput))
end

for _, sec in ipairs(S.Pages[S.SETTINGS_TAB].allSections or S.Pages[S.SETTINGS_TAB].sections) do
    for _, row in ipairs(sec.rows) do
        if row.kind == "button" and row.label == "Minimize" then
            row.onClick = function() S.setVisible(false) end
        end
    end
end

function S.switchTab(i)
    if i == S.activeTab then return end
    local drawOwner = S.drawBegin()
    S.setPageVisible(S.activeTab, false)
    S.activeTab = i
    S.cascSwitch()
    S.hideTip()
    S.markChanged()
    -- tab-switch flicker: the executor draws on its own thread, so every write is on screen at once. Lay the page out
    -- at its cascade start (faded, 10 px low) BEFORE showing it, then again after setPageVisible (which re-shows
    -- every row) so off-screen rows are hidden again. Otherwise it flashed solid at its old spot, then jumped.
    S.relayout()
    S.setPageVisible(S.activeTab, true)
    S.relayout()
    S.Win.dirty = true
    S.drawEnd(drawOwner)
    for _, fn in ipairs(S.TabOpenFns[i] or {}) do task.spawn(pcall, fn) end
end
-- Tab:OnOpen(fn): fn runs each time that tab becomes the open tab (and once right away if it already is)
S.TabOpenFns = {}

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


function S.buildSearch()
    S.Search.results = S.findRows(S.Search.buf, S.Const.SEARCH_MAX)
end

-- every searchable control matching q across all tabs, best first (shared by the search bar and Spotlight)
function S.findRows(buf, max)
    local q = buf:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local scored = {}
    if q ~= "" then
        for idx = 1, S.SETTINGS_TAB do
            local page = S.Pages[idx]
            if page then
                for _, sec in ipairs(page.allSections or page.sections) do
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
    local out = {}
    for i = 1, math.min(max, #scored) do out[i] = scored[i] end
    return out
end

function S.gotoResult(res)
    if not res then return end
    S.switchTab(res.tabIdx)
    if res.sec.psub then S.setSettingsSub(res.sec.psub) end
    if res.row.sub then res.sec.subSel = res.row.sub end
    S.Search.focus = res              -- one-shot: scroll the row into view once it's laid out
    S.closeSearch()
    S.Mark.row, S.Mark.t = res.row, 0 -- "it's here" pulse on the row (S.markUpdate)
    S.Win.dirty = true
end
-- found-row marker: accent wash + rim over the row Spotlight / search jumped to, two soft pulses then fade (1.6 s)
S.Mark = { t = 0 }
function S.markUpdate(dt)
    local m = S.Mark
    if not m.row then return end
    if S.Cfg.perfMode then
        if m.fill then m.fill.Visible, m.rim.Visible = false, false end
        m.row = nil
        return
    end
    if not m.fill then
        m.fill = S.New("Square", { Filled = true, Transparency = 0, ZIndex = 36, Visible = false })
        m.rim = S.New("Square", { Filled = false, Thickness = 1, Transparency = 0, ZIndex = 37, Visible = false })
    end
    m.t = m.t + dt
    local r, D = m.row.rect, 1.6
    local top, bot = S.Win.y + S.TB, S.Win.y + S.Win.h
    local y0, y1 = r and math.max(r.y, top), r and math.min(r.y + r.h, bot)
    if m.t >= D or not r or not S.Win.visible or not m.row.vis or y1 - y0 < 4 then
        m.fill.Visible, m.rim.Visible = false, false
        if m.t >= D or not S.Win.visible then m.row = nil end
        return
    end
    local k = math.min(1, m.t / 0.12) * math.min(1, (D - m.t) / 0.5)
    k = k * (0.65 + 0.35 * math.cos(m.t * math.pi * 2.5)) -- pulse
    for _, o in ipairs({ m.fill, m.rim }) do
        o.Position, o.Size, o.Corner, o.Color = Vector2.new(r.x, y0), Vector2.new(r.w, y1 - y0), S.CR(6), S.Theme.C1
        o.Visible = true
    end
    m.fill.Transparency = 0.16 * k * S.Cfg.opacity
    m.rim.Transparency = 0.9 * k * S.Cfg.opacity
end

-- scrollbar glow: lights the thumb itself (same width, same length), brightest at its middle, soft at
-- its ends. One 1px segment per thumb pixel row.
function S.thumbGlow(segs, tp, ts, glowT, img)
    if not S.glowsOn() or S.Cfg.scrollGlow == false or S.Cfg.perfMode then glowT = 0 end
    if img then
        if S.drawClip then S.drawClip(img, tp.Y, tp.Y + ts.Y) end
        for i = 1, #segs do if segs[i].Visible then segs[i].Visible = false end end
        local show = glowT > 0.02
        img.Visible = show
        if show then
            img.Position, img.Size = tp, ts
            img.Color = S.lerpColor(S.Theme.C1, S.lerpColor(S.Theme.C1, S.Theme.White, 0.55), 0.6)
            img.Transparency = glowT * S.Cfg.opacity
        end
        return
    end
    local N = #segs
    local used = math.max(1, math.min(N, math.floor(ts.Y + 0.5)))
    local y0 = math.floor(tp.Y + 0.5)
    local coreC = S.lerpColor(S.Theme.C1, S.Theme.White, 0.55)
    local show = glowT > 0.02
    for i = 1, N do
        local o = segs[i]
        if show and i <= used then
            local a = 1 - math.abs((i - 0.5) / used - 0.5) * 2
            a = a * (2 - a) -- broad bright middle, soft ends
            o.Visible = true
            o.Position = Vector2.new(tp.X, y0 + i - 1)
            o.Size = Vector2.new(math.max(1, ts.X), 1)
            o.Color = S.lerpColor(S.Theme.C1, coreC, a)
            o.Transparency = (0.35 + 0.6 * a) * glowT * S.Cfg.opacity
        else
            o.Visible = false
        end
    end
end

-- resize grip glow: eases from dim to the accent while the corner is hovered or being dragged
function S.updateGrip(dt)
    if not S.Win.visible then return end
    local perf = S.Cfg.perfMode
    if perf and S.gripPerfLayout == S.layoutGen then return end
    S.gripPerfLayout = perf and S.layoutGen or nil
    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    local hot = not perf and (S.Drag.mode == "resize" or S.inRect(S.In.x, S.In.y, x + w - 24, y + h - 24, 26, 26))
    local ease = S.animOn() and (1 - (0.000001 ^ dt)) or 1
    S.gripT = S.gripT + ((hot and 1 or 0) - S.gripT) * ease
    local col = S.lerpColor(S.Theme.Dim, S.Theme.C1, S.gripT)
    local a = (0.35 + 0.65 * S.gripT) * S.Cfg.opacity
    for _, l in ipairs(S.D.gripArc) do l.Color = col l.Transparency = a end
    S.D.gripRing[1].Color, S.D.gripRing[1].Transparency = col, a
end

-- ========== spotlight (Ctrl+Space) ==========
-- Mac-Spotlight-style launcher: a centred search bar over the game, works with the menu closed.
-- Up/Down select, Enter (or click) opens the menu at that control with a pulse on it; Shift+Enter (Shift+click) runs it
-- in place (toggles flip, buttons fire; other controls have nothing to run, so they open the menu too).
-- Motion: open/close fade + slight scale/drop over a dimmed backdrop, panel height eases to fit the
-- results, rows fade in staggered, the selection highlight glides between rows.
S.Spot = { open = false, closing = false, buf = "", sel = 1, results = {}, t = 0, rows = {}, spWas = false,
    h = nil, selY = nil, rowsT = 0, blinkT = 0 }
S.Const.SPOT_W, S.Const.SPOT_MAX = 560, 8
function S.spotInit()
    if S.Spot.bg then return end
    S.perfBootMark("spotlightBuildStart")
    local Z = 90
    S.Spot.dim  = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0, ZIndex = Z - 1, Visible = false })
    -- Drawings can't be blurred (BlurEffect only reaches the 3D world): the open menu gets a frosted veil instead,
    -- its own bg colour laid over it so it sinks back behind the Spotlight
    S.Spot.veil = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = 0, ZIndex = Z - 1, Corner = 8, Visible = false })
    S.Spot.bg   = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = 0, ZIndex = Z, Corner = 14, Visible = false })
    -- The outline is the fallback for the halo.
    S.Spot.ol   = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0, ZIndex = Z + 1, Corner = 14, Visible = false })
    S.Spot.ico  = S.New("Image", { Transparency = 0, ZIndex = Z + 2, Visible = false, Size = Vector2.new(18, 18), Color = S.Theme.Dim })
    S.Spot.txt  = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS + 6, Visible = false })
    S.Spot.div  = S.New("Square", { Filled = true, Color = S.Theme.Track, Transparency = 0, ZIndex = Z + 1, Visible = false })
    -- Selection uses the active tab's accent wash.
    local ramp = S.FX.get and S.FX.get("tabRamp", 256, 2, function(px) return (1 - px / 256) ^ 1.6 end)
    S.Spot.hi   = ramp and S.New("Image", { Data = ramp, Color = S.Theme.C1, Transparency = 0, ZIndex = Z + 1, Visible = false, Size = Vector2.new(1, 1) })
        or S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = Z + 1, Corner = 8, Visible = false })
    S.Spot.empty = S.New("Text", { Text = "No results", Color = S.Theme.Dim, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS, Visible = false })
    S.Spot.hint = S.New("Text", { Text = "Enter go    Shift+Enter run    Esc close", Color = S.Theme.Dim, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS - 2, Visible = false })
    for i = 1, S.Const.SPOT_MAX do
        S.Spot.rows[i] = {
            lbl  = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS + 1, Visible = false }),
            st   = S.New("Text", { Text = "", Color = S.Theme.C1, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS - 1, Visible = false }),
            path = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS - 1, Visible = false }),
        }
    end
    S.loadIcon("search", function(data) pcall(function() S.Spot.ico.Data = data end) end)
    S.perfBootMark("spotlightBuildEnd")
end
function S.spotObjs()
    local o = { S.Spot.dim, S.Spot.veil, S.Spot.bg, S.Spot.ol, S.Spot.ico, S.Spot.txt, S.Spot.div, S.Spot.hi, S.Spot.empty, S.Spot.hint }
    if S.Spot.halo then o[#o + 1] = S.Spot.halo end
    for _, r in ipairs(S.Spot.rows) do o[#o + 1] = r.lbl o[#o + 1] = r.st o[#o + 1] = r.path end
    return o
end
function S.spotSetResults()
    S.Spot.results = S.findRows(S.Spot.buf, S.Const.SPOT_MAX)
    S.Spot.sel = 1
    S.Spot.rowsT = 0 -- restart the row stagger
end
function S.spotOpen()
    S.spotInit()
    S.hardCloseDropdown()
    if S.Pick.open then S.closePicker() end
    if S.Search.active then S.closeSearch() end
    S.Focus.row, S.Capture.row = nil, nil
    S.Spot.open, S.Spot.closing, S.Spot.buf, S.Spot.sel, S.Spot.results = true, false, "", 1, {}
    S.Spot.t, S.Spot.h, S.Spot.selY, S.Spot.rowsT, S.Spot.blinkT = 0, nil, nil, 0, 0
    S.keyStates[0x20] = true -- the Space of Ctrl+Space is still down: don't type it
    S.setGameInput(false)
end
-- starts the close animation; the drawings hide when it finishes (instant with animations off)
function S.spotClose()
    if not S.Spot.open then return end
    S.Spot.open, S.Spot.closing = false, true
    S.setGameInput(not (S.Cfg.blockInput and S.Win.visible))
    if not S.animOn() then S.spotHide() end
end
function S.spotHide()
    S.Spot.closing, S.Spot.t = false, 0
    S.Blur.screen = 0
    if S.Spot.bg then for _, o in ipairs(S.spotObjs()) do o.Visible = false end end
end
-- current value shown next to a result
function S.spotState(row)
    if row.kind == "toggle" then return row.value and "On" or "Off"
    elseif row.kind == "slider" then return S.fmtSlider(row) .. (row.suffix or "")
    elseif row.kind == "dropdown" then return S.dropText(row)
    elseif row.kind == "keybind" then return S.rowKeyName(row)
    elseif row.kind == "color" then return S.hexOf(row.color)
    elseif row.kind == "textbox" then return tostring(row.value or "") end
    return ""
end
function S.spotRun(res, run)
    if not res then return end
    local row = res.row
    S.spotClose()
    if run and row.disabled then return end
    if not run then
        S.setVisible(true)
        S.gotoResult(res)
    elseif row.kind == "toggle" then
        S.Element.new(row):Set(not row.value)
        if row.flag then S.markChanged() end
        S.toast(row.label, row.value and "On" or "Off", 1.5)
    elseif row.kind == "button" then
        if row.onClick then pcall(row.onClick) end
    else
        S.setVisible(true)
        S.gotoResult(res)
    end
end
function S.spotUpdate(dt)
    local sp = S.Cfg.spotOn ~= false and iskeypressed(S.Cfg.spotKey or 0x20)
    local hot = sp and not S.Spot.spWas and iskeypressed(0x11)
    S.Spot.spWas = sp
    if hot then
        if S.Spot.open then S.spotClose() else S.spotOpen() end
        return
    end
    if not S.Spot.open and not S.Spot.closing then return end

    if S.Spot.open then
        if S.edgeKey(0x1B) then S.spotClose() return end
        local n0 = #S.Spot.results
        if S.edgeKey(0x26) then S.Spot.sel = math.max(1, S.Spot.sel - 1) end
        if S.edgeKey(0x28) then S.Spot.sel = math.min(math.max(1, n0), S.Spot.sel + 1) end
        local enter = false
        S.pollTyping(
            function(ch) S.Spot.buf = S.Spot.buf .. ch S.spotSetResults() S.Spot.blinkT = 0 end,
            function() S.Spot.buf = S.Spot.buf:sub(1, -2) S.spotSetResults() S.Spot.blinkT = 0 end,
            function() enter = true end
        )
        if enter then S.spotRun(S.Spot.results[S.Spot.sel], iskeypressed(0x10)) return end
    end

    local okV, vp = pcall(function() return S.vpLogical() end)
    if not okV or not vp then return end
    local anim = S.animOn()
    -- open: 0 -> 1 over 0.2 s (ease-out cubic); close: 1 -> 0 over 0.14 s, then hide
    if S.Cfg.perfMode then
        S.Spot.t = S.Spot.open and 1 or 0
    elseif S.Spot.open then
        S.Spot.t = math.min(1, S.Spot.t + dt / 0.2)
    else
        S.Spot.t = math.max(0, S.Spot.t - dt / 0.14)
    end
    if S.Spot.closing and S.Spot.t <= 0 then S.spotHide() return end
    local s = anim and (1 - (1 - S.Spot.t) ^ 3) or 1
    local ease = anim and (1 - (0.0000005 ^ dt)) or 1
    S.Spot.rowsT = S.Cfg.perfMode and 1 or S.Spot.rowsT + dt
    if not S.Cfg.perfMode then S.Spot.blinkT = S.Spot.blinkT + dt end

    local n = #S.Spot.results
    local typed = #S.Spot.buf > 0
    local headH, rowH = 54, 38
    local listH = (n > 0) and (n * rowH + 14 + 24) or (typed and 44 or 0)
    local targetH = headH + listH
    S.Spot.h = S.Spot.h and (S.Spot.h + (targetH - S.Spot.h) * ease) or targetH
    if math.abs(S.Spot.h - targetH) < 0.5 then S.Spot.h = targetH end
    local H = math.floor(S.Spot.h + 0.5)
    local sc = 0.96 + 0.04 * s
    local W = math.floor(S.Const.SPOT_W * sc + 0.5)
    local x = math.floor((vp.X - W) / 2)
    local y = math.floor(vp.Y * 0.22 - (1 - s) * 14)
    local a = s * S.Cfg.opacity
    local aT = (s ^ 2) * S.Cfg.opacity -- content fades in a touch after the panel

    -- whole screen blur = the same DoF glass as the window (BlurEffect doesn't render on Potassium: probe showed it
    -- Enabled at Size 18 with nothing on screen, so Spotlight was only stacking dim layers). DoF strength is global, so
    -- the blur can't fade: instead the glass grows from the Spotlight panel out to the full screen as it opens.
    S.Blur.screen = 0
    if not S.Cfg.perfMode then
        local k = s
        local gx, gy = x * (1 - k), y * (1 - k)
        local gw, gh = W + (vp.X - W) * k, H + (vp.Y - H) * k
        if s > 0.02 then S.Blur.rect("spot", gx, gy, gw, gh, 0) end
    end
    S.Spot.dim.Visible = not S.Cfg.perfMode
    S.Spot.veil.Visible = S.Spot.dim.Visible and S.Win.visible
    if S.Spot.dim.Visible then
        S.Spot.dim.Position, S.Spot.dim.Size, S.Spot.dim.Color = Vector2.new(0, 0), vp, S.Theme.Dark
        S.Spot.dim.Transparency = 0.12 * a
        S.Spot.veil.Position, S.Spot.veil.Size, S.Spot.veil.Corner = Vector2.new(S.Win.x, S.Win.y), Vector2.new(S.Win.w, S.Win.h), S.CR(8)
        S.Spot.veil.Color, S.Spot.veil.Transparency = S.Theme.Bg, 0.45 * a
    end
    S.Spot.bg.Position, S.Spot.bg.Size, S.Spot.bg.Color = Vector2.new(x, y), Vector2.new(W, H), S.Theme.Bg
    S.Spot.bg.Transparency = S.Const.ALPHA_BG * a
    S.glassPanel("spot", S.Spot.bg, x, y, W, H, a, 14)
    local haloOn = S.FX.ok and S.haloOn()
    if haloOn then
        if not S.Spot.halo then
            S.Spot.halo = S.New("Image", { Color = S.Theme.C1, Transparency = 0, ZIndex = 89, Visible = false, Size = Vector2.new(1, 1) })
        end
        -- edge image made for the settled size, stretched while the panel scales / grows
        local key = S.Const.SPOT_W .. "x" .. targetH
        if S.Spot.haloKey ~= key then
            local d = S.FX.edge(S.Const.SPOT_W, targetH, 14, 9, 4)
            if d then S.Spot.halo.Data = d S.Spot.haloKey = key end
        end
        S.Spot.halo.Position, S.Spot.halo.Size = Vector2.new(x - 9, y - 9), Vector2.new(W + 18, H + 18)
        S.Spot.halo.Color = S.Theme.C1
        S.Spot.halo.Transparency = (0.32 + 0.08 * math.sin(S.runT * 2.1)) * a
        S.Spot.halo.Visible = S.Spot.haloKey ~= nil
    elseif S.Spot.halo then
        S.Spot.halo.Visible = false
    end
    local hasHalo = haloOn and S.Spot.haloKey ~= nil
    S.Spot.ol.Position, S.Spot.ol.Size = Vector2.new(x, y), Vector2.new(W, H)
    S.Spot.ol.Color, S.Spot.ol.Transparency = S.lerpColor(S.Theme.Track, S.Theme.C1, 0.35), 0.8 * a
    S.Spot.ico.Position, S.Spot.ico.Transparency = Vector2.new(x + 20, y + math.floor((headH - 18) / 2)), aT
    S.Spot.ico.Color = S.Theme.C1
    -- placeholder types itself out after opening (typewriter, ~45 ms a letter); caret stays solid while it types
    local ph = "Search LegoSense"
    local nType = (S.animOn() and not typed) and math.clamp(math.floor((S.Spot.rowsT - 0.1) / 0.045), 0, #ph) or #ph
    local caret = (S.Spot.open and (S.Cfg.perfMode or nType < #ph or (S.Spot.blinkT % 1) < 0.55)) and "|" or " "
    S.Spot.txt.Text = typed and (S.Spot.buf .. caret) or (ph:sub(1, nType) .. caret)
    S.Spot.txt.Color = typed and S.Theme.Text or S.Theme.White
    S.Spot.txt.Position = Vector2.new(x + 50, y + math.floor((headH - S.TH(S.Spot.txt, S.FS + 6)) / 2))
    S.Spot.txt.Transparency = aT
    local showList = H > headH + 6
    S.Spot.div.Position, S.Spot.div.Size = Vector2.new(x + 14, y + headH), Vector2.new(W - 28, 1)
    S.Spot.div.Transparency, S.Spot.div.Visible = 0.5 * aT, showList
    S.Spot.hint.Position = Vector2.new(x + 22, y + H - 21)
    S.Spot.hint.Transparency, S.Spot.hint.Visible = aT * math.min(1, S.Spot.rowsT / 0.25), n > 0 and H >= targetH - 2
    S.Spot.empty.Visible = typed and n == 0 and H >= targetH - 2
    S.Spot.empty.Position = Vector2.new(x + math.floor((W - S.TW(S.Spot.empty)) / 2), y + headH + 13)
    S.Spot.empty.Transparency = aT

    -- mouse: hovering picks a row only when the mouse moved (so arrow keys aren't overridden)
    local moved = S.Spot.mx ~= S.In.x or S.Spot.my ~= S.In.y
    S.Spot.mx, S.Spot.my = S.In.x, S.In.y
    local clicked = nil
    local listTop = y + headH + 7
    for i = 1, S.Const.SPOT_MAX do
        local r, res = S.Spot.rows[i], S.Spot.results[i]
        local ry = listTop + (i - 1) * rowH
        local on = res ~= nil and (ry + rowH - 4) <= (y + H - 24)
        if on then
            local hov = S.Spot.open and S.inRect(S.In.x, S.In.y, x + 8, ry, W - 16, rowH - 4)
            if hov and moved then S.Spot.sel = i end
            if hov and S.In.pressed then clicked = res end
            -- stagger: each row fades + slides in 20 ms after the one above
            -- stagger: each row rises + fades in 30 ms after the one above (the menu's cascade, quicker)
            local rt = math.max(0, math.min(1, (S.Spot.rowsT - (i - 1) * 0.03) / 0.22))
            rt = anim and (1 - (1 - rt) ^ 3) or 1
            local slide = 0
            local cy = ry + math.floor((rowH - 4) / 2) + math.floor((1 - rt) * 8 + 0.5)
            r.lbl.Text = S.truncate(res.label, 250)
            r.lbl.Position = Vector2.new(x + 24 + slide, cy - math.floor(S.TH(r.lbl, S.FS + 1) / 2))
            r.lbl.Color = res.row.disabled and S.Theme.Dim or ((i == S.Spot.sel) and S.Theme.White or S.Theme.Text)
            local stT = S.spotState(res.row)
            r.st.Text = S.truncate(stT, 120)
            r.st.Color = (res.row.kind == "toggle" and not res.row.value) and S.Theme.Dim or S.Theme.C1
            r.st.Position = Vector2.new(x + 24 + slide + S.TW(r.lbl) + 12, cy - math.floor(S.TH(r.st, S.FS - 1) / 2))
            r.path.Text = S.truncate(res.tab .. "  /  " .. (res.sec.title or ""), 170)
            r.path.Position = Vector2.new(x + W - 22 - S.TW(r.path), cy - math.floor(S.TH(r.path, S.FS - 1) / 2))
            for _, o in ipairs({ r.lbl, r.st, r.path }) do o.Transparency = aT * rt end
        end
        r.lbl.Visible, r.st.Visible, r.path.Visible = on, on, on
    end
    -- selection highlight glides to the selected row
    local selOn = n > 0 and S.Spot.sel <= n and (listTop + S.Spot.sel * rowH - 4) <= (y + H - 24)
    if selOn then
        local ty = listTop + (S.Spot.sel - 1) * rowH
        S.Spot.selY = S.Spot.selY and (S.Spot.selY + (ty - S.Spot.selY) * ease) or ty
        if math.abs(S.Spot.selY - ty) < 0.5 then S.Spot.selY = ty end
        local sy = math.floor(S.Spot.selY + 0.5)
        S.Spot.hi.Position, S.Spot.hi.Size = Vector2.new(x + 8, sy), Vector2.new(W - 16, rowH - 4)
        pcall(function() S.Spot.hi.Rounding = 8 end)
        S.Spot.hi.Color, S.Spot.hi.Transparency = S.Theme.C1, 0.42 * aT
    end
    S.Spot.hi.Visible = selOn
    S.Spot.bg.Visible, S.Spot.ol.Visible, S.Spot.ico.Visible, S.Spot.txt.Visible = true, not hasHalo, true, true

    if S.Spot.open and S.In.pressed then
        S.In.pressed = false -- clicks never fall through to the menu while Spotlight is up
        if clicked then S.spotRun(clicked, iskeypressed(0x10))
        elseif not S.inRect(S.In.x, S.In.y, x, y, W, H) then S.spotClose() end
    end
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
    -- Backspace repeats while held: 0.4 s delay, then every 35 ms
    if S.edgeKey(0x08) then applyBksp() S.bkspT = os.clock() + 0.4
    elseif S.bkspT and iskeypressed(0x08) and os.clock() >= S.bkspT then applyBksp() S.bkspT = os.clock() + 0.035 end
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
    pcall(writefile, S.saveTargetPath(), S.snapshot("script"))
    S.ensureDir(S.ROOT)
    pcall(writefile, S.UI_PATH, S.snapshot("ui"))
end

-- ========== overlays ==========
-- small always-on-top panels (keybinds, staff list, ...) that stay up with the menu closed.
-- a script feeds rows with SetRows; text is only rewritten when it changes (Text writes are slow in Matcha).
-- drag one by its header while the menu is open; positions are saved with the settings.
S.Overlays = {}
S.Const.OV_ROW, S.Const.OV_PAD, S.Const.OV_HEAD = 22, 10, 28
-- every UI panel (window + overlays) keeps this gap to each screen edge; same as an overlay's default x
S.Const.EDGE = 24
function S.clampRect(x, y, w, h)
    local vp = S.vp
    if not vp then return x, y end
    local m = S.Const.EDGE
    return math.clamp(x, m, math.max(m, vp.X - w - m)), math.clamp(y, m, math.max(m, vp.Y - h - m))
end
S.Overlay = {}
S.Overlay.__index = S.Overlay

function S.newOverlay(opts)
    opts = opts or {}
    local n = #S.Overlays
    local font = S.FontIds[S.Cfg.font] or 0
    local ov = setmetatable({
        id = tostring(opts.Id or opts.Title or ("overlay" .. (n + 1))), title = tostring(opts.Title or "Overlay"),
        x = opts.Position and opts.Position.X or 24, y = opts.Position and opts.Position.Y or (260 + n * 140),
        minW = opts.MinWidth or 160, empty = opts.EmptyText or "None",
        rows = {}, visible = opts.Visible ~= false, dirty = true, font = font,
        L = {}, R = {}, lTxt = {}, rTxt = {}, lCol = {}, rCol = {},
        chips = {}, washes = {}, tags = {}, seen = {}, actT = {}, countText = "",
    }, S.Overlay)
    ov.bg = S.New("Square", { Filled = true, Color = S.Theme.Dark, Transparency = 0.9, ZIndex = 20, Corner = S.CR(5), Visible = false })
    ov.edge = S.New("Square", { Filled = false, Color = S.Theme.Track, Transparency = 0.55, ZIndex = 21, Corner = S.CR(5), Visible = false })
    ov.accent = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 1, ZIndex = 21, Visible = false })
    ov.head = S.New("Text", { Text = ov.title, Color = S.Theme.Header, Transparency = 1, ZIndex = 22, Font = font, Size = S.FS, Visible = false })
    -- The header can show a count at the right.
    ov.count = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 22, Font = font, Size = S.FS - 2, Visible = false })
    table.insert(S.Overlays, ov)
    return ov
end

-- rows: { { "left", "right", leftColor?, rightColor? }, ... } or { { Left = .., Right = .., Color = .., RightColor = .. }, ... }
function S.Overlay:SetRows(rows)
    local out = {}
    for i, r in ipairs(rows or {}) do
        out[i] = {
            l = tostring(r.Left or r[1] or ""), r = tostring(r.Right or r[2] or ""),
            lc = r.Color or r[3], rc = r.RightColor or r[4],
            active = (r.Active or r.active) and true or false, tag = r.Tag or r.tag, chip = (r.Chip or r.chip) and true or false,
        }
        -- Key = stable identity for the row-in animation / active wash (default: the left text). A row whose left text
        -- changes every update (such as the watermark's FPS) can keep its animation state by supplying a stable Key.
        out[i].key = tostring(r.Key or r.key or out[i].l)
    end
    self.rows = out
    self.dirty = true
    return self
end
function S.Overlay:SetTitle(t) self.title = tostring(t) self.dirty = true return self end
function S.Overlay:SetVisible(v) self.visible = v and true or false self.dirty = true return self end
function S.Overlay:IsVisible() return self.visible end

function S.ovRowObjs(ov, i)
    if not ov.L[i] then
        ov.L[i] = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 1, ZIndex = 22, Font = ov.font, Size = S.FS, Visible = false })
        ov.R[i] = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 23, Font = ov.font, Size = S.FS - 1, Visible = false })
        ov.chips[i] = S.New("Square", { Filled = true, Color = S.Theme.Control, Transparency = 0, ZIndex = 22, Corner = 4, Visible = false })
        ov.tags[i] = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 0, ZIndex = 22, Font = ov.font, Size = S.FS - 3, Visible = false })
        local ramp = S.FX.ok and S.FX.get("tabRamp", 256, 2, function(px) return (1 - px / 256) ^ 1.6 end)
        if ramp then ov.washes[i] = S.New("Image", { Data = ramp, Color = S.Theme.C1, Transparency = 0, ZIndex = 21, Visible = false, Size = Vector2.new(1, 1) }) end
    end
    return ov.L[i], ov.R[i], ov.chips[i], ov.washes[i], ov.tags[i]
end

-- docked overlay (the keybind overlay): sits beside the open menu's top-right corner and follows it; with the menu
-- closed it goes to its own spot (ov.x / ov.y, draggable then). The transition uses a 0.55 s ease-out-back
-- that overshoots by about 4% and settles. The path bows perpendicular to travel by 12% of
-- the distance (max 40 px), the panel dips to 55% opacity mid-flight, and the accent halo flashes as it lands.
S.Const.OV_DOCK_GAP = 12
function S.ovDockPos(ov, fx, fy, w, h)
    local docked = S.Win.visible and not S.Intro
    local tx, ty = fx, fy
    if docked then
        local g = S.Const.OV_DOCK_GAP
        tx, ty = S.Win.x + S.Win.w + g, S.Win.y
        if S.vp and tx + w > S.vp.X - S.Const.EDGE then tx = S.Win.x - g - w end -- no room right: dock on the left
        tx, ty = S.clampRect(tx, ty, w, h)
    end
    if ov.dockMode ~= docked then
        if ov.dockMode ~= nil and ov.dx and S.animOn() then ov.mv = { x = ov.dx, y = ov.dy, t0 = os.clock() } end
        ov.dockMode = docked
    end
    local mv = ov.mv
    ov.flyA = 1
    if S.Cfg.perfMode then
        ov.mv, ov.landT = nil, nil
        return tx, ty
    end
    if not mv then return tx, ty end
    local k = math.clamp((os.clock() - mv.t0) / 0.55, 0, 1)
    if k >= 1 then ov.mv = nil ov.landT = os.clock() return tx, ty end
    ov.anim = true
    local c1 = 1.2 -- ease-out-back
    local f = 1 + (c1 + 1) * (k - 1) ^ 3 + c1 * (k - 1) ^ 2
    local dx, dy = tx - mv.x, ty - mv.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if f > 1 and dist > 0 then f = 1 + (f - 1) * math.min(1, 16 / (dist * 0.05)) end -- peak overshoot ~16 px max, still smooth
    local bow = math.min(40, dist * 0.12) * math.sin(math.clamp(f, 0, 1) * math.pi)
    local nx, ny = 0, 0
    if dist > 0.5 then nx, ny = dy / dist, -dx / dist end -- perpendicular, turned so a sideways move bows upward
    if ny > 0 then nx, ny = -nx, -ny end
    ov.flyA = 1 - 0.45 * math.sin(k * math.pi)
    return math.floor(mv.x + dx * f + nx * bow + 0.5), math.floor(mv.y + dy * f + ny * bow + 0.5)
end
-- runs when an overlay changes and every frame while it animates (height ease, rows rising in, active wash)
function S.layoutOverlay(ov)
    ov.dirty, ov.anim = false, false
    local show = ov.visible and UI.created
    local rows = ov.rows
    local list = (#rows > 0) and rows or { { l = ov.empty, r = "", lc = S.Theme.Dim } }
    local pad, rowH, headH = S.Const.OV_PAD, S.Const.OV_ROW, S.Const.OV_HEAD
    local op, now = S.Cfg.opacity * (S.Cfg.ovOpacity or 100) / 100, os.clock()
    local ease = S.animOn() and (1 - (0.0000005 ^ (S.frameDt or 1 / 60))) or 1
    local w = math.max(ov.minW, (#ov.title + #ov.countText) * S.CHAR_W + pad * 2 + 24)
    for _, r in ipairs(list) do
        local extra = (r.chip and 14 or 0) + (r.tag and (#r.tag * S.CHAR_W + 10) or 0)
        w = math.max(w, (#r.l + #r.r) * S.CHAR_W + pad * 2 + 26 + extra)
    end
    local h = headH + #list * rowH + 8
    ov.w, ov.h = w, h
    ov.shownH = ov.shownH and (ov.shownH + (h - ov.shownH) * ease) or h
    if math.abs(ov.shownH - h) < 0.5 then ov.shownH = h else ov.anim = true end
    local H = math.floor(ov.shownH + 0.5)
    -- drawn position is clamped, ov.x/ov.y stay as placed, so a panel that grew and got pushed in returns when it shrinks
    local x, y = S.clampRect(math.floor(ov.x), math.floor(ov.y), w, h)
    if ov.dock then x, y = S.ovDockPos(ov, x, y, w, h) op = op * (ov.flyA or 1) end
    ov.dx, ov.dy = x, y
    ov.bg.Visible, ov.head.Visible, ov.count.Visible = show, show, show
    ov.accent.Visible = false
    local haloOn = show and S.FX.ok and S.haloOn()
    if show then
        ov.bg.Position, ov.bg.Size, ov.bg.Color, ov.bg.Corner = Vector2.new(x, y), Vector2.new(w, H), S.Theme.Bg, S.CR(8)
        ov.bg.Transparency = S.Const.ALPHA_BG * op
        ov.edge.Position, ov.edge.Size, ov.edge.Color, ov.edge.Corner = Vector2.new(x, y), Vector2.new(w, H), S.Theme.Track, S.CR(8)
        if haloOn then
            if not ov.halo then
                ov.halo = S.New("Image", { Color = S.Theme.C1, Transparency = 0, ZIndex = 19, Visible = false, Size = Vector2.new(1, 1) })
            end
            local key = w .. "x" .. h
            if ov.haloKey ~= key and not ov.anim then
                local d = S.FX.edge(w, h, S.CR(8), 9, 4)
                if d then ov.halo.Data = d ov.haloKey = key end
            end
            ov.halo.Position, ov.halo.Size, ov.halo.Color = Vector2.new(x - 9, y - 9), Vector2.new(w + 18, H + 18), S.Theme.C1
        end
        if ov.head.Text ~= ov.title then ov.head.Text = ov.title end
        ov.head.Position, ov.head.Color, ov.head.Transparency = Vector2.new(x + pad, y + 8), S.Theme.Text, op
        if ov.count.Text ~= ov.countText then ov.count.Text = ov.countText end
        ov.count.Position, ov.count.Color, ov.count.Transparency = Vector2.new(x + w - pad - S.TW(ov.count), y + 10), S.Theme.C1, op
    end
    local hasHalo = haloOn and ov.haloKey ~= nil
    ov.edge.Visible = show and not hasHalo
    if ov.halo then ov.halo.Visible = hasHalo end
    -- labels no longer listed forget their timers, so they rise in again when they come back
    local listed = {}
    for _, r in ipairs(rows) do listed[r.key or r.l] = true end
    for k in pairs(ov.seen) do if not listed[k] then ov.seen[k], ov.actT[k] = nil, nil end end
    local n = math.max(#list, #ov.L)
    for i = 1, n do
        local r = list[i]
        if r and show then
            local L, R, chip, wash, tag = S.ovRowObjs(ov, i)
            local k = 1
            if #rows > 0 then
                local rk = r.key or r.l
                ov.seen[rk] = ov.seen[rk] or now
                if S.animOn() then k = math.clamp((now - ov.seen[rk] - (i - 1) * 0.04) / 0.3, 0, 1) end
            end
            k = 1 - (1 - k) ^ 3
            local target = r.active and 1 or 0
            local at = ov.actT[r.key or r.l] or target
            at = at + (target - at) * ease
            if math.abs(at - target) < 0.01 then at = target else ov.anim = true end
            if #rows > 0 then ov.actT[r.key or r.l] = at end
            if k < 1 then ov.anim = true end
            local ry = y + headH + (i - 1) * rowH + math.floor((1 - k) * 6 + 0.5)
            local cy = ry + rowH / 2
            if wash then
                wash.Visible = at > 0.01
                wash.Position, wash.Size = Vector2.new(x + 4, ry + 1), Vector2.new(w - 8, rowH - 2)
                pcall(function() wash.Rounding = S.CR(6) end) -- same as the tab highlight
                wash.Color, wash.Transparency = S.Theme.C1, 0.42 * at * k * op
            end
            if ov.lTxt[i] ~= r.l then ov.lTxt[i] = r.l L.Text = r.l end
            if ov.rTxt[i] ~= r.r then ov.rTxt[i] = r.r R.Text = r.r end
            L.Color = r.lc or S.lerpColor(S.Theme.Text, S.Theme.White, at)
            L.Position, L.Transparency = Vector2.new(x + pad, math.floor(cy - S.TH(L, S.FS) / 2 + 0.5)), k * op
            local rx = x + w - pad
            if r.chip and r.r ~= "" then
                local cw = S.TW(R) + 12
                rx = rx - cw
                chip.Visible = true
                chip.Position, chip.Size, chip.Corner = Vector2.new(rx, ry + 3), Vector2.new(cw, rowH - 6), S.CR(4)
                chip.Color, chip.Transparency = S.lerpColor(S.Theme.Control, S.Theme.C1, 0.18 * at), 0.9 * k * op
                R.Position = Vector2.new(rx + 6, math.floor(cy - S.TH(R, S.FS - 1) / 2 + 0.5))
                R.Color = r.rc or S.lerpColor(S.Theme.Dim, S.Theme.C1, at)
            else
                chip.Visible = false
                R.Position = Vector2.new(rx - S.TW(R), math.floor(cy - S.TH(R, S.FS - 1) / 2 + 0.5))
                R.Color = r.rc or S.Theme.Dim
                rx = rx - S.TW(R)
            end
            R.Transparency = k * op
            if r.tag then
                if tag.Text ~= r.tag then tag.Text = r.tag end
                tag.Visible = true
                tag.Position = Vector2.new(rx - 6 - S.TW(tag), math.floor(cy - S.TH(tag, S.FS - 3) / 2 + 0.5))
                tag.Color, tag.Transparency = S.Theme.Dim, 0.8 * k * op
            else
                tag.Visible = false
            end
            L.Visible, R.Visible = true, true
        elseif ov.L[i] then
            ov.L[i].Visible, ov.R[i].Visible, ov.chips[i].Visible, ov.tags[i].Visible = false, false, false, false
            if ov.washes[i] then ov.washes[i].Visible = false end
        end
    end
end

-- built-in keybind overlay: every keybind control, its key, highlighted while held
S.KeybindOverlay = S.newOverlay({ Id = "keybinds", Title = "Keybinds", Visible = false, EmptyText = "No keybinds" })
S.KeybindOverlay.dock = true -- beside the open menu, free spot while it's closed (S.ovDockPos)
S.KeybindOverlay.builtin = true -- position saved in ui.json (_uiOverlays), shared by every script
S.kbT = 0
function S.updateKeybindOverlay(dt)
    local ov = S.KeybindOverlay
    local enabled = not S.Cfg.perfMode and S.Cfg.keybindOverlay == true
    if ov.visible ~= enabled then ov:SetVisible(enabled) end
    if not ov.visible then return end
    S.kbT = S.kbT + dt
    if S.kbT < 0.05 then return end
    S.kbT = 0
    local rows, sig, on = {}, {}, 0
    for _, r in ipairs(S.KeybindRows) do
        if r.vk and r.vk ~= 0 then
            local held = (r.vk == -2) and ismouse2pressed() or (r.vk > 0 and iskeypressed(r.vk))
            -- a bind with a Mode is "on" by its state (toggled / held / always); a plain bind while its key is down
            local active = held
            if r.mode then active = r.keyState == true end
            local key = S.rowKeyName(r)
            local tag = r.mode and r.mode:lower() or nil
            if active then on = on + 1 end
            if active or not S.Cfg.kbActiveOnly then
                rows[#rows + 1] = { Left = r.label, Right = key, Active = active, Tag = tag, Chip = true }
                sig[#sig + 1] = r.label .. key .. (active and "1" or "0") .. (tag or "")
            end
        end
    end
    ov.countText = ""
    local key = table.concat(sig, "|")
    if key ~= ov.kbSig then ov.kbSig = key ov:SetRows(rows) end
end

-- watermark: brand + FPS + ping + time (Settings > Overlays)
S.Watermark = S.newOverlay({ Id = "watermark", Title = "LegoSense", Visible = false, EmptyText = "" })
S.Watermark.builtin = true
S.wm = { t = 0, frames = 0 }
function S.updateWatermark(dt)
    local ov, w = S.Watermark, S.wm
    local on = not S.Cfg.perfMode and S.Cfg.watermark == true
    if ov.visible ~= on then ov:SetVisible(on) end
    if not on then w.t, w.frames = 0, 0 return end
    w.frames = w.frames + 1
    w.t = w.t + dt
    if w.t < 0.5 then return end
    local fps = math.floor(w.frames / w.t + 0.5)
    w.t, w.frames = 0, 0
    if ov.title ~= S.BRAND then ov.title = S.BRAND end
    local pg = S.homePing and S.homePing()
    ov:SetRows({ { Key = "wm", Left = fps .. " fps" .. (pg and ("   " .. pg .. " ms") or ""), Right = os.date("%H:%M:%S") } }) -- local clock (seconds: HH:MM looked frozen)
end
function S.updateOverlays(dt)
    S.updateKeybindOverlay(dt)
    S.updateWatermark(dt)
    local themeKey = S.Theme.Dark
    for _, ov in ipairs(S.Overlays) do
        -- saved position, applied once the settings have been loaded
        if UI.created and not ov.restored then
            ov.restored = true
            local src = ov.builtin and type(S.Persisted._uiOverlays) == "table" and S.Persisted._uiOverlays[ov.id] and S.Persisted._uiOverlays or S.Persisted._overlays
            local saved = type(src) == "table" and src[ov.id]
            if type(saved) == "table" and type(saved[1]) == "number" then ov.x, ov.y = saved[1], saved[2] end
            ov.dirty = true
        end
        local halo = S.haloOn()
        if ov.theme ~= themeKey or ov.themeC1 ~= S.Theme.C1 or ov.haloOn ~= halo then
            ov.theme, ov.themeC1, ov.haloOn, ov.dirty = themeKey, S.Theme.C1, halo, true
        end
        if S.vpChanged then ov.dirty = true end
        -- drag by the header, only while the menu is open (mouse input belongs to the game otherwise). The docked
        -- keybind overlay is the other way round: fixed beside the open menu, draggable to its own spot while it's closed
        if ov.dock and ov.winWas ~= (S.Win.visible and not S.Intro) then ov.winWas = S.Win.visible and not S.Intro ov.dirty = true end -- open / close: fly
        if ov.dock and S.Win.visible then
            local wk = S.Win.x .. "," .. S.Win.y .. "," .. S.Win.w .. "," .. S.Win.h
            if ov.winKey ~= wk then ov.winKey = wk ov.dirty = true end -- follow the menu when it moves / resizes
        end
        local canDrag = (ov.dock and not S.Win.visible and not ov.mv) or (not ov.dock and S.Win.visible)
        if ov.visible and canDrag and ov.w then
            local hx, hy = ov.dx or ov.x, ov.dy or ov.y
            if S.In.pressed and not S.ovDrag and not S.Cfg.ovLock and S.inRect(S.In.x, S.In.y, hx, hy, ov.w, S.Const.OV_HEAD)
                and not (S.Win.visible and S.inRect(S.In.x, S.In.y, S.Win.x, S.Win.y, S.Win.w, S.Win.h)) then
                S.ovDrag = { ov = ov, ox = S.In.x - hx, oy = S.In.y - hy }
            end
        end
        if S.ovDrag and S.ovDrag.ov == ov then
            if S.In.down then
                ov.x, ov.y = S.clampRect(S.In.x - S.ovDrag.ox, S.In.y - S.ovDrag.oy, ov.w or 0, ov.h or 0)
                ov.dirty = true
            else
                S.ovDrag = nil
                S.markChanged()
            end
        end
        local layout = ov.dirty or ov.anim
        if layout then S.layoutOverlay(ov) end
        if ov.visible and UI.created and ov.dx then
            if halo and ov.haloKey then
                local land = ov.landT and math.max(0, 1 - (os.clock() - ov.landT) / 0.5) or 0
                ov.halo.Transparency = math.min(1, (0.26 + 0.07 * math.sin(S.runT * 2.1) + 0.5 * land * land)) * S.Cfg.opacity
            end
            if not S.Cfg.perfMode then
                local h = ov.shownH or ov.h
                S.Blur.rect(ov, ov.dx, ov.dy, ov.w, h, S.Const.BLUR_INSET_SMALL)
                local glass = S.glassOn()
                if glass then
                    local oa = S.Cfg.opacity * (S.Cfg.ovOpacity or 100) / 100 * (ov.flyA or 1)
                    S.glassPanel(ov, ov.bg, ov.dx, ov.dy, ov.w, math.floor(h + 0.5), oa, 8)
                elseif ov.glassOn and not layout then
                    ov.bg.Transparency = S.Const.ALPHA_BG * S.Cfg.opacity * (S.Cfg.ovOpacity or 100) / 100 * (ov.flyA or 1)
                end
                ov.glassOn = glass
            end
        end
    end
end

S.loadYield()
-- ========== UI performance diagnostics ==========
-- Reports include player name, displayName, userId and account age, game identity, per-phase frame and UI
-- timings, CPU/GPU render samples, drawing counts, boot marks, recent hitches and environment settings.
-- Only a PUBLIC, non-secret UI-owner Luarmor loader URL belongs here, never the webhook.
-- Alternatively the private UI-owner bootstrap can register __LEGOSENSE_UI_TELEMETRY_SEND.
-- Consumer scripts do not configure destinations or transports.
-- The global UI sharing setting controls outbound reports. Local diagnostics are saved regardless.
S.UI_TELEMETRY = { LoaderUrl = "https://api.luarmor.net/files/v4/loaders/bbe98a166432b39dfb52b9521358a235.lua", LoadTimeout = 10 }
function S.perfEnv()
    local e = { lib = UI.Version, executor = "?", quality = "?", screen = "?", uiScale = S.K, memMB = -1, cpuMs = -1, gpuMs = -1 }
    pcall(function() local n, v = identifyexecutor() e.executor = tostring(n) .. (v and (" " .. tostring(v)) or "") end)
    pcall(function() e.quality = tostring(UserSettings():GetService("UserGameSettings").SavedQualityLevel) end)
    pcall(function() local v = workspace.CurrentCamera.ViewportSize e.screen = math.floor(v.X) .. "x" .. math.floor(v.Y) end)
    pcall(function() e.memMB = math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb()) end)
    local cpu, gpu = S.perfStats()
    if cpu then e.cpuMs = math.floor(cpu * 10) / 10 end
    if gpu then e.gpuMs = math.floor(gpu * 10) / 10 end
    pcall(function() e.players = #game:GetService("Players"):GetPlayers() end)
    pcall(function()
        local getter = getfenv().getfpscap
        if type(getter) ~= "function" then return end
        local cap = getter()
        if type(cap) == "number" and cap >= 0 and cap < math.huge then e.fpsCap = cap end
    end)
    e.drawings = #UI.Objects
    e.fx = { glass = S.glassOn and S.glassOn() or false, blur = S.Blur.on(), blurArea = S.Cfg.blurMode, snow = S.Cfg.perfMode and "Off" or S.Cfg.bgFx,
        animations = S.animOn(), perfMode = S.Cfg.perfMode == true, themeImgBlur = S.Cfg.perfMode and 0 or (S.Cfg.themeImgBlur or 0),
        glow = S.haloOn() }
    return e
end
function S.perfId()
    if S.Perf.id then return S.Perf.id end
    local path = S.ROOT .. "/perf_id.txt"
    local ok, id = pcall(function() return isfile(path) and readfile(path) end)
    if not (ok and type(id) == "string" and #id >= 8) then
        id = string.format("%08x", math.random(0, 0x7fffffff)) pcall(writefile, path, id)
    end
    S.Perf.id = id
    return id
end
function S.perfDrawings()
    -- Match env.drawings by counting the managed objects. Visibility is the last cached intent.
    local byType, visible = {}, 0
    for _, o in ipairs(UI.Objects) do
        local kind = S.Shapes[o]
        if kind then byType[kind] = (byType[kind] or 0) + 1 end
        local e = S.ScaleLogical[o]
        if e and not e.removed and e.c.Visible == true then visible = visible + 1 end
    end
    local P = S.Perf
    return { total = #UI.Objects, visible = visible, byType = byType, created = P.created, freed = P.freed, peak = P.peak }
end

function S.perfRound(n, scale)
    return math.floor(n * scale + 0.5) / scale
end
function S.perfReport(reason)
    local ph, hitches = {}, {}
    for name, P in pairs(S.Perf.ph) do
        if P.n > 0 or P.uiN > 0 or P.blurN > 0 then
            local uiN, sections = math.max(1, P.uiN), {}
            for key, seconds in pairs(P.sections) do sections[key] = S.perfRound(seconds * 1000 / uiN, 1000) end
            ph[name] = { frames = P.n, avgMs = math.floor(P.sum / math.max(1, P.n) * 10) / 10, worstMs = math.floor(P.worst * 10) / 10,
                over8ms = P.s120, over16ms = P.s60, bins = P.bins,
                uiAvgMs = S.perfRound(P.uiSum * 1000 / uiN, 1000), uiWorstMs = S.perfRound(P.uiWorst * 1000, 1000),
                blurAvgMs = S.perfRound(P.blurSum * 1000 / math.max(1, P.blurN), 1000), sections = sections,
                drawEntriesAvg = S.perfRound(P.drawEntries / uiN, 100), drawEntriesMax = P.drawMax,
                drawPropertyWritesAvg = S.perfRound(P.drawWrites / uiN, 100),
                relayoutsPerSec = P.sum > 0 and S.perfRound(P.relayouts * 1000 / P.sum, 100) or 0,
                renderCpuAvgMs = P.cpuN > 0 and S.perfRound(P.cpuSum / P.cpuN, 1000) or nil,
                renderGpuAvgMs = P.gpuN > 0 and S.perfRound(P.gpuSum / P.gpuN, 1000) or nil }
        end
    end
    local perf = S.Perf
    for i = 1, perf.hitchCount do
        local h = perf.hitches[(perf.hitchNext - perf.hitchCount + i - 2) % #perf.hitches + 1]
        hitches[i] = { phase = h.phase, ms = S.perfRound(h.ms, 100), uptimeS = S.perfRound(h.uptimeS, 1000),
            section = h.section, sectionMs = S.perfRound(h.sectionMs, 1000), lastMark = h.lastMark }
    end
    -- Summary over settled frames (load/intro excluded unless nothing else was sampled yet).
    local function sum(skipBoot)
        local n, total, worst, over16 = 0, 0, 0, 0
        for name, P in pairs(S.Perf.ph) do
            if not (skipBoot and (name == "load" or name == "intro")) then
                n, total, over16 = n + P.n, total + P.sum, over16 + P.s60
                if P.worst > worst then worst = P.worst end
            end
        end
        return n, total, worst, over16
    end
    local n, total, worst, over16 = sum(true)
    if n == 0 then n, total, worst, over16 = sum(false) end
    local avgMs = total / math.max(1, n)
    local open = S.Perf.ph.open
    local summary = { frames = n, avgMs = math.floor(avgMs * 10) / 10, avgFps = avgMs > 0 and math.floor(1000 / avgMs + 0.5) or 0,
        worstMs = math.floor(worst * 10) / 10, over16Pct = math.floor(over16 / math.max(1, n) * 1000) / 10,
        openAvgMs = open and open.n > 0 and math.floor(open.sum / open.n * 10) / 10 or nil }
    local player = {}
    pcall(function()
        local lp = game:GetService("Players").LocalPlayer
        player = { name = lp.Name, displayName = lp.DisplayName, userId = lp.UserId, accountAgeDays = lp.AccountAge }
    end)
    local place = { placeId = game.PlaceId, gameId = game.GameId, jobId = game.JobId, script = S.BRAND }
    local report = { id = S.perfId(), reason = reason, uptimeS = math.floor(os.clock() - S.PerfT0),
        player = player, game = place, summary = summary,
        marks = perf.marks, phases = ph, env = S.perfEnv(), drawings = S.perfDrawings(), hitches = hitches }
    local errors = (perf :: any).errors
    if errors and #errors > 0 then
        -- PerfReport is also public. Keep its entries separate from the library's recorder.
        local entries = table.create(#errors)
        for i, entry in ipairs(errors) do entries[i] = table.clone(entry) end
        report.errors = entries
        report.droppedErrors = (perf :: any).droppedErrors
    end
    return report
end
function S.perfAllowed()
    return S.Perf.consentReady and not S.unloaded and not UI.unloaded and not S.Env.matcha and S.Cfg.perfShare ~= false
end
function S.perfCancelPending(status)
    local P, current = S.Perf, coroutine.running()
    local load = P.senderLoad
    P.senderLoad = nil -- invalidate before cancellation; native HTTP may still finish late
    local function cancel(thread)
        if thread and thread ~= current then pcall(task.cancel, thread) end
    end
    if load then cancel(load.worker) cancel(load.watch) end
    cancel(P.sendThread)
    P.senderLoading, P.sendPending, P.sendThread = false, false, nil
    P.senderStatus = status
end
-- Non-yielding lookup/start. A protected loader may return a function or register it later.
function S.perfSender()
    if not S.perfAllowed() then return nil end
    local P = S.Perf
    if type(P.sender) == "function" then P.senderStatus = "ready" return P.sender end
    if P.senderStatus == "timeout" or P.senderStatus == "failed" then return nil end
    local env = (type(getgenv) == "function" and getgenv()) or getfenv()
    local registered = rawget(env, "__LEGOSENSE_UI_TELEMETRY_SEND")
    if type(registered) == "function" then P.sender, P.senderStatus = registered, "ready" return registered end
    if P.senderLoading then return nil end
    local url = S.UI_TELEMETRY.LoaderUrl
    if type(url) ~= "string" or not url:match("^https://") or url:find("/api/webhooks", 1, true) then
        P.senderStatus = "unconfigured" return nil
    end
    local timeout = math.clamp(tonumber(S.UI_TELEMETRY.LoadTimeout) or 10, 0.1, 30)
    local attempt = { deadline = os.clock() + timeout }
    P.senderLoad, P.senderLoading, P.senderStatus, P.senderLoadError = attempt, true, "loading", nil
    attempt.worker = task.spawn(function()
        local ok, sender = pcall(function()
            local code = S.httpGet(url)
            if P.senderLoad ~= attempt or not S.perfAllowed() or os.clock() >= attempt.deadline then return nil end
            local build = loadstring(code, "@legosense-private-ui-sender")
            if not build then error("Private UI sender did not compile") end
            return build()
        end)
        if P.senderLoad ~= attempt or not S.perfAllowed() or os.clock() >= attempt.deadline then return end
        if not ok then attempt.failed = true
        elseif type(sender) == "function" then attempt.sender = sender end
    end)
    attempt.watch = task.spawn(function()
        while P.senderLoad == attempt and S.perfAllowed() do
            if os.clock() >= attempt.deadline then break end
            local sender = attempt.sender or rawget(env, "__LEGOSENSE_UI_TELEMETRY_SEND")
            if type(sender) == "function" then
                P.sender, P.senderStatus, P.senderLoading, P.senderLoad = sender, "ready", false, nil
                return
            end
            if attempt.failed then break end
            task.wait(0.05) -- poll explicit registration, bounded by this attempt's deadline
        end
        if P.senderLoad ~= attempt then return end
        P.senderLoad, P.senderLoading = nil, false
        P.senderStatus = S.perfAllowed() and (attempt.failed and "failed" or "timeout") or "disabled"
        P.senderLoadError = "Private UI sender unavailable"
        if attempt.worker then pcall(task.cancel, attempt.worker) end
    end)
    return P.sender -- task.spawn may finish immediately for a cached/fast loader
end
function S.perfPrepare()
    S.Perf.consentReady = true -- only after loadPersisted restores the UI owner's shared settings
    if S.perfAllowed() then S.perfSender() end
end
function S.perfDeliver(sender, json, final)
    if S.Cfg.perfShare == false or S.Perf.sent >= 3 or (not final and not S.perfAllowed()) then return end
    S.Perf.sent = S.Perf.sent + 1 -- reserve attempt before a sender can yield
    local ok, delivered = pcall(sender, json)
    S.Perf.lastDeliveryOk = ok and delivered == true
    if S.Perf.lastDeliveryOk then S.Perf.delivered = (S.Perf.delivered or 0) + 1 end
end
function S.perfSend(reason)
    local okJ, json, playerName = pcall(function()
        local report = S.perfReport(reason)
        return game:GetService("HttpService"):JSONEncode(report), report.player.name
    end)
    if not okJ then return end
    pcall(function() -- local copy, regardless of sharing preference
        local dir = S.ROOT .. "/logs"
        if not pcall(S.ensureDir, dir) then
            pcall(makefolder, S.ROOT)
            pcall(makefolder, dir)
        end
        local name = tostring(playerName or ""):gsub("[^%w_]", "")
        if name == "" then name = "unknown" end
        local stamp = os.date("!%Y%m%d-%H%M%S")
        local file = string.format("legosense-perf-%s-%s-%s.json", name, stamp, reason)
        writefile(dir .. "/" .. file, json)
    end)
    local P = S.Perf
    if not P.consentReady or S.Env.matcha or S.Cfg.perfShare == false or P.sent >= 3 then return end
    if reason == "unload" then
        -- Cleanup never waits for a loader or a yielding POST; only an already-ready sender is eligible.
        if not S.unloaded and type(P.sender) == "function" then
            local sender = P.sender
            task.spawn(function() S.perfDeliver(sender, json, true) end)
        end
        return
    end
    if not S.perfAllowed() or P.sendPending then return end
    local pending = {}
    P.sendPending = pending
    P.sendThread = task.spawn(function()
        local sender = S.perfSender()
        while not sender and P.senderLoading and S.perfAllowed() and P.sendPending == pending do
            task.wait(0.05)
            sender = S.perfSender()
        end
        if sender and S.perfAllowed() and P.sendPending == pending then S.perfDeliver(sender, json, false) end
        if P.sendPending == pending then P.sendPending, P.sendThread = false, nil end
    end)
end
function S.perfStart()
    if S.Env.matcha or S.Perf.started then return end
    S.Perf.started = true
    task.delay(60, function() if not S.unloaded then pcall(S.perfSend, "60s") end end)
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
-- off Matcha, Mouse.Y leaves out the topbar inset (58 px) while Drawing uses full-viewport coords; UIS matches Drawing
if not (_G.FALUI_ENV and _G.FALUI_ENV.matcha) then pcall(function() S.UIS = game:GetService("UserInputService") end) end
if S.LocalPlayer then
    S.playerName = tostring(S.LocalPlayer.Name)
    local dn = S.LocalPlayer.DisplayName
    S.displayName = (dn and #tostring(dn) > 0) and tostring(dn) or S.playerName
end

S.In = { x = 0, y = 0, down = false, wasDown = false, pressed = false, released = false }
S.Drag = { mode = nil, ox = 0, oy = 0, row = nil, sy = 0, startScroll = 0, pendIdx = 0, startDropScroll = 0 }
S.wheelPulse = 0
S.keyWas = false
S.errCount = 0
S.lastClock = os.clock()
S.runT = 0
S.saveTimer = 0
S.nyanClock = 0

function S.curPage() return S.Pages[S.activeTab] end

function S.doScroll(d)
    if S.Spot.open or S.Dlg then return end
    -- an open dropdown list under the mouse scrolls itself, one option per notch
    local db = S.Drop.open and S.Drop.bg
    if db and S.inRect(S.In.x, S.In.y, db.Position.X, db.Position.Y, db.Size.X, db.Size.Y) then
        local maximum = math.max(0, #S.dropFiltered() - S.Const.MAXOPT)
        S.Drop.scroll = S.Scroll.move(S.Drop.bar, S.Drop.scroll, d > 0 and 1 or -1, maximum, true)
        S.Win.dirty = true
        return
    end
    -- the wheel only scrolls the menu while the mouse is over it (else the game keeps the wheel)
    if not S.inRect(S.In.x, S.In.y, S.Win.x, S.Win.y, S.Win.w, S.Win.h) then return end
    local page = S.curPage()
    if page and S.Win.visible then
        -- over a card that's shorter than its content (resized or MaxHeight): scroll the card, not the page
        for _, sec in ipairs(page.sections) do
            local r = sec.rect
            local lim = sec.limH
            if lim and sec.fitH and sec.fitH > lim and r and S.inRect(S.In.x, S.In.y, r.x, r.y, r.w, r.h) then
                local s = S.Scroll.move(sec.bar, sec.scroll or 0, d, sec.fitH - lim)
                if s ~= sec.scroll then sec.scroll = s S.Win.dirty = true return end
            end
        end
    end
    if page and S.Win.visible then
        local nextScroll, raw = S.Scroll.move(S.PageBar, page.scrollY, d, page.maxScroll or 0)
        page.scrollY = nextScroll
        if raw ~= page.scrollY then S.overPush(page, nil, (raw - page.scrollY) * 11) end
        S.wheelPulse = 0.45
        S.Win.dirty = true
    end
end

-- Anti-AFK (Settings > Interface): Roblox fires Idled after ~20 min without input; a virtual right-click resets the kick timer
pcall(function()
    table.insert(UI.WheelConns, game:GetService("Players").LocalPlayer.Idled:Connect(function()
        if S.previewOnly or S.Cfg.antiAfk == false then return end
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end))
end)
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

-- slider steps: Increment (default 1) sets both the snap and the shown decimals (0.05 -> 2 decimals)
function S.decimals(inc) local d = tostring(inc):match("%.(%d+)$") return d and #d or 0 end
function S.snapSlider(row, v)
    local inc = row.inc or 1
    v = row.min + math.floor((v - row.min) / inc + 0.5) * inc
    v = math.max(row.min, math.min(row.max, v))
    return tonumber(string.format("%." .. S.decimals(inc) .. "f", v))
end
function S.fmtSlider(row)
    local d = S.decimals(row.inc or 1)
    return d == 0 and tostring(math.floor(row.value + 0.5)) or string.format("%." .. d .. "f", row.value)
end
-- real rendered size of a Text object (logical px) when the executor reports TextBounds; else the CHAR_W estimate.
-- set .Text first. Used wherever text is centred.
-- Matcha keeps the estimate its layout was tuned with.
function S.TW(o, cw)
    local e = S.ScaleLogical[o]
    if e and (e.pending.Text ~= nil or e.pending.Size ~= nil or e.pending.Font ~= nil) then
        return S.textWidth(o.Text or "", tonumber(o.Size) or S.FS, o.Font)
    end
    local ok, tb = false, nil
    if not S.Env.matcha then ok, tb = pcall(function() return o.TextBounds end) end
    if ok and tb and tb.X > 0 then return tb.X end
    return #(o.Text or "") * (cw or S.CHAR_W)
end
function S.TH(o, fallback)
    if S.Env.matcha then return fallback or S.FS end
    local ok, tb = pcall(function() return o.TextBounds end)
    if ok and tb and tb.Y > 0 then return tb.Y end
    return fallback or S.FS
end
-- fire a row's callback + mark the config dirty (shared by typing paths)
function S.fireRow(row)
    if row.onChange then pcall(row.onChange, row.value) end
    if row.flag then S.markChanged() end
end
function S.vkHeld(vk)
    if vk == 0x01 then return ismouse1pressed() end
    if vk == -2 or vk == 0x02 then return ismouse2pressed() end
    return vk and vk > 0 and iskeypressed(vk) or false
end
-- keybinds with a Mode: Toggle flips on each press, Hold is on while held, Always stays on.
-- A linked Toggle row follows the state (and clicking that toggle feeds back into Toggle mode).
function S.pollKeyRows()
    for _, kr in ipairs(S.KeyRows) do
        if S.Capture.row ~= kr and not S.Focus.row and not S.Spot.open then
            local held = S.vkHeld(kr.vk)
            local st = kr.keyState
            if kr.toggleRow and kr.mode == "Toggle" then st = kr.toggleRow.value end
            if kr.mode == "Hold" then st = held
            elseif kr.mode == "Always" then st = true
            elseif held and not kr.wasHeld then st = not st end
            kr.wasHeld = held
            if st ~= kr.keyState or (kr.toggleRow and kr.toggleRow.value ~= st) then
                kr.keyState = st
                if kr.toggleRow and kr.toggleRow.value ~= st then S.Element.new(kr.toggleRow):Set(st) end
                if kr.onKey then pcall(kr.onKey, st) end
            end
        end
    end
end

function S.sliderFromMouse(row)
    local t = math.max(0, math.min(1, (S.In.x - row.barX) / row.barW))
    local v = S.snapSlider(row, row.min + t * (row.max - row.min))
    if v ~= row.value then
        row.value = v
        if row.onChange then pcall(row.onChange, v) end
        if row.flag then S.markChanged() end
    end
end

-- trim one object to the vertical viewport [top,bot]. rectangles (and images marked in S.ClipCut: vertically
-- uniform washes) are physically cut (position + height shrunk) so the part outside the UI is truly gone.
-- glyphs / knobs / other images can't be cut: they fade out over S.Const.CLIP_FADE px BEFORE reaching the edge
-- and are fully transparent once any part crosses it, so nothing ever draws past the card / window edge.
-- `mul` is an extra alpha (row show/hide fade).
S.ClipCut = setmetatable({}, { __mode = "k" })
function S.clipEdgeK(y0, y1, top, bot)
    local F = S.Const.CLIP_FADE or 8
    return math.max(0, math.min(1, (y0 - top) / F, (bot - y1) / F))
end
function S.clipObj(o, top, bot, mul)
    S.drawClip(o, top, bot)
    if not o or not o.Visible then return end
    mul = mul or 1
    local s = S.Shapes[o]
    local c = (s == "Image") and S.Crop[o]
    if c then
        local p, sz = o.Position, o.Size
        -- still the rect we cut last frame (no relayout since): work from the layout's uncut rect, not the cut one
        if c.cy and c.gen == S.layoutGen then
            p, sz = Vector2.new(c.bx, c.by), Vector2.new(sz.X, c.bh)
        end
        c.cy = nil
        local y0, y1 = p.Y, p.Y + sz.Y
        if y1 <= top or y0 >= bot or sz.Y <= 0 then o.Visible = false return end
        if not c.px then -- not decoded (yet / unsupported): hide it whole once it reaches the edge, never fade
            if y0 < top or y1 > bot then o.Visible = false return end
            o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * mul
            return
        end
        local key = "full"
        if y0 < top or y1 > bot then
            local r0 = math.floor((math.max(y0, top) - y0) / sz.Y * c.h + 0.5)
            local r1 = math.floor((math.min(y1, bot) - y0) / sz.Y * c.h + 0.5)
            if r1 - r0 < 1 then o.Visible = false return end
            key, c.r0, c.r1 = r0 * 65536 + r1, r0, r1
            c.bx, c.by, c.bh, c.gen = p.X, y0, sz.Y, S.layoutGen
            c.cy, c.ch = y0 + r0 / c.h * sz.Y, (r1 - r0) / c.h * sz.Y
            o.Position = Vector2.new(p.X, c.cy)
            o.Size = Vector2.new(sz.X, c.ch)
        elseif o.Position.Y ~= p.Y or o.Size.Y ~= sz.Y then
            o.Position, o.Size = p, sz -- back to whole after being cut
        end
        if c.key ~= key then
            c.key = key
            o.Data = (key == "full") and c.data or S.cropTGA(c, c.r0, c.r1)
        end
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * mul
        return
    end
    if s == "Image" and S.ClipCut[o] then s = "Square" end
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
        local k = S.clipEdgeK(p.Y, p.Y + hgt, top, bot)
        if k <= 0 then o.Visible = false return end
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * k * mul
    elseif s == "Circle" then
        local p = o.Position
        local r = tonumber(o.Radius) or 5
        local k = S.clipEdgeK(p.Y - r, p.Y + r, top, bot)
        if k <= 0 then o.Visible = false return end
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * k * mul
    elseif s == "Image" then
        -- images that aren't uniform top-to-bottom (glows, avatars) can't be cut without squashing
        local p, sz = o.Position, o.Size
        local k = S.clipEdgeK(p.Y, p.Y + sz.Y, top, bot)
        if k <= 0 then o.Visible = false return end
        o.Transparency = (S.Bases[o] or 1) * S.Cfg.opacity * k * mul
    end
end

function S.clipRows()
    local page = S.Pages[S.activeTab]
    if not page or not S.Win.visible then return end
    local top = S.Win.y + S.TB + 2
    local bot = S.Win.y + S.Win.h - 6
    for _, sec in ipairs(page.sections) do
        S.clipObj(sec.hdr, top, bot, sec.inK)
        -- The shared scrollbar clips its track, thumb and glow together in S.Scroll.paint.
        for _, row in ipairs(sec.rows) do
            if row.live then
                local mul = (row.clipMul or 1) * (sec.inK or 1)
                -- rows of a card with a custom height are also cut to the card
                local t2, b2 = math.max(top, row.cTop or top), math.min(bot, row.cBot or bot)
                for _, o in ipairs(S.rowObjs(row)) do S.clipObj(o, t2, b2, mul) end
                -- streamer mode: Home hero avatar stays hidden (sidebar avatar is handled in the footer pass)
                if row.kind == "hero" and S.Cfg.streamer then row.img.Visible = false end
            end
        end
    end
end

-- ========== FX runtime: ripples, shimmer, goo, glow, intro ==========
-- button ripple: a circle grows from the click and fades. Drawings can't be clipped, so it's drawn as one
-- 1px Line per physical pixel row, each cut to the circle and to the button's rounded rect.
S.Ripple = { lines = {}, used = 0 }
S.Const.RIP_LINES = 120 -- physical rows of a 72 px tile at up to 160% UI scale
function S.rippleBox(row, idx)
    if row.kind == "tab" then -- sidebar tab: the highlight's rect
        return S.Win.x + 6, S.itemsTop() + (row.idx - 1) * S.Const.ITEM_H + 2, math.max(8, S.Sb.cur - 12), S.Const.ITEM_H - 8
    end
    local r = row.rect
    if row.kind == "tiles" then
        local tr = row.tileRects[idx]
        if tr then return tr[1], tr[2], tr[3], tr[4] end
    end
    if row.kind == "discord" then
        local br = row.btnRects[idx]
        if br then return br[1], br[2], br[3], br[4] end
    end
    if row.kind == "dropdown" then
        local bw = row.boxW or 135
        return r.x + r.w - 12 - bw, r.y + 6, bw, 22
    end
    if row.kind == "buttonrow" then
        local bw = row.bw or 60
        return r.x + 12 + (idx - 1) * (bw + 8), r.y + 4, bw, row.h - 8
    end
    return r.x + 12, r.y + 4, r.w - 24, row.h - 8
end
function S.addRipple(row, idx, mx, my)
    if not S.animOn() or not row.rect or S.Cfg.ripples == false then return end
    local rp = S.Ripple
    local z = row.ripZ or 34
    if #rp.lines == 0 then
        for k = 1, S.Const.RIP_LINES do
            rp.lines[k] = S.New("Line", { Color = S.Theme.White, Thickness = 1, Transparency = 0, ZIndex = z, Visible = false })
        end
    elseif rp.z ~= z then
        for _, l in ipairs(rp.lines) do l.ZIndex = z end
    end
    local bx, by = S.rippleBox(row, idx)
    rp.row, rp.idx, rp.z = row, idx, z
    rp.t0, rp.ox, rp.oy, rp.tab = os.clock(), mx - bx, my - by, S.activeTab
end

function S.updateRipples()
    local rp = S.Ripple
    local row = rp.row
    if not row then return end
    local age, K = os.clock() - rp.t0, S.K
    local used = 0
    -- A tab ripple outlives the tab switch it caused; a control's ripple ends with its page.
    local live = row.kind == "tab" or (row.vis and row.rect and S.activeTab == rp.tab)
    if age < 0.55 and S.Win.visible and live and S.animOn() and S.Cfg.ripples ~= false then
        local bx, by, bw, bh = S.rippleBox(row, rp.idx)
        local k = age / 0.55
        local rad2 = (1 - (1 - k) ^ 3) ^ 2 * (bw * bw + bh * bh)
        local cr = math.min(S.CR(4), bh / 2)
        local top, bot = S.Win.y + (row.kind == "tab" and 0 or S.TB + 2), S.Win.y + S.Win.h - 6
        top, bot = math.max(top, row.cTop or top), math.min(bot, row.cBot or bot)
        local cx, cy = bx + rp.ox, by + rp.oy
        local a = 0.22 * (1 - k) * S.Cfg.opacity * (row.clipMul or 1)
        local first = math.floor(by * K + 0.5)
        local last = math.min(first + #rp.lines - 1, math.floor((by + bh) * K + 0.5) - 1)
        for py = first, last do
            local yy = (py + 0.5) / K
            local dy = yy - cy
            if yy > top and yy < bot and rad2 > dy * dy then
                local hw = math.sqrt(rad2 - dy * dy)
                local e = math.min(yy - by, by + bh - yy)
                local ins = (e < cr) and (cr - math.sqrt(math.max(0, cr * cr - (cr - e) ^ 2))) or 0
                local xa, xb = math.max(bx + ins, cx - hw), math.min(bx + bw - ins, cx + hw)
                if xb > xa then
                    used += 1
                    local ln = rp.lines[used]
                    ln.From, ln.To = Vector2.new(xa, yy), Vector2.new(xb, yy)
                    ln.Color, ln.Transparency = S.Theme.White, a
                    if used > rp.used then ln.Visible = true end
                end
            end
        end
    else
        rp.row = nil
    end
    for i = used + 1, rp.used do rp.lines[i].Visible = false end
    rp.used = used
end

-- loading shimmer: a soft light band sweeps along a progress bar's filled part while it's under 100%
function S.fxProgress(row)
    local active = S.animOn() and S.Win.visible and row.vis and row.barX and row.shown > 0.002 and row.value < 0.999
    local fill = active and math.floor(row.barW * math.clamp(row.shown, 0, 1) + 0.5) or 0
    local CW = 6
    local n = math.ceil(fill / CW)
    if n > 0 then
        row.shim = row.shim or {}
        local top, bot = S.Win.y + S.TB + 2, S.Win.y + S.Win.h - 6
        top, bot = math.max(top, row.cTop or top), math.min(bot, row.cBot or bot)
        local band = 46
        local sx = row.barX - band + (S.runT * 240) % (fill + band * 2)
        for i = 1, n do
            local c = row.shim[i]
            if not c then
                c = S.New("Square", { Filled = true, Color = S.Theme.White, Transparency = 0, ZIndex = 35, Visible = false })
                row.shim[i] = c
            end
            local x0 = row.barX + (i - 1) * CW
            local w = math.min(CW, row.barX + fill - x0)
            local d = (x0 + w / 2 - sx) / (band * 0.45)
            local a = 0.5 * math.exp(-d * d)
            c.Position, c.Size, c.Color = Vector2.new(x0, row.barY), Vector2.new(w, 5), S.Theme.White
            S.Bases[c] = a
            c.Visible = a > 0.02
            S.clipObj(c, top, bot, row.clipMul or 1)
        end
    end
    if row.shim then for i = n + 1, #row.shim do S.Bases[row.shim[i]] = 0 row.shim[i].Visible = false end end
end

-- goo overscroll: pushing past either end of a page stretches it (page.over px, + = past the bottom) and a soft
-- accent bulge grows from that edge; both spring back with a little wobble once let go
-- Overlay and Spotlight glow follow the "Window glow" setting.
function S.haloOn() return S.glowsOn() and S.Cfg.winGlow ~= false end
function S.overPush(page, px, vel)
    if not S.animOn() or S.Cfg.overscroll == false then return end
    if px then page.over, page.overV, page.overHeld = px, 0, true end
    if vel then page.overV = math.clamp((page.overV or 0) + vel, -1400, 1400) end
end
function S.updateOver(page, dt)
    local o, v = page.over or 0, page.overV or 0
    if S.Cfg.perfMode then
        page.over, page.overV, page.overHeld = 0, 0, false
    elseif page.overHeld then
        page.overHeld = false
    elseif o ~= 0 or v ~= 0 then
        v = (v - o * 200 * dt) * math.exp(-11 * dt)
        o = math.clamp(o + v * dt, -60, 60)
        if math.abs(o) < 0.05 and math.abs(v) < 2 then o, v = 0, 0 end
        page.over, page.overV = o, v
    end
    if (page.over or 0) ~= 0 or page.overShown then S.Win.dirty = true end
    page.overShown = (page.over or 0) ~= 0
    local g, geo = S.D.overGlow, page.geo
    if not g then return end
    local m = math.abs(page.over or 0)
    if S.glowsOn() and geo and geo.visTop and m > 0.3 and S.Win.visible then
        local hgt = 8 + m * 1.8
        local cyy = (page.over < 0) and (geo.visTop + hgt * 0.45) or (geo.visBot - hgt * 0.45)
        S.FX.place(g, geo.cx + geo.cw / 2, cyy, geo.cw * (0.5 + 0.3 * math.min(1, m / 40)), hgt)
        g.Color, g.Transparency, g.Visible = S.Theme.C1, math.min(1, m / 22) * 0.6 * S.Cfg.opacity, true
    else
        g.Visible = false
    end
end

-- window glow: a soft accent halo hugging the window, slowly breathing. The image is the window's rounded rect
-- blurred outward (inside left empty), made at 1/4 size and stretched; remade once a resize settles.
S.WinGlow = {}
function S.updateWinGlow(dt)
    local g = S.D.winGlow
    if not g then return end
    if S.Cfg.winGlow == false or not S.glowsOn() or S.Cfg.perfMode or not S.Win.visible then g.Visible = false return end
    local st, w, h, m = S.WinGlow, S.Win.w, S.Win.h, 9
    if st.w ~= w or st.h ~= h then
        st.pend = (st.pend or 0) + dt
        if st.pend > 0.25 or not st.w then
            st.pend = 0
            -- half size, mapped exactly onto the drawn area (rounded image size -> separate x / y scale).
            -- 32-bit TGA (no checksums) and only the edge band is computed: the middle is empty anyway.
            local cr = S.CR(8)
            local iw, ih = math.ceil((w + 2 * m) / 2), math.ceil((h + 2 * m) / 2)
            local sx, sy = (w + 2 * m) / iw, (h + 2 * m) / ih
            local ok, d = pcall(function()
                local b = buffer.create(18 + iw * ih * 4)
                buffer.writeu8(b, 2, 2) buffer.writeu16(b, 12, iw) buffer.writeu16(b, 14, ih)
                buffer.writeu8(b, 16, 32) buffer.writeu8(b, 17, 0x28) -- 8 alpha bits, top-left origin
                local band = math.ceil((m + cr + 2) / math.min(sx, sy))
                local function px(x, y)
                    local sd = S.FX.rrSD((x + 0.5) * sx, (y + 0.5) * sy, w / 2 + m, h / 2 + m, w / 2, h / 2, cr)
                    if sd >= 0 then
                        local k = sd / m
                        local a = math.floor(math.exp(-k * k * 4) * 255 + 0.5)
                        if a > 0 then buffer.writeu32(b, 18 + (y * iw + x) * 4, 0x00FFFFFF + a * 16777216) end
                    end
                end
                for y = 0, ih - 1 do
                    if y < band or y >= ih - band then
                        for x = 0, iw - 1 do px(x, y) end
                    else
                        for x = 0, math.min(band, iw) - 1 do px(x, y) end
                        for x = math.max(band, iw - band), iw - 1 do px(x, y) end
                    end
                end
                return buffer.tostring(b)
            end)
            if ok then
                g.Data = d
            else
                S.perfError("glow", d)
                print("LEGOSENSE|window glow: " .. tostring(d))
            end
            st.w, st.h = w, h
        end
    end
    g.Position = Vector2.new(S.Win.x - m, S.Win.y - m)
    g.Size = Vector2.new(w + 2 * m, h + 2 * m)
    g.Color = S.Theme.C1
    g.Transparency = (0.32 + 0.08 * math.sin(S.runT * 2.1)) * S.Cfg.opacity
    g.Visible = true
end

-- ========== background blur (needs Instances: never on Matcha) ==========
-- Region blur uses a nearly transparent Glass part 0.5 studs in front of the camera, sized to the
-- background's rect, inside a DepthOfField near-blur zone (< 3.5 studs); the Drawings sit on top, so the game
-- behind every background reads frosted. Full-screen blur (Spotlight) = a BlurEffect. The DoF is only enabled while
-- a glass is up, so nothing close to the camera (viewmodels) blurs with the menu closed.
-- shortcut: the glass is a plain rectangle, so the few pixels outside each rounded corner blur too; upgrade = per-corner inset parts.
S.Blur = { rects = {}, parts = {}, frame = 0, screen = 0, screenT = 0 }
S.Const.BLUR_INSET = 7.5
S.Const.BLUR_INSET_SMALL = 9.5
S.Const.BLUR_INSET_INTRO = 4.5
S.Const.BLUR_EDGE = { left = 0, right = 0, top = 0, bottom = 0 } -- extra px per edge (panels only)
S.Const.BLUR_EDGE0 = { left = 0, right = 0, top = 0, bottom = 0 } -- full-screen rects: never trimmed
S.Const.BLUR_Y_LESS = 0 -- Manual top/bottom inset equals the side inset minus this value.
-- The blur needs Roblox to render DepthOfField, which it only does at higher graphics quality (DevForum: in-game
-- graphics 8+, some setups 10+). Below that our near Glass sheets blur NOTHING and only hide see-through things behind
-- them (Glass never draws transparent parts / decals / particles / name tags / BillboardGuis behind it).
-- Place the sheets only when the current quality supports blur. Recheck every 2 s
-- because players can change graphics quality mid-game.
S.Const.BLUR_MIN_QUALITY = 8          -- in-game graphics slider (1-10)
S.Const.BLUR_MIN_RENDER_LEVEL = 15    -- automatic graphics: Rendering.QualityLevel (1-21), ~slider 8
function S.Blur.qualityOk()
    local now = os.clock()
    if S.Blur.qT and now - S.Blur.qT < 2 then return S.Blur.qOk end
    S.Blur.qT = now
    local ok = true
    pcall(function()
        local saved = UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value -- 0 = automatic, 1-10
        if saved > 0 then ok = saved >= S.Const.BLUR_MIN_QUALITY
        else ok = settings().Rendering.QualityLevel.Value >= S.Const.BLUR_MIN_RENDER_LEVEL end
    end)
    S.Blur.qOk = ok
    return ok
end
function S.Blur.on() return not S.Env.matcha and S.Cfg.bgBlur ~= false and not S.Cfg.perfMode and S.Blur.qualityOk() end
-- call every frame a background is shown (logical px); a rect not refreshed for 2 frames loses its glass.
-- The inset places the glass inside the panel so the blur can spread to its edge.
-- Omit the inset to use BLUR_INSET, or pass 0 for an untrimmed sheet.
function S.Blur.rect(key, x, y, w, h, inset)
    if not S.Blur.on() then return end
    -- per-place switches (Settings > Effects > Blur)
    local where = (key == "win" or key == "intro") and "blurWin" or (key == "tip" and "blurTips") or (key == "spot" and "blurSpot") or "blurOv"
    if S.Cfg[where] == false then return end
    local r = S.Blur.rects[key]
    if not r then r = {} S.Blur.rects[key] = r end
    r.x, r.y, r.w, r.h, r.f, r.inset = x, y, w, h, S.Blur.frame, inset
end
function S.Blur.ensure()
    if S.Blur.dof then return true end
    if S.Blur.failed then return false end
    local ok, e = pcall(function()
        local L = game:GetService("Lighting")
        local dof = Instance.new("DepthOfFieldEffect")
        dof.FarIntensity, dof.NearIntensity, dof.FocusDistance, dof.InFocusRadius, dof.Enabled = 0, 1, 53.5, 50, false
        dof.Name, dof.Parent = "LSBlur", L
        local be = Instance.new("BlurEffect")
        be.Size, be.Enabled, be.Name, be.Parent = 0, false, "LSBlurScreen", L
        S.Blur.dof, S.Blur.be = dof, be
    end)
    if not ok then
        S.Blur.failed = true
        S.perfError("blur", e)
        print("LEGOSENSE|blur: " .. tostring(e))
    end
    return ok
end
function S.Blur.part(key)
    local p = S.Blur.parts[key]
    if p and p.Parent then return p end
    p = Instance.new("Part")
    p.Name, p.Material, p.Transparency, p.Color = "LSGlass", Enum.Material.Glass, 0.98, Color3.new(1, 1, 1)
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
    p.Parent = workspace.CurrentCamera
    S.Blur.parts[key] = p
    return p
end
function S.Blur.drop(key)
    local p = S.Blur.parts[key]
    if p then pcall(function() p:Destroy() end) end
    S.Blur.parts[key], S.Blur.rects[key] = nil, nil
end
function S.Blur.clear(destroyFx)
    for key in pairs(S.Blur.parts) do S.Blur.drop(key) end
    S.Blur.rects = {}
    if S.Blur.dof then
        if destroyFx then
            pcall(function() S.Blur.dof:Destroy() S.Blur.be:Destroy() end)
            S.Blur.dof, S.Blur.be = nil, nil
        else
            S.Blur.dof.Enabled, S.Blur.be.Enabled = false, false
        end
    end
end
-- window blur. "Window": glass behind the menu only. "Full screen" (Settings > Effects > Blur): Spotlight's look, the
-- glass grows from the menu out to the whole screen as it opens (DoF strength is global, so it can't fade) + a light dim.
-- The window itself shows instantly; only the glass eases (open 0.2 s, close 0.14 s, ease-out cubic like Spotlight).
S.WinBlurT = 0
function S.winBlur(dt)
    if S.Cfg.perfMode then
        S.WinBlurT = 0
        if S.WinDim then S.WinDim.Visible = false end
        return
    end
    local full = S.Cfg.blurMode == "Full screen"
    local tgt = (S.Win.visible and full) and 1 or 0
    if S.animOn() then
        S.WinBlurT = tgt > S.WinBlurT and math.min(1, S.WinBlurT + dt / 0.2) or math.max(0, S.WinBlurT - dt / 0.14)
    else
        S.WinBlurT = tgt
    end
    local k = 1 - (1 - S.WinBlurT) ^ 3
    local okV, vp = pcall(S.vpLogical)
    if k > 0.001 and okV and vp then
        local x, y, w, h = S.Win.x * (1 - k), S.Win.y * (1 - k), S.Win.w + (vp.X - S.Win.w) * k, S.Win.h + (vp.Y - S.Win.h) * k
        S.Blur.rect("win", x, y, w, h, S.Const.BLUR_INSET * (1 - k))
    elseif S.Win.visible then
        S.Blur.rect("win", S.Win.x, S.Win.y, S.Win.w, S.Win.h)
    end
    local show = k > 0.001 and okV and vp and S.Blur.on() and S.Cfg.blurWin ~= false
    if show then
        if not S.WinDim then S.WinDim = S.New("Square", { Filled = true, Transparency = 0, ZIndex = 2, Visible = false }) end
        S.WinDim.Position, S.WinDim.Size, S.WinDim.Color = Vector2.new(0, 0), vp, S.Theme.Dark
        S.WinDim.Transparency = 0.12 * k * S.Cfg.opacity
    end
    if S.WinDim then S.WinDim.Visible = show and true or false end
end
-- bound at RenderPriority.Last: after the camera moved this frame, so the glass never trails it
-- At 1080p the DoF blur spreads about 11.5 screen px horizontally and 5 screen px vertically past the glass.
-- Inset each edge by the corresponding spread to bring the blur to the panel boundary.
-- Scale those distances with viewport height and divide by the UI scale to get logical pixels.
-- Library:BlurInset(...) switches to the manual values.
S.Const.BLUR_SPILL_PX = 11.5 -- left / right
S.Const.BLUR_SPILL_Y_PX = 5
function S.Blur.autoInset()
    if S.Const.blurManual then return end
    local okV, vy = pcall(function() return workspace.CurrentCamera.ViewportSize.Y end)
    local m = S.Const.BLUR_SPILL_PX * ((okV and vy and vy > 0) and vy / 1080 or 1) / (S.K or 1)
    S.Const.BLUR_INSET, S.Const.BLUR_INSET_SMALL, S.Const.BLUR_INSET_INTRO = m, m, m
end
function S.Blur.step(dt)
    local f = S.Blur.frame
    S.Blur.frame = f + 1
    if not next(S.Blur.rects) and not next(S.Blur.parts) and not S.Blur.dof then return end
    if not S.Blur.on() or not S.Blur.ensure() then
        if next(S.Blur.rects) or next(S.Blur.parts) or (S.Blur.dof and (S.Blur.dof.Enabled or S.Blur.be.Enabled)) then S.Blur.clear() end
        S.Blur.screenT = 0
        return
    end
    S.Blur.autoInset()
    local cam = workspace.CurrentCamera
    local cf = cam.CFrame
    local look, K = cf.LookVector, S.K
    local function at(x, y)
        local d = cam:ViewportPointToRay(x * K, y * K).Direction
        return cf:PointToObjectSpace(cf.Position + d * (0.5 / d:Dot(look)))
    end
    local any = false
    for key, r in pairs(S.Blur.rects) do
        if r.f >= f - 1 and r.w > 1 and r.h > 1 then
            local p = S.Blur.part(key)
            -- inset: DoF near blur bleeds ~10 px past the glass edge, so the glass stops 12 px inside the rect
            -- (blur then fades out right at the edge instead of spilling outside)
            local m = math.min(r.inset or S.Const.BLUR_INSET, r.w / 4, r.h / 4)
            -- Use a smaller automatic inset at the top and bottom because the blur spreads less vertically.
            local my = 0 -- 0 = full screen (Spotlight / full-screen blur)
            if m > 0 then
                if S.Const.blurManual then my = math.max(0.5, m - S.Const.BLUR_Y_LESS)
                else my = m * S.Const.BLUR_SPILL_Y_PX / S.Const.BLUR_SPILL_PX end -- measured vertical spread, same scaling
            end
            -- per-edge trim on top of that (Library:BlurInset("top"|"bottom"|"left"|"right", px), read off the ruler)
            local E = m > 0 and S.Const.BLUR_EDGE or S.Const.BLUR_EDGE0
            local gl, gt, gr, gb = r.x + m + E.left, r.y + my + E.top, r.x + r.w - m - E.right, r.y + r.h - my - E.bottom
            r.m, r.my, r.glass = m, my, { gl, gt, gr, gb }
            local a, b = at(gl, gt), at(gr, gb)
            p.Size = Vector3.new(math.abs(b.X - a.X), math.abs(b.Y - a.Y), 0.01)
            p.CFrame = cf * CFrame.new((a.X + b.X) / 2, (a.Y + b.Y) / 2, -0.5)
            -- debug view (Library:DebugBlur(true)): the glass shows as a red sheet, so its rect vs the panel is visible
            if S.Blur.debug then p.Transparency, p.Color = 0.55, Color3.fromRGB(255, 40, 40)
            -- black tint: a white Glass sheet catches the sun's specular + refraction streaks (the "shine", worse toward the
            -- screen edges where the view hits it at a steeper angle). Black keeps the DoF blur and drops the shine.
            -- Glass is required because DoF ignores SmoothPlastic sheets.
            else p.Transparency, p.Color = 0.98, Color3.new(0, 0, 0) end
            any = true
        else
            S.Blur.drop(key)
        end
    end
    S.Blur.dof.Enabled = any
    S.Blur.dof.NearIntensity = math.clamp((S.Cfg.blurStrength or 100) / 100, 0, 1)
    S.Blur.screenT = S.Blur.screenT + (S.Blur.screen - S.Blur.screenT) * (S.animOn() and math.min(1, dt * 14) or 1)
    if S.Blur.screenT < 0.2 and S.Blur.screen == 0 then S.Blur.screenT = 0 end
    S.Blur.be.Size, S.Blur.be.Enabled = S.Blur.screenT, S.Blur.screenT > 0
end

-- logo glyph: comet arc slowly orbiting a faint ring, centre dot breathing a little
function S.updateGlyph(dt)
    local G = S.Glyph
    if not G then return end
    local show = S.Win.visible and not UI.logoLoaded
    local perf = S.Cfg.perfMode
    if (not show and G.shown == false) or (perf and G.staticLayout == S.layoutGen and G.shown == show) then return end
    G.shown, G.staticLayout = show, perf and S.layoutGen or nil
    G.ring.Visible, G.dot.Visible = show, show
    local animate = show and not perf
    if not animate then
        if G.glow then G.glow.Visible = false end
        for _, l in ipairs(G.arc) do l.Visible = false end
        if not show then return end
    end
    local op = S.Cfg.opacity
    local cx, cy = S.Win.x + S.Const.SB_MIN / 2, S.Win.y + 24 -- centre of the collapsed sidebar / of the title + subtitle block
    G.ring.Position, G.ring.Radius, G.ring.Color, G.ring.Transparency = Vector2.new(cx, cy), 12, S.Theme.C1, 0.22 * op
    G.dot.Position, G.dot.Radius, G.dot.Color, G.dot.Transparency = Vector2.new(cx, cy), 2.2 + (animate and 0.3 * math.sin(S.runT * 2.2) or 0), S.Theme.White, op
    if not animate then return end
    G.ang = G.ang + dt * 1.1
    if G.glow then
        G.glow.Visible = S.glowsOn()
        if G.glow.Visible then
            S.FX.place(G.glow, cx, cy, 18)
            G.glow.Color, G.glow.Transparency = S.Theme.C1, 0.55 * op
        end
    end
    local n, len, r = #G.arc, math.pi * 1.2, 12
    for i = 1, n do
        local a0, a1 = G.ang - len * (1 - (i - 1) / n), G.ang - len * (1 - i / n)
        local l = G.arc[i]
        l.Visible = true
        l.From, l.To = Vector2.new(cx + math.cos(a0) * r, cy + math.sin(a0) * r), Vector2.new(cx + math.cos(a1) * r, cy + math.sin(a1) * r)
        l.Color = S.lerpColor(S.Theme.C2, S.Theme.C1, i / n)
        l.Transparency = (i / n) ^ 1.4 * op
    end
end

S.loadYield()
-- ========== intro ==========
-- shown by CreateWindow (Settings > Interface > Intro animation), centred on the window:
--   a small card (window background colour) pops in with a dot on it -> a comet orbits the dot shedding sparks while its tail grows into a full ring (the title types out
--   under it) -> 100%: a pulse ring flies out, the dot breathes, the ring holds 0.2 s -> the card TV-closes into a
--   line while the ring pulls in, the line stretches to the window's width (spring overshoot, glow streak) -> it
--   opens vertically to the full window (TV unfold) while the title flies to the logo spot -> the menu shows under the opened panel, the panel fades
--   away and a shine sweeps across. Ring, sparks and line run along the theme's two accent colours.
S.Const.INTRO = { POP = 0.25, LOAD = 1.4, HOLD = 0.2, PULL = 0.18, BURST = 0.4, OPEN = 0.55, HAND = 0.25, SHINE = 0.5, RING = 26, SB_HOLD = 0.3 }
S.Const.INTRO_SEG, S.Const.INTRO_SPARKS = 120, 64
function S.introAccent(u, t) -- u = 0..1 around the ring
    return S.lerpColor(S.Theme.C1, S.Theme.C2, 0.5 + 0.5 * math.sin(u * 2 * math.pi + t * 1.5))
end
function S.introStart()
    S.perfBootMark("introBuildStart")
    local I = { t = 0, objs = {}, seg = {}, sparks = {}, letters = {}, shine = {}, k = 0, kv = 0, ang = 0, sparkT = 0, sparkI = 1 }
    local function N(ty, p) p.Transparency, p.Visible = 0, true local o = S.New(ty, p) I.objs[#I.objs + 1] = o return o end
    local glowD, solidD = S.glowsOn() and S.FX.glow(), S.FX.solid()
    if glowD then I.glow = N("Image", { Data = glowD, Color = S.Theme.C1, ZIndex = 90, Size = Vector2.new(1, 1) }) end
    -- the card / line / opening panel: one shape in the window's background colour + see-through level
    if solidD then I.fill = N("Image", { Data = solidD, Color = S.Theme.Bg, ZIndex = 89, Size = Vector2.new(1, 1) })
    else I.fill = N("Square", { Filled = true, Color = S.Theme.Bg, ZIndex = 89 }) end
    I.pulse = N("Circle", { Filled = false, Radius = S.Const.INTRO.RING, NumSides = 96, Thickness = 2, Color = S.Theme.C1, ZIndex = 93 })
    for i = 1, S.Const.INTRO_SEG do I.seg[i] = N("Line", { Thickness = 3, Color = S.Theme.White, ZIndex = 94 }) end
    for i = 1, S.Const.INTRO_SPARKS do
        I.sparks[i] = { life = 0, ln = N("Line", { Thickness = 2, Color = S.Theme.White, ZIndex = 95 }),
            gl = glowD and N("Image", { Data = glowD, Color = S.Theme.C1, ZIndex = 94, Size = Vector2.new(1, 1) }) or nil }
    end
    I.dot = N("Circle", { Filled = true, Radius = 4, NumSides = 32, Color = S.Theme.White, ZIndex = 96 })
    -- TV unfold: the bright line splits into a top + bottom edge that ride the opening panel
    I.edgeT = N("Line", { Thickness = 2, Color = S.Theme.White, ZIndex = 94 })
    I.edgeB = N("Line", { Thickness = 2, Color = S.Theme.White, ZIndex = 94 })
    for i = 1, 90 do I.shine[i] = N("Square", { Filled = true, Color = S.Theme.White, ZIndex = 97 }) end
    local lx = 0
    for i = 1, #S.BRAND do
        local l = N("Text", { Text = S.BRAND:sub(i, i), Color = S.Theme.White, ZIndex = 96, Font = 0, Size = 18 })
        I.letters[i] = { d = l, x = lx }
        lx = lx + S.TW(l, S.CHAR_WB) + 3 -- a little letter spacing
    end
    I.titleW = lx - 3
    -- where each letter lands: the sidebar title (S.D.brand) at its own size, measured per prefix
    local m = S.New("Text", { Text = "", Font = 0, Size = S.FS + 4, Transparency = 0, Visible = false })
    for i, l in ipairs(I.letters) do
        m.Text = S.BRAND:sub(1, i - 1)
        l.tx = (i == 1) and 0 or S.TW(m, S.CHAR_WB)
    end
    S.freeObj(m)
    -- the menu opens with the sidebar already out so the title has somewhere to land; it closes again
    -- S.Const.INTRO.SB_HOLD after the intro ends (unless the mouse is on it). S.Sb.introHold is read by the sidebar target logic.
    S.Sb.introHold = true
    S.Sb.max = S.sbMax() -- the window's saved size may have just loaded: never snap to a stale width
    S.Sb.cur, S.Sb.from, S.Sb.to, S.Sb.target = S.Sb.max, S.Sb.max, S.Sb.max, S.Sb.max
    S.Intro = I
    S.perfBootMark("introStart")
end
-- open sidebar width: 27% of the window, clamped
function S.sbMax() return math.max(132, math.min(360, math.floor(S.Win.w * (S.Cfg.sbWidth or 27) / 100))) end
function S.introEnd()
    S.perfBootMark("introEndStart")
    local I = S.Intro
    S.Intro = nil
    if I then for _, o in ipairs(I.objs) do S.freeObj(o) end end
    S.perfBootMark("introDrawingsFreed")
    S.Sb.introHold = false
    S.Sb.holdUntil = os.clock() + S.Const.INTRO.SB_HOLD
    if not S.Win.visible then S.setVisible(true) end
    S.perfBootMark("introEnd")
end
function S.introSpark(I, ha, CX, CY)
    local s = I.sparks[I.sparkI]
    I.sparkI = I.sparkI % #I.sparks + 1
    -- peel off the comet head in a cone: outward + a little backward against the spin
    local cone, out, back = (math.random() - 0.5) * 1.1, 30 + math.random() * 70, 25 + math.random() * 35
    local RING = S.Const.INTRO.RING
    s.x, s.y = CX + math.cos(ha) * RING, CY + math.sin(ha) * RING
    s.vx = math.cos(ha + cone) * out + math.sin(ha) * back
    s.vy = math.sin(ha + cone) * out - math.cos(ha) * back
    s.size = 0.8 + math.random() ^ 2 * 2.4 -- mostly small, a few big
    s.life = 0.45 + math.random() * 0.4
    s.max, s.tw, s.u = s.life, math.random() * 6, (ha / (2 * math.pi)) % 1
end
function S.introUpdate(dt)
    local I, C = S.Intro, S.Const.INTRO
    if S.Cfg.perfMode then
        S.introEnd()
        S.Sb.holdUntil = nil
        return
    end
    I.t = I.t + dt
    local t, RING = I.t, C.RING
    local function sm(x) x = math.clamp(x, 0, 1) return x * x * (3 - 2 * x) end
    local WW, WH = S.Win.w, S.Win.h
    local CX, CY = S.Win.x + WW / 2, S.Win.y + WH / 2
    local tLoad0 = C.POP
    local tHold0 = tLoad0 + C.LOAD
    local tPull0 = tHold0 + C.HOLD
    local tBurst0 = tPull0 + C.PULL
    local tOpen0 = tBurst0 + C.BURST
    local tHand0 = tOpen0 + C.OPEN
    if t >= tHand0 + math.max(C.HAND, C.SHINE) then return S.introEnd() end
    if t >= tHand0 and not S.Win.visible then -- the menu shows under the opened panel, then cascades in
        S.perfBootMark("introRevealStart")
        S.setVisible(true)
        S.Casc, S.CascCards, S.CascSpeed = os.clock(), nil, nil
        S.perfBootMark("introRevealEnd")
    end
    local op = S.Cfg.opacity
    local pop = t < C.POP and (sm(t / C.POP) * (1 + 0.35 * math.sin(math.pi * math.min(1, t / C.POP)))) or 1
    local popA = math.min(1, pop)
    local p = math.clamp((t - tLoad0) / C.LOAD, 0, 1)
    local pe = 1 - (1 - p) ^ 2
    local pull = (t >= tPull0 and t < tBurst0) and sm((t - tPull0) / C.PULL) or (t >= tBurst0 and 1 or 0)
    local burst, full = t >= tBurst0, t >= tHold0
    local holdK = (full and not burst) and math.sin(math.min(1, (t - tHold0) / (C.HOLD + C.PULL)) * math.pi) or 0
    local hand = sm((t - tHand0) / C.HAND) -- 0 -> 1 while the panel fades off the menu
    local white = S.Theme.White

    -- dot (breathes during the hold)
    I.dot.Position = Vector2.new(CX, CY)
    I.dot.Radius = 4 * pop * (1 - 0.7 * pull) + 2.2 * holdK
    I.dot.Transparency = (burst and math.max(0, 1 - (t - tBurst0) / 0.15) or popA) * op

    -- ring -> one wide line (spring)
    if burst then
        I.kv = (I.kv + (1 - I.k) * 260 * dt) * math.exp(-12 * dt)
        I.k = I.k + I.kv * dt
    end
    local r0 = RING * (1 - 0.25 * pull) * popA
    I.ang = I.ang + dt * (burst and 0 or (6.5 - 4 * pe))
    local len = (0.5 + 1.5 * pe ^ 1.5) * math.pi
    local n = #I.seg
    -- the centre line hands over to the top/bottom edges (I.edgeT/B) the instant the unfold starts: one line splitting in two
    -- Hide the centre line immediately so it cannot linger between the moving edges.
    local outF = t >= tOpen0 and 0 or 1
    local pts = {}
    for i = 1, n do
        local a = (i - 1) / n * 2 * math.pi - math.pi / 2
        -- flat ellipse WW wide, 1.5 px tall: radius along angle a
        local line = 1 / math.sqrt((math.cos(a) / (WW / 2)) ^ 2 + (math.sin(a) / 1.5) ^ 2)
        local r = r0 + (line - r0) * math.max(0, I.k)
        if not burst then a = a + I.ang end
        pts[i] = Vector2.new(CX + math.cos(a) * r, CY + math.sin(a) * r)
    end
    local burstCol = burst and math.min(1, (t - tBurst0) / 0.4) or 0.25
    for i = 1, n do
        local s = I.seg[i]
        s.From, s.To = pts[i], pts[i % n + 1]
        local alpha = 1
        if not full then
            local u = i / n * 2 * math.pi
            alpha = u <= len + 1e-3 and math.clamp(u / len, 0, 1) ^ (1.4 * (1 - p)) or 0
        end
        s.Transparency = alpha * popA * outF * op
        s.Thickness = burst and (3 - math.min(1, I.k)) or 3
        s.Color = S.lerpColor(white, S.introAccent(i / n, t), burstCol)
    end

    -- sparks: shed from the comet head while loading, flung outward when the ring bursts
    if not full and t > tLoad0 then
        I.sparkT = I.sparkT + dt
        local rate = 0.03 + (0.014 - 0.03) * pe
        while I.sparkT > rate do I.sparkT = I.sparkT - rate S.introSpark(I, len + I.ang - math.pi / 2, CX, CY) end
    end
    if burst and not I.flung then
        I.flung = true
        for _, s in ipairs(I.sparks) do
            if s.life > 0 then
                local dx, dy = s.x - CX, s.y - CY
                local d = math.max(1, math.sqrt(dx * dx + dy * dy))
                s.vx, s.vy = s.vx + dx / d * 260, s.vy + dy / d * 260
                s.life = math.max(s.life, 0.35) s.max = math.max(s.max, s.life)
            end
        end
    end
    local drag = math.exp(-2.6 * dt)
    for _, s in ipairs(I.sparks) do
        if s.life > 0 then
            s.life = s.life - dt
            s.vx, s.vy = s.vx * drag, s.vy * drag
            s.x, s.y = s.x + s.vx * dt, s.y + s.vy * dt
            local lk = math.max(0, s.life / s.max)
            local a = lk ^ 1.3 * (0.75 + 0.25 * math.sin(t * 22 + s.tw)) * op
            local sz = s.size * (0.4 + 0.6 * lk)
            local streak = 0.045 * (0.5 + 0.5 * lk)
            local col = S.lerpColor(white, S.introAccent(s.u, t), 1 - lk)
            s.ln.From, s.ln.To = Vector2.new(s.x, s.y), Vector2.new(s.x - s.vx * streak, s.y - s.vy * streak)
            s.ln.Thickness, s.ln.Color, s.ln.Transparency = sz, col, a
            if s.gl then
                if s.size > 2 then
                    S.FX.place(s.gl, s.x, s.y, sz * 7)
                    s.gl.Color, s.gl.Transparency = col, S.glowsOn() and a * 0.5 or 0
                else s.gl.Transparency = 0 end
            end
        else
            s.ln.Transparency = 0
            if s.gl then s.gl.Transparency = 0 end
        end
    end

    -- pulse ring when the load completes
    if full and t < tHold0 + 0.45 then
        local pk = sm((t - tHold0) / 0.45)
        I.pulse.Position, I.pulse.Radius = Vector2.new(CX, CY), RING * (1 + 1.8 * pk)
        I.pulse.Color, I.pulse.Transparency = S.introAccent(0, t), (1 - pk) * 0.8 * op
    else I.pulse.Transparency = 0 end

    -- glow: pulses with the load, flattens into a streak with the line, fades as the panel opens
    if I.glow then
        local flash = burst and math.max(0, 1 - (t - tBurst0) / 0.45) or 0
        local kk = math.min(1, math.max(0, I.k))
        local gw = burst and (RING * 6 + (WW * 1.15 - RING * 6) * kk) or (RING * 6 * (1 + 0.08 * math.sin(t * 4)))
        local gh = burst and (RING * 6 + (60 - RING * 6) * kk) or gw
        S.FX.place(I.glow, CX, CY, gw, gh)
        local ga = burst and (0.35 + 0.65 * flash) or (0.35 + 0.35 * pe + (full and 0.3 or 0))
        I.glow.Color = S.introAccent(0.25, t)
        I.glow.Transparency = S.glowsOn() and math.min(1, ga) * popA * (1 - sm((t - tOpen0) / 0.2)) * op or 0 -- gone fast: it sits at the centre
    end

    -- card -> TV close into a line -> line stretches to the window width -> TV open to the full window -> fades off
    local cardW, cardH, cardY = 220, 170, CY + 14
    local ok = math.clamp((t - tOpen0) / C.OPEN, 0, 1)
    local openK = sm((ok - 0.08) / 0.85)
    local fw, fh, fy
    if t < tPull0 then
        local s2 = 0.92 + 0.08 * popA
        fw, fh, fy = cardW * s2, cardH * s2, cardY
    elseif t < tBurst0 then
        local c = (t - tPull0) / C.PULL
        c = c * c -- TV close: accelerates shut
        fw, fh, fy = cardW, cardH + (2 - cardH) * c, cardY + (CY - cardY) * c
    elseif t < tOpen0 then
        fw, fh, fy = cardW + (WW - cardW) * math.max(0, I.k), 2, CY
    else
        fw, fh, fy = WW, math.max(2, WH * openK), CY
    end
    I.fill.Position, I.fill.Size = Vector2.new(CX - fw / 2, fy - fh / 2), Vector2.new(fw, fh)
    pcall(function() I.fill.Rounding = math.min(S.CR(8), fh / 2) end) -- same corners as the window
    I.fill.Color = S.Theme.Bg
    -- opening: starts near solid (reads as the line widening) and settles to the window's own ALPHA_BG
    local fillA = (t >= tOpen0) and (S.Const.ALPHA_BG + (0.94 - S.Const.ALPHA_BG) * (1 - openK)) or S.Const.ALPHA_BG
    I.fill.Transparency = fillA * popA * (1 - hand) * op
    do -- edges: bright through most of the unfold, fade over its last 40% + the hand-over
        local on = t >= tOpen0
        local e = on and (1 - sm((ok - 0.6) / 0.4)) or 0
        local r = math.min(S.CR(8), fh / 2)
        local x0, x1 = CX - fw / 2 + r, CX + fw / 2 - r
        local col = S.lerpColor(white, S.introAccent(0.25, t), 0.35 + 0.4 * openK)
        I.edgeT.From, I.edgeT.To = Vector2.new(x0, fy - fh / 2), Vector2.new(x1, fy - fh / 2)
        I.edgeB.From, I.edgeB.To = Vector2.new(x0, fy + fh / 2), Vector2.new(x1, fy + fh / 2)
        I.edgeT.Color, I.edgeB.Color = col, col
        I.edgeT.Transparency, I.edgeB.Transparency = e * op, e * op
    end
    if popA * (1 - hand) > 0.3 then S.Blur.rect("intro", CX - fw / 2, fy - fh / 2, fw, fh, S.Const.BLUR_INSET_INTRO) end

    -- shine sweep across the window once it's open
    local sk = (t - tHand0) / C.SHINE
    local cols = math.min(#I.shine, math.floor((WW - 2 * S.CR(8)) / 8))
    for i, c in ipairs(I.shine) do
        if i <= cols and sk > 0 and sk < 1 then
            local x = S.Win.x + S.CR(8) + (i - 1) * 8
            local d = (x + 4 - (S.Win.x - 60 + sk * (WW + 120))) / 40
            c.Position, c.Size = Vector2.new(x, S.Win.y + 1), Vector2.new(8, WH - 2)
            c.Transparency = 0.09 * math.exp(-d * d) * op
        else c.Transparency = 0 end
    end

    -- title: types in under the ring, flies onto the sidebar title (S.D.brand: x + 52, y + 8, accent colour)
    -- during the burst + open, then hands over to it: the real title shows at tHand0 at the same spot and size
    local shown = math.floor(math.max(0, t - 0.2) * 16)
    local fly = burst and sm((t - tBurst0) / (C.BURST + C.OPEN)) or 0
    local tSize = S.FS + 4
    local tCol = S.lerpColor(white, S.Theme.C1, fly)
    for i, l in ipairs(I.letters) do
        local li = math.clamp(shown - i + 1, 0, 1)
        local hx, hy = CX - I.titleW / 2 + l.x, CY + RING + 24 - 6 * (1 - li)
        -- stagger: later letters leave a touch later, so the word streams in rather than moving as a block
        local f = sm((fly - (i - 1) * 0.025) / (1 - (#I.letters - 1) * 0.025))
        local tx, ty = S.Win.x + 52 + l.tx, S.Win.y + 8
        l.d.Position = Vector2.new(hx + (tx - hx) * f, hy + (ty - hy) * f - 18 * math.sin(f * math.pi))
        l.d.Size = 18 + (tSize - 18) * f
        l.d.Color = tCol
        l.d.Transparency = li * (1 - hand) * op
    end
end

function S.frame()
    local now = os.clock()
    local frameDelta = math.min(now - S.lastClock, 0.1)
    local dt = frameDelta * ((S.Cfg.animSpeed or 100) / 100) -- Settings > Effects > Animation speed
    S.lastClock = now
    S.frameDt = dt
    S.runT = S.runT + dt

    if S.UIS then local p = S.UIS:GetMouseLocation() S.In.x, S.In.y = p.X / S.K, p.Y / S.K
    elseif S.mouse then S.In.x, S.In.y = S.mouse.X / S.K, S.mouse.Y / S.K end
    S.In.wasDown = S.In.down
    S.In.down = ismouse1pressed()
    if #S.KeyRows > 0 then S.pollKeyRows() end
    S.In.pressed = S.In.down and not S.In.wasDown
    S.In.released = (not S.In.down) and S.In.wasDown
    do local d2 = ismouse2pressed() S.In.rpressed = d2 and not S.In.down2 S.In.down2 = d2 end
    if S.ctxUpdate(dt) then S.In.pressed = false end
    if S.In.rpressed and not S.Ctx.open then S.ctxFromRow() end
    S.perfSection("overlays")
    S.spotUpdate(dt)
    S.perfSection("other")
    S.updateGrip(dt)
    if S.Dlg then
        S.perfSection("overlays")
        S.updateDialog(dt)
        S.perfSection("other")
    end
    if #S.Toasts > 0 then
        S.perfSection("toasts")
        S.updateToasts(dt)
        S.perfSection("other")
    end

    local okVp, vp = pcall(function() return S.vpLogical() end)
    S.vpChanged = okVp and vp ~= nil and (not S.vp or vp.X ~= S.vp.X or vp.Y ~= S.vp.Y)
    if S.vpChanged then S.vp = vp end
    -- window: never bigger than the screen minus the edge gap, never past it (covers drags, resizes, loaded configs, screen changes)
    if S.vp then
        local m = S.Const.EDGE
        local w = math.max(S.Const.MIN_W, math.min(S.Win.w, S.vp.X - m * 2))
        local h = math.max(S.Const.MIN_H, math.min(S.Win.h, S.vp.Y - m * 2))
        local x, y = S.clampRect(S.Win.x, S.Win.y, w, h)
        if x ~= S.Win.x or y ~= S.Win.y or w ~= S.Win.w or h ~= S.Win.h then
            S.Win.x, S.Win.y, S.Win.w, S.Win.h = x, y, w, h
            S.Win.dirty = true
        end
    end

    if UI.created and not S.Intro and not S.Capture.row and not S.Focus.row and not S.Pick.hexFocus and not S.Drop.open and not S.Search.active then
        local k = iskeypressed(S.Cfg.menuKey)
        if k and not S.keyWas then S.setVisible(not S.Win.visible) end
        S.keyWas = k
    end

    S.perfSection("snow")
    S.updateSnow(frameDelta, S.runT)
    S.perfSection("overlays")
    S.updateOverlays(dt)
    if S.Intro then
        S.perfSection("intro")
        local okI, eI = pcall(S.introUpdate, dt)
        if not okI then
            S.perfError("intro", eI)
            print("LEGOSENSE|intro error: " .. tostring(eI))
            S.introEnd()
        end
    end
    S.perfSection("other")
    if S.Ripple.row then S.updateRipples() end
    if not S.Win.visible and S.D.winGlow then S.D.winGlow.Visible = false end
    if not S.Win.visible then S.updateGlyph(dt) end -- hides it

    if not S.Win.visible then -- full-screen glass shrinks back after the menu closes
        S.perfSection("glassBlurRects")
        S.winBlur(dt)
        return
    end

    local x, y, w, h = S.Win.x, S.Win.y, S.Win.w, S.Win.h
    S.Sb.max = S.sbMax()

    if (S.Cfg.preset == "Rainbow" or S.Cfg.preset == "Nyan") and not S.Cfg.perfMode then
        S.hue = (S.hue + dt * (S.Cfg.rainbowSpeed / 100) * 0.15) % 1
        S.Theme.C1 = S.hsv2rgb(S.hue, 0.5, 0.85)
        S.Theme.C2 = S.hsv2rgb((S.hue + 0.08) % 1, 0.55, 0.9)
        if S.Cfg.preset == "Rainbow" then
            S.Theme.Dark = S.hsv2rgb(S.hue, 0.55, 0.32)   -- sidebar + topbar cycle too; light Mono bg stays
        end
        S.Win.dirty = true
    end

    -- nyan background frame animation (swaps Data + touches Position so Matcha re-decodes)
    if S.D.nyan.Visible and not S.Cfg.perfMode and #S.Const.NYAN_FRAMES > 1 and UI.nyanData and UI.nyanRect then
        S.nyanClock = S.nyanClock + dt
        local n = #S.Const.NYAN_FRAMES
        local idx = (math.floor(S.nyanClock * S.Const.NYAN_FPS) % n) + 1
        local frames = UI.nyanBlurFrames or UI.nyanData
        if idx ~= UI.nyanCur and frames[idx] then
            pcall(function()
                S.D.nyan.Data = frames[idx]
                S.D.nyan.Position = Vector2.new(UI.nyanRect.x, UI.nyanRect.y)
            end)
            UI.nyanCur = idx
        end
    end

    -- dropdown open/close animation (slide + fade); teardown happens when the close anim finishes
    if S.Drop.open then
        local target = S.Drop.closing and 0 or 1
        local dE = S.animOn() and (1 - (0.00003 ^ dt)) or 1
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
                local keep = false
                if #S.Drop.searchBuf > 0 and f[1] then keep = S.dropPick(S.Drop.open, f[1]) end
                if keep then S.Drop.searchBuf = "" else S.closeDropdown() end
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
        -- a left click after the one that started listening binds MB1 (Esc cancels)
        if S.Capture.row and S.In.pressed and os.clock() - (S.Capture.t or 0) > 0.05 then
            S.Capture.row.vk = 0x01
            if S.Capture.row.onChange then pcall(S.Capture.row.onChange, 0x01) end
            if S.Capture.row.flag then S.markChanged() end
            S.Capture.row = nil
        end
        S.Win.dirty = true
    elseif S.Focus.row then
        local row = S.Focus.row
        if row.kind == "slider" then
            S.pollTyping(
                function(ch)
                    if ch:match("[%d%.%-]") and #(row.buf or "") < 8 then row.buf = (row.buf or "") .. ch end
                end,
                function() row.buf = (row.buf or ""):sub(1, -2) end,
                function()
                    local v = tonumber(row.buf)
                    if v then
                        v = S.snapSlider(row, v)
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
            -- Numeric: digits . - only. Finished: callback only on Enter / clicking away, not per key.
            S.pollTyping(
                function(ch)
                    if row.numeric and not ch:match("[%d%.%-]") then return end
                    row.value = row.value .. ch
                    if not row.finished then S.fireRow(row) end
                end,
                function() row.value = row.value:sub(1, -2) if not row.finished then S.fireRow(row) end end,
                function() if row.finished then S.fireRow(row) end S.Focus.row = nil end
            )
            if S.In.pressed and row.rect and not S.inRect(S.In.x, S.In.y, row.rect.x, row.rect.y, row.rect.w, row.rect.h) then
                if row.finished then S.fireRow(row) end
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
    if S.Cfg.sidebarMode == "Expanded" then S.Sb.target = S.Sb.max end
    -- intro: held open while it plays and for SB_HOLD after (title lands there first, then it tucks away)
    if S.Sb.introHold or (S.Sb.holdUntil and now < S.Sb.holdUntil) then S.Sb.target = S.Sb.max end
    local ease = S.animOn() and (1 - (0.0000001 ^ dt)) or 1
    -- Sidebar open/close uses a timed sine ease-out (0.26 s) that lands exactly on the target.
    if S.Sb.target ~= S.Sb.to then S.Sb.from, S.Sb.to, S.Sb.t0 = S.Sb.cur, S.Sb.target, now end
    if S.Sb.cur ~= S.Sb.to then
        local p = S.animOn() and math.min(1, (now - S.Sb.t0) / 0.26) or 1
        local e = math.sin(p * math.pi / 2)
        S.Sb.cur = (p >= 1) and S.Sb.to or (S.Sb.from + (S.Sb.to - S.Sb.from) * e)
        S.Win.dirty = true
    end

    local targetHY = (S.activeTab <= #S.Tabs) and (S.activeTab - 1) * S.Const.ITEM_H or S.hiliteY
    local newHY = S.hiliteY + (targetHY - S.hiliteY) * ease
    if math.abs(newHY - S.hiliteY) > 0.1 then
        S.hiliteY = newHY
        S.Win.dirty = true
    end
    -- goo: the highlight's far end trails behind, so it stretches between tabs and pulls back together
    do
        local tailE = S.animOn() and (1 - (0.0004 ^ dt)) or 1
        local nt = (S.hiliteT or S.hiliteY) + (S.hiliteY - (S.hiliteT or S.hiliteY)) * tailE
        if math.abs(nt - S.hiliteY) < 0.1 then nt = S.hiliteY end
        if nt ~= S.hiliteT then S.hiliteT = nt S.Win.dirty = true end
    end

    if S.In.pressed and not S.Capture.row then
        local consumed = false
        do local p = S.curPage() if p then p.momentum = 0 end end

        -- layout editor toggle / reset
        if S.PencilRect and S.inRect(S.In.x, S.In.y, S.PencilRect.x, S.PencilRect.y, S.PencilRect.w, S.PencilRect.h) then
            S.LayoutEdit = not S.LayoutEdit
            S.closeDropdown() S.closePicker()
            if not S.LayoutEdit then S.markChanged() end
            S.Win.dirty = true
            consumed = true
        elseif S.ResetRect and S.inRect(S.In.x, S.In.y, S.ResetRect.x, S.ResetRect.y, S.ResetRect.w, S.ResetRect.h) then
            S.resetLayout(S.activeTab)
            consumed = true
        end

        -- search field + results popout take clicks first
        if not consumed and S.Search.rect and S.inRect(S.In.x, S.In.y, S.Search.rect.x, S.Search.rect.y, S.Search.rect.w, S.Search.rect.h) then
            S.closeDropdown() S.closePicker()
            S.Search.active = true
            S.buildSearch()
            S.Win.dirty = true
            consumed = true
        elseif S.Search.active then
            -- geom is nil while there are no results; any outside click must still blur the field
            local g = S.Search.geom
            if g and S.inRect(S.In.x, S.In.y, g.px, g.py, g.pw, g.n * g.rowH + 8) then
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
            elseif S.Pick.open.hasAlpha and S.inRect(S.In.x, S.In.y, gx, S.Pick.ay or 0, gridW, 14) then
                S.Pick.a = math.max(0, math.min(1, (S.In.x - gx) / gridW))
                S.pickerApply()
                S.Win.dirty = true
                consumed = true
                S.Drag.mode = "pickalpha"
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
                S.Drag.sbOff = S.Scroll.grab(S.Drop.bar, S.In.y)
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
                S.Drag.sbOff = S.Scroll.grab(S.PageBar, S.In.y)
            elseif S.inRect(S.In.x, S.In.y, x, y, S.Sb.cur, h) then
                if S.PinRect and S.FlagRows.sidebarMode and S.inRect(S.In.x, S.In.y, S.PinRect.x, S.PinRect.y, S.PinRect.w, S.PinRect.h) then
                    S.applyRow(S.FlagRows.sidebarMode, S.Cfg.sidebarMode == "Expanded" and "Auto" or "Expanded")
                elseif S.D.gear.Visible and S.GearRect and S.inRect(S.In.x, S.In.y, S.GearRect.x, S.GearRect.y, S.GearRect.w, S.GearRect.h) then
                    S.switchTab(S.SETTINGS_TAB)
                else
                    local iy = S.itemsTop()
                    for i = 1, #S.Tabs do
                        if S.inRect(S.In.x, S.In.y, x, iy + (i - 1) * S.Const.ITEM_H, S.Sb.cur, S.Const.ITEM_H) then
                            -- tab ripple: a tiny pseudo-row per tab, drawn above the lifted sidebar
                            S.TabRip = S.TabRip or {}
                            S.TabRip[i] = S.TabRip[i] or { kind = "tab", idx = i, rect = {}, vis = true, ripZ = 34 + S.SB_LIFT }
                            S.addRipple(S.TabRip[i], 1, S.In.x, S.In.y)
                            S.switchTab(i)
                            break
                        end
                    end
                end
            else
                local handled = false
                local page = S.Pages[S.activeTab]
                -- a card's own scrollbar (cards made shorter than their content)
                if page and S.In.y > y + S.TB then
                    for _, sec in ipairs(page.sections) do
                        local g2 = sec.sbGeo
                        if g2 and S.inRect(S.In.x, S.In.y, g2.x, g2.y, g2.w, g2.h) then
                            S.Drag.mode, S.Drag.sbSec = "cardsb", sec
                            S.Drag.sbOff = S.Scroll.grab(sec.bar, S.In.y)
                            handled = true
                            break
                        end
                    end
                end
                -- the Settings page can't be rearranged
                if page and S.LayoutEdit and S.activeTab ~= S.SETTINGS_TAB and not handled and S.In.y > y + S.TB then
                    -- editing: the grip resizes, anywhere else on a card (header or body) moves it; rows don't react
                    for _, sec in ipairs(page.sections) do
                        local gr, hr, r = sec.gripRect, sec.headRect, sec.rect
                        if gr and S.inRect(S.In.x, S.In.y, gr.x, gr.y, gr.w, gr.h) then
                            S.Drag.mode, S.Drag.sec = "cardsize", sec
                            S.Drag.w0, S.Drag.x0 = sec.lay and sec.lay.w, S.In.x
                            handled = true
                            break
                        elseif (hr and S.inRect(S.In.x, S.In.y, hr.x, hr.y, hr.w, hr.h)) or (r and sec.vis and S.inRect(S.In.x, S.In.y, r.x, r.y, r.w, r.h)) then
                            S.Drag.mode, S.Drag.sec = "card", sec
                            S.Drag.cardOx, S.Drag.cardOy = S.In.x - hr.x, S.In.y - (hr.y + 2)
                            S.Drag.lastX, S.Drag.lastY = nil, nil
                            S.cardZ(sec, 20)
                            handled = true
                            break
                        end
                    end
                end
                if page and not handled then
                    -- click a section header -> collapse/expand that card
                    for _, sec in ipairs(page.sections) do
                        local hr = sec.headRect
                        if not (S.LayoutEdit and S.activeTab ~= S.SETTINGS_TAB) and hr and S.In.y > y + S.TB and S.inRect(S.In.x, S.In.y, hr.x, hr.y, hr.w, hr.h) then
                            sec.collapsed = not sec.collapsed
                            S.markChanged()
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
                                if row.disabled then
                                    -- disabled rows swallow the click
                                elseif row.kind == "toggle" then
                                    row.value = not row.value
                                    if row.onChange then pcall(row.onChange, row.value) end
                                    if row.flag then S.markChanged() end
                                elseif row.kind == "button" then
                                    S.addRipple(row, 1, S.In.x, S.In.y)
                                    if row.onClick then pcall(row.onClick) end
                                    if #UI.Objects == 0 then return end
                                elseif row.kind == "buttonrow" then
                                    local bw = row.bw or 60
                                    for i = 1, #row.defs do
                                        local bx2 = r.x + 12 + (i - 1) * (bw + 8)
                                        if S.inRect(S.In.x, S.In.y, bx2, r.y + 4, bw, row.h - 8) then
                                            S.addRipple(row, i, S.In.x, S.In.y)
                                            pcall(row.defs[i].cb)
                                            break
                                        end
                                    end
                                elseif row.kind == "tiles" then
                                    rowPass = true
                                    for i, tr in ipairs(row.tileRects) do
                                        if S.inRect(S.In.x, S.In.y, tr[1], tr[2], tr[3], tr[4]) then
                                            local d = row.defs[i]
                                            if d and d.onClick then
                                                rowPass = false
                                                S.addRipple(row, i, S.In.x, S.In.y)
                                                pcall(d.onClick, i)
                                            end
                                            break
                                        end
                                    end
                                elseif row.kind == "hero" then
                                    rowPass = true
                                elseif row.kind == "discord" then
                                    rowPass = true
                                    for i, br in ipairs(row.btnRects) do
                                        if S.inRect(S.In.x, S.In.y, br[1], br[2], br[3], br[4]) then
                                            rowPass = false
                                            S.addRipple(row, i, S.In.x, S.In.y)
                                            S.discordJoin(row)
                                            break
                                        end
                                    end
                                elseif row.kind == "subtabs" then
                                    local i = math.floor((S.In.x - r.x - 12) / (row.cellW or 60)) + 1
                                    local nm = row.names[math.clamp(i, 1, #row.names)]
                                    if nm ~= sec.subSel then
                                        sec.subSel = nm
                                        if sec.onSub then sec.onSub(nm) end
                                        S.markChanged()
                                        S.Win.dirty = true
                                    end
                                elseif row.kind == "slider" then
                                    local t = (row.value - row.min) / math.max(0.0001, row.max - row.min)
                                    local kx = row.knobX or (row.barX + row.barW * t)
                                    if row.chipRect and S.inRect(S.In.x, S.In.y, row.chipRect.x, row.chipRect.y, row.chipRect.w, row.chipRect.h) then
                                        S.Focus.row = row
                                        row.buf = S.fmtSlider(row)
                                    elseif S.inRect(S.In.x, S.In.y, kx - 9, row.barY - 9, 18, 20) then
                                        S.Drag.mode = "slider"
                                        S.Drag.row = row
                                    else
                                        rowPass = true
                                    end
                                elseif row.kind == "dropdown" then
                                    if S.inRect(S.In.x, S.In.y, S.rippleBox(row, 1)) then S.addRipple(row, 1, S.In.x, S.In.y) end
                                    S.openDropdown(row)
                                    S.Win.dirty = true
                                elseif row.kind == "color" then
                                    S.openPicker(row)
                                    S.Win.dirty = true
                                elseif row.kind == "keybind" then
                                    S.Capture.row, S.Capture.t = row, os.clock()
                                elseif row.kind == "textbox" then
                                    S.Focus.row = row
                                elseif row.kind == "divider" or row.kind == "note" or row.kind == "progress" or row.kind == "image" then
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
            local keep = pick and S.dropPick(S.Drop.open, pick)
            if not keep then S.closeDropdown() end
            S.Win.dirty = true
        elseif S.Drag.mode == "scroll" then
            -- release a flick: hand the tracked velocity to the momentum integrator
            local page = S.curPage()
            if page then page.momentum = S.Drag.vel or 0 end
        end
        if S.Drag.mode == "card" and S.Drag.sec then S.cardZ(S.Drag.sec, 0) end
        if S.Drag.sec then S.markChanged() S.Win.dirty = true end
        S.Drag.mode = nil
        S.Drag.row = nil
        S.Drag.sec = nil
        S.Drag.sbSec = nil
        S.Drag.vel = 0
    end

    if S.Drag.mode == "card" and S.Drag.sec then
        local page = S.curPage()
        if page then S.moveCard(page, S.Drag.sec) end
    elseif S.Drag.mode == "cardsize" and S.Drag.sec then
        local page = S.curPage()
        if page then S.resizeCard(page, S.Drag.sec) end
    elseif S.Drag.mode == "cardsb" and S.Drag.sbSec and S.Drag.sbSec.sbGeo then
        local sec = S.Drag.sbSec
        local s = S.Scroll.drag(sec.bar, S.In.y, S.Drag.sbOff)
        if s ~= sec.scroll then sec.scroll = s S.Win.dirty = true end
    elseif S.Drag.mode == "move" then
        S.Win.x, S.Win.y = S.clampRect(S.In.x - S.Drag.ox, S.In.y - S.Drag.oy, S.Win.w, S.Win.h)
        S.Win.dirty = true
    elseif S.Drag.mode == "resize" then
        local m = S.Const.EDGE
        local maxW = S.vp and S.vp.X - m - S.Win.x or math.huge
        local maxH = S.vp and S.vp.Y - m - S.Win.y or math.huge
        local newW = math.max(S.Const.MIN_W, math.min(maxW, S.In.x - S.Win.x + 8))
        local newH = math.max(S.Const.MIN_H, math.min(maxH, S.In.y - S.Win.y + 8))
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
    elseif S.Drag.mode == "pickalpha" and S.Pick.open then
        S.Pick.a = math.max(0, math.min(1, (S.In.x - (S.Pick.gx or 0)) / (S.Const.SV_COLS * S.Const.SV_CELL)))
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
        S.Drop.scroll = S.Scroll.drag(S.Drop.bar, S.In.y, S.Drag.sbOff, true)
        S.Win.dirty = true
    elseif S.Drag.mode == "scrollpend" then
        if math.abs(S.In.y - S.Drag.sy) > 6 then S.Drag.mode = "scroll" end
    elseif S.Drag.mode == "scroll" then
        local page = S.curPage()
        if page then
            local raw = S.Drag.startScroll - (S.In.y - S.Drag.sy)
            local newScroll = math.max(0, math.min((page.maxScroll or 0), raw))
            local ex = raw - newScroll -- dragged past an end: rubber-band stretch (eases toward 48 px)
            if ex ~= 0 then S.overPush(page, (ex > 0 and 1 or -1) * 48 * (1 - math.exp(-math.abs(ex) / 90))) end
            -- track a smoothed scroll velocity (px/s) so a flick release carries momentum
            local inst = (newScroll - page.scrollY) / math.max(dt, 1e-4)
            S.Drag.vel = (S.Drag.vel or 0) * 0.6 + inst * 0.4
            page.scrollY = newScroll
            S.Win.dirty = true
        end
    elseif S.Drag.mode == "sbar" and UI.sbRect then
        local page = S.curPage()
        if page then
            page.scrollY = S.Scroll.drag(S.PageBar, S.In.y, S.Drag.sbOff)
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
            if page.scrollY <= 0 then page.scrollY = 0 S.overPush(page, nil, page.momentum * 0.35) page.momentum = 0 end
            if page.scrollY >= (page.maxScroll or 0) then page.scrollY = page.maxScroll or 0 S.overPush(page, nil, page.momentum * 0.35) page.momentum = 0 end
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
            S.updateOver(page, dt)
            S.Scroll.step(page, "scrollY", "scrollCur", "scrollV", page.maxScroll or 0, dt,
                S.Drag.mode == "scroll" or S.Drag.mode == "sbar")
            for _, sec in ipairs(page.sections) do
                S.Scroll.step(sec, "scroll", "scrollCur", "scrollV", math.max(0, (sec.fitH or 0) - (sec.limH or sec.fitH or 0)), dt,
                    S.Drag.mode == "cardsb" and S.Drag.sbSec == sec)
            end
        end
    end

    -- scrollbar glow while scrolling by any means
    S.wheelPulse = math.max(0, S.wheelPulse - dt)
    S.PageBar.pulse = math.max(S.PageBar.pulse, S.wheelPulse)
    S.Scroll.update(S.PageBar, dt, S.Drag.mode == "scroll" or S.Drag.mode == "sbar")
    S.Scroll.update(S.Drop.bar, dt, S.Drag.mode == "dropscroll" or S.Drag.mode == "dropsbar")
    local scrollPage = S.curPage()
    if scrollPage then
        for _, sec in ipairs(scrollPage.sections) do
            S.Scroll.update(sec.bar, dt, S.Drag.mode == "cardsb" and S.Drag.sbSec == sec)
        end
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
    S.updateNyan(frameDelta) -- use this frame's title/control bounds after any relayout
    S.perfSection("updateControls")
    S.updateControls(dt, S.In.x, S.In.y)
    S.perfSection("clipRows")
    S.clipRows()
    S.perfSection("other")
    S.markUpdate(dt)
    S.perfSection("glassBlurRects")
    S.updateWinGlow(dt)
    S.winBlur(dt)
    if S.Win.visible and S.Pick.open and S.Pick.bg.Visible then
        local pp, ps = S.Pick.bg.Position, S.Pick.bg.Size
        S.Blur.rect("pick", pp.X, pp.Y, ps.X, ps.Y, S.Const.BLUR_INSET_SMALL)
        if S.glassOn() then
            S.glassPanel("pick", S.Pick.bg, pp.X, pp.Y, ps.X, ps.Y, S.Cfg.opacity, 6)
        else
            S.Pick.bg.Transparency = S.Const.ALPHA_BG * S.Cfg.opacity
        end
    end
    S.perfSection("other")
    S.updateGlyph(dt)
end

S.calibrateFont()
UI.Conn = S.RunService.RenderStepped:Connect(function(dt)
    local started = os.clock()
    local P = S.Perf
    local sampled = not S.Env.matcha and pcall(S.perfFrame, dt)
    if sampled then P.section, P.sectionT = "other", started end
    local pf = _G.FallenPerf -- a host script's per-frame profiler, when it has one on
    S.DrawBatch = true
    local ok, e = pcall(S.frame)
    -- Always release the transaction, including a frame that errored mid-layout.
    if not ok then
        S.perfError("frame", e)
        pcall(S.perfSection, "clipRows")
        local clipped, clipError = pcall(S.clipRows)
        if not clipped then S.perfError("frame", clipError) end
    end
    S.DrawBatch = false
    pcall(S.perfSection, "drawFlush")
    local entries = #S.DrawQueue
    local okD, writes = pcall(S.drawFlush)
    if not okD then
        S.perfError("frame", writes)
        if ok then ok, e = false, writes end
    end
    if #S.RRQueue > 0 then
        pcall(S.perfSection, "rrFlush")
        local okR, eR = pcall(S.rrFlush)
        if not okR then
            S.perfError("frame", eR)
            if ok then ok, e = false, eR end
        end
    end
    pcall(S.perfSection, "other")
    if pf then pf.ui = pf.ui + (os.clock() - started) end
    if not ok then
        S.errCount = S.errCount + 1
        if S.errCount <= 3 or S.errCount % 300 == 0 then
            print("LEGOSENSE|frame ERROR (" .. S.errCount .. "): " .. tostring(e))
        end
    end
    if sampled then pcall(S.perfUIEnd, started, entries, okD and writes or 0, os.clock()) end
end)
bootSample = nil

S.bindCtrlSpace()
if not S.Env.matcha then
    pcall(function()
        S.RunService:BindToRenderStep("LSBlur", Enum.RenderPriority.Last.Value, function(dt)
            local started = os.clock()
            local phaseOk, phase = pcall(S.perfPhase, started)
            local ok, e = pcall(S.Blur.step, dt)
            if not ok then
                S.perfError("blur", e)
                if not S.Blur.errShown then
                    S.Blur.errShown = true
                    print("LEGOSENSE|blur step: " .. tostring(e))
                end
            end
            if S.Ruler.on or S.Ruler.used > 0 then pcall(S.rulerStep) end
            if next(S.GlassP) then pcall(S.glassSweep) end
            if phaseOk then pcall(S.perfBlur, phase, os.clock() - started) end
        end)
    end)
end

function UI.Unload()
    if UI.unloaded then return end -- Unload UI button, X, the script's own unload and a re-load can all fire it
    UI.unloaded = true
    if S.Perf then S.perfCancelPending("unloaded") end
    if S.Perf.started then pcall(S.perfSend, "unload") end -- before S.unloaded / disconnects
    S.unloaded = true -- every Drawing write of this instance becomes a no-op (see S.scaleDrawing)
    UI.nyanBlurKey, UI.nyanBlurJob, UI.nyanBlurFrames = nil, nil, nil
    UI.nyanDecoded = nil
    for _, fn in ipairs(S.onUnloadList) do pcall(fn) end -- let the consumer script stop its loops/ESP too
    if UI.Conn then pcall(function() UI.Conn:Disconnect() end) end
    if not S.Env.matcha then pcall(function() S.RunService:UnbindFromRenderStep("LSBlur") end) end
    pcall(function() game:GetService("ContextActionService"):UnbindAction("LegoSenseCtrlSpace") end)
    pcall(S.Blur.clear, true)
    for _, c in ipairs(UI.WheelConns) do pcall(function() c:Disconnect() end) end
    if S.FrameConn then pcall(function() S.FrameConn:Disconnect() end) end
    if S.Cfg.autoSave then pcall(S.saveSettings) end
    for _, o in ipairs(UI.Objects) do local e = S.ScaleLogical[o] pcall(function() (e and e.o or o):Remove() end) end
    S.Perf.freed = S.Perf.freed + #UI.Objects
    UI.Objects = {}
    S.setGameInput(true)
    if S.blockGui then pcall(function() S.blockGui:Destroy() end) S.blockGui = nil end
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
        icon  = S.New("Image", { Transparency = 1, ZIndex = 33, Visible = S.Win.visible, Size = Vector2.new(16, 16), Color = S.Theme.Dim }),
        label = S.New("Text",  { Text = "", Color = S.Theme.Dim, Transparency = 1, ZIndex = 33, Font = 0, Size = S.FS + 4, Visible = S.Win.visible }),
    }
    S.liftItem(S.Items[newIdx])
    S.loadIcon(S.Tabs[newIdx].icon, function(data) S.Items[newIdx].icon.Data = data end)
    S.Win.dirty = true
    return newIdx
end

-- ---- Element: a single control handle ----
S.Element = {}
S.Element.__index = S.Element
function S.Element.new(row) return setmetatable({ row = row }, S.Element) end
function S.Element:SetTip(tip) self.row.tip = tip return self end
S.TEXT_ROWS = { note = true, divider = true, button = true }
function S.Element:Set(v)
    if S.TEXT_ROWS[self.row.kind] then return self:SetText(v) end
    S.applyRow(self.row, v) S.Win.dirty = true return self
end
-- change the visible text of a note / divider / button (or any row's label)
function S.Element:SetText(text)
    self.row.label = tostring(text)
    S.Win.dirty = true
    return self
end
-- replace a dropdown's options; keeps the current value if it is still in the list, else picks the first
function S.Element:SetOptions(list)
    local r = self.row
    if r.kind ~= "dropdown" then return self end
    r.options = list or {}
    if r.multi then
        if S.Drop.open == r then S.Drop.options = r.options end
        S.Win.dirty = true
        return self
    end
    local keep = false
    for _, o in ipairs(r.options) do
        if tostring(o) == tostring(r.value) then keep = true break end
    end
    if not keep then S.applyRow(r, tostring(r.options[1] or "")) end
    if S.Drop.open == r then S.Drop.options = r.options end
    S.Win.dirty = true
    return self
end
function S.Element:SetVisible(v) local r = self.row r.showT = r.showT or 1 r.hidden = not v S.Win.dirty = true return self end
function S.Element:SetDisabled(v) self.row.disabled = v ~= false S.Win.dirty = true return self end
function S.Element:Get()
    local r = self.row
    if r.color ~= nil then return r.color, r.alpha elseif r.vk ~= nil then return r.vk else return r.value end
end

-- ---- Section: a card that holds controls ----
S.Section = {}
S.Section.__index = S.Section
function S.Section.new(sec, tabIdx) return setmetatable({ section = sec, tabIdx = tabIdx }, S.Section) end
function S.Section:_refresh()
    if self.sub then -- every Create* ends here: tag the row it just added with this sub-tab
        local r = self.section.rows[#self.section.rows]
        r.sub = self.sub
        r.showT = (self.section.subSel == self.sub) and 1 or 0
    end
    if self.tabIdx == S.activeTab then S.setPageVisible(S.activeTab, true) end
    S.Win.dirty = true
end
function S.Section:SetVisible(v) S.setCardOff(self.section, v == false) return self end -- hide / show the whole card
-- tabs = sec:CreateSubTabs({"Aimbot", "FOV"}); tabs.Aimbot:CreateToggle{...} -> only shown on that sub-tab
function S.Section:CreateSubTabs(names)
    S.addSubTabs(self.section, names, self.tabIdx)
    self:_refresh()
    local out = {}
    for _, n in ipairs(names) do out[n] = setmetatable({ section = self.section, tabIdx = self.tabIdx, sub = n }, S.Section) end
    return out
end
-- options every control takes: Tip, Disabled, Visible = false, DependsOn = "flag" | { "flag", value }
-- (shown while that flag is truthy / equals value). Starlight/Rayfield-style names are accepted too:
-- Name, CurrentValue, CurrentOption, Range = {min, max}, Increment, and the flag as a 2nd argument.
function S.Section:_finish(r, o)
    r.tip = o.Tip
    if o.Disabled then r.disabled = true end
    self:_refresh()
    if o.DependsOn ~= nil then
        local dep = type(o.DependsOn) == "table" and o.DependsOn or { o.DependsOn }
        r.visFn = function()
            local v = S.Library:GetFlag(dep[1])
            if dep[2] ~= nil then return v == dep[2] end
            return v ~= nil and v ~= false and v ~= ""
        end
        if not r.visFn() then r.showT = 0 end
    end
    if o.Visible == false then r.hidden = true r.showT = 0 end
    S.Win.dirty = true
    return S.Element.new(r)
end
function S.Section:CreateToggle(o, flag)
    o = o or {}
    local def = o.Default if def == nil then def = o.CurrentValue end
    local r = S.addToggle(self.section, o.Text or o.Name or "Toggle", def, o.Flag or flag, o.Callback)
    return self:_finish(r, o)
end
function S.Section:CreateSlider(o, flag)
    o = o or {}
    local mn = o.Min or (o.Range and o.Range[1]) or 0
    local mx = o.Max or (o.Range and o.Range[2]) or 100
    local def = o.Default or o.CurrentValue or mn
    local r = S.addSlider(self.section, o.Text or o.Name or "Slider", mn, mx, def, o.Suffix, o.Flag or flag, o.Callback)
    r.inc = o.Increment or o.Step or 1
    return self:_finish(r, o)
end
function S.Section:CreateDropdown(o, flag)
    o = o or {}
    local def = o.Default if def == nil then def = o.CurrentOption end
    if type(def) == "table" and not o.Multi then def = def[1] end
    local opts = o.Options or {}
    if o.SpecialType == "Player" then opts = S.playerNames(o.ExcludeLocal) end
    if def == nil and not o.Multi then def = opts[1] or "" end
    local r = S.addDropdown(self.section, o.Text or o.Name or "Dropdown", opts, def, o.Flag or flag, o.Callback, o.Multi)
    local h = self:_finish(r, o)
    if o.SpecialType == "Player" then S.trackPlayers(h, o.ExcludeLocal) end
    return h
end
function S.Section:CreateButton(o)
    o = o or {}
    local r = S.addButton(self.section, o.Text or o.Name or "Button", o.Callback)
    return self:_finish(r, o)
end
function S.Section:CreateButtonRow(defs)
    local r = S.addButtonRow(self.section, defs or {}) self:_refresh() return S.Element.new(r)
end
function S.Section:CreateColor(o, flag)
    o = o or {}
    -- Alpha = 0..1 (opacity) adds an alpha bar; Callback(color, alpha). Transparency = 0..1 (Rayfield-style) works too.
    local a = o.Alpha
    if a == nil and type(o.Transparency) == "number" then a = 1 - o.Transparency end
    if a ~= nil then
        S.addColorAlpha = math.clamp(a, 0, 1) -- read by S.addColor -> regFlag so a saved alpha wins over this default
    end
    local r = S.addColor(self.section, o.Text or o.Name or "Color", o.Default or o.Color or S.Theme.C1, o.Flag or flag, o.Callback)
    S.addColorAlpha = nil
    return self:_finish(r, o)
end
S.Section.CreateColorpicker = S.Section.CreateColor
S.Section.CreateColorPicker = S.Section.CreateColor
-- Mode = "Toggle" | "Hold" | "Always" turns the bind into a live key: OnKey(state) fires on change,
-- Toggle = <toggle handle> drives that toggle. Without Mode, Callback(vk) fires on rebind only (as before).
function S.Section:CreateKeybind(o, flag)
    o = o or {}
    local r = S.addKeybind(self.section, o.Text or o.Name or "Keybind", o.Default or o.CurrentKeybind or 0x24, o.Flag or flag, o.Callback)
    if o.Mode then
        r.mode, r.onKey, r.keyState, r.wasHeld = o.Mode, o.OnKey, false, false
        r.toggleRow = o.Toggle and o.Toggle.row or nil
        table.insert(S.KeyRows, r)
    end
    return self:_finish(r, o)
end
S.Section.CreateBind = S.Section.CreateKeybind
-- Numeric = true: digits/./- only. Finished = true: Callback fires on Enter / click-away instead of every key.
function S.Section:CreateTextbox(o, flag)
    o = o or {}
    local r = S.addTextbox(self.section, o.Text or o.Name or "Textbox", o.Default or o.CurrentValue, o.Flag or flag, o.Callback)
    r.numeric, r.finished = o.Numeric == true, o.Finished == true
    return self:_finish(r, o)
end
S.Section.CreateInput = S.Section.CreateTextbox
function S.Section:CreateDivider(text) local r = S.addDivider(self.section, text or "") self:_refresh() return S.Element.new(r) end
function S.Section:CreateNote(text) local r = S.addNote(self.section, text or "") self:_refresh() return S.Element.new(r) end
function S.Section:CreateChangelog(entries) S.addChangelog(self.section, entries or {}) self:_refresh() return self end
S.Section.CreateLabel = S.Section.CreateNote
-- Value 0..1; handle:Set(0.4) moves the bar
function S.Section:CreateProgress(o)
    o = o or {}
    local r = S.addProgress(self.section, o.Text or o.Name or "Progress", o.Value or o.Default or 0)
    return self:_finish(r, o)
end
-- Image = url or asset id, Height = px (default 120)
function S.Section:CreateImage(o)
    o = o or {}
    local r = S.addImage(self.section, o.Image or o.Url or o.Id, o.Height)
    return self:_finish(r, o)
end
-- bold title line + wrapped body; returns { Title, Content, Set(title, content) }
function S.Section:CreateParagraph(o)
    o = o or {}
    local t = S.addNote(self.section, tostring(o.Title or ""))
    t.title = true
    t.lbl.Size, t.lbl.Color = S.FS, S.Theme.Text
    self:_refresh()
    local c = S.addNote(self.section, tostring(o.Content or ""))
    self:_refresh()
    local th, ch = S.Element.new(t), S.Element.new(c)
    return { Title = th, Content = ch, Set = function(_, title, content)
        if title then th:SetText(title) end
        if content then ch:SetText(content) end
    end }
end

-- Tiles = { { Title, Sub, Callback, Wash, Big }, ... }, Columns (2), Height (46 px per tile).
-- Returns { SetTile(i, title, sub, on) } for live values (only changed text is rewritten).
function S.Section:CreateDiscord(o)
    if type(o) ~= "table" then o = { Invite = o } end
    local r = S.addDiscord(self.section, o.Invite or o.Link or o.Code)
    self:_finish(r, o)
    S.discordLoad(r)
    return S.Element.new(r)
end
function S.Section:CreateTiles(o)
    o = o or {}
    local defs = {}
    for i, t in ipairs(o.Tiles or {}) do
        defs[i] = { title = t.Title or t[1], sub = t.Sub or t[2], onClick = t.Callback or t[3], wash = t.Wash, big = t.Big, live = t.Live }
    end
    local r = S.addTiles(self.section, defs, o.Columns, o.Height)
    self:_finish(r, o)
    return { row = r, SetTile = function(_, i, title, sub, on)
        local d = r.defs[i]
        if not d then return end
        if (title ~= nil and title ~= d.title) or (sub ~= nil and sub ~= d.sub) or (on ~= nil and on ~= d.on) then
            if title ~= nil then d.title = title end
            if sub ~= nil then d.sub = sub end
            if on ~= nil then d.on = on end
            S.Win.dirty = true
        end
    end }
end
function S.Section:CreateHero(o)
    o = o or {}
    local r = S.addHero(self.section, o.Title, o.Sub)
    self:_finish(r, o)
    return { row = r, Set = function(_, title, sub)
        if (title and title ~= r.label) or (sub and sub ~= r.subText) then r.label, r.subText = title or r.label, sub or r.subText S.Win.dirty = true end
    end }
end

-- ---- Tab: a sidebar page ----
S.Tab = {}
S.Tab.__index = S.Tab
function S.Tab.new(idx) return setmetatable({ index = idx }, S.Tab) end
function S.Tab:CreateSection(opts, side)
    S.perfBootMark("pageSectionBuildStart")
    local title
    local maxH
    if type(opts) == "table" then title = opts.Title or opts.Name or opts.Text side = opts.Side maxH = opts.MaxHeight else title = opts end
    local sec = S.addSection(self.index, title or "Section", S.resolveSide(side))
    sec.maxH = tonumber(maxH)
    if self.index == S.activeTab then S.setPageVisible(S.activeTab, true) end
    S.Win.dirty = true
    S.perfBootMark("pageSectionBuildEnd")
    return S.Section.new(sec, self.index)
end
S.Tab.CreateGroupbox = S.Tab.CreateSection
function S.Tab:Select() S.switchTab(self.index) return self end -- open this tab
function S.Tab:OnOpen(fn)
    local l = S.TabOpenFns[self.index] or {}
    S.TabOpenFns[self.index] = l
    l[#l + 1] = fn
    if S.activeTab == self.index then task.defer(pcall, fn) end
    return self
end
-- page-level sub-tabs (a bar across the top of the tab, like Settings):
--   local sub = tab:CreateSubTabs({ "Aim", "Visuals" })   -- or { Names = {...}, Title = "AIM" }
--   local card = sub.Aim:CreateSection("Silent aim", "left") -> only shown while "Aim" is selected
-- Card-level sub-tabs inside one card stay: section:CreateSubTabs({...}).
function S.Tab:CreateSubTabs(names)
    local title
    if type(names) == "table" and names.Names then title, names = names.Title, names.Names end
    local nav = S.makePageNav(self.index, names, title or string.upper(S.tabNameOf(self.index)))
    local out, tab = {}, self
    for _, n in ipairs(names) do
        out[n] = {
            CreateSection = function(_, opts, side)
                local h = S.Tab.CreateSection(tab, opts, side)
                h.section.psub = n
                S.pageFilter(S.Pages[tab.index])
                return h
            end,
            Select = function() S.setPageSub(S.Pages[tab.index], n) end,
        }
    end
    S.pageFilter(S.Pages[self.index])
    self.subNav = nav
    return out
end
function S.Tab:SelectSubTab(name) if S.Pages[self.index] and S.Pages[self.index].nav then S.setPageSub(S.Pages[self.index], name) end return self end

function S.wrapTab(tabIdx) return S.Tab.new(tabIdx) end

S.Library = {}
UI.Library = S.Library
S.Library.Flags = S.FlagRows
S.Library.Theme = S.Theme -- live: presets edit this table in place, so scripts can match the UI colours
-- the Drawing font id the UI currently uses (follows the Font setting), so script text can match it
function S.Library:GetFontId() return S.FontIds[S.Cfg.font] or 0 end
-- Settings > Streamer mode: scripts should show "Player" (or similar) instead of real player names while it's on
function S.Library:IsStreamer() return S.Cfg.streamer == true end

function S.Library:CreateTab(name, icon)
    S.perfBootMark("tabBuildStart")
    local idx = S.newTabIndex(name or "Tab", icon)
    if S.Cfg.openTab ~= "Home" and S.Persisted._tab == (name or "Tab") then S.switchTab(idx) end -- reopen the tab that was open last time
    S.perfBootMark("tabBuildEnd")
    return S.wrapTab(idx)
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

-- ---- context menu (right-click) ----
-- small glass panel at the mouse: an optional dim header line + clickable items. Closes on a click outside, Esc,
-- or when the menu hides. Used for favorites (right-click any option row).
S.Ctx = { open = false, items = {}, k = 0 }
S.Const.CTX_W, S.Const.CTX_ROW = 180, 26
function S.ctxBuild()
    if S.Ctx.bg then return end
    local Z = 106
    S.Ctx.bg = S.New("Square", { Filled = true, Color = S.Theme.Bg, Transparency = 0, ZIndex = Z, Corner = 6, Visible = false })
    S.Ctx.hi = S.New("Square", { Filled = true, Color = S.Theme.C1, Transparency = 0, ZIndex = Z + 1, Corner = 4, Visible = false })
    S.Ctx.head = S.New("Text", { Text = "", Color = S.Theme.Dim, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS - 2, Visible = false })
    S.Ctx.lbls = {}
    for i = 1, 6 do S.Ctx.lbls[i] = S.New("Text", { Text = "", Color = S.Theme.Text, Transparency = 0, ZIndex = Z + 2, Font = 0, Size = S.FS, Visible = false }) end
end
function S.ctxShow(v)
    if not S.Ctx.bg then return end
    S.Ctx.bg.Visible, S.Ctx.hi.Visible, S.Ctx.head.Visible = v, v, v
    for _, l in ipairs(S.Ctx.lbls) do l.Visible = false end
end
-- items = { { Text = "...", Callback = fn }, ... } (max 6); head = optional dim title line
function S.ctxOpen(x, y, head, items)
    S.ctxBuild()
    S.Ctx.items, S.Ctx.headText, S.Ctx.hasHead = items, head or "", head ~= nil
    local H = (S.Ctx.hasHead and 22 or 4) + #items * S.Const.CTX_ROW + 4
    local vp = S.vp or Vector2.new(1920, 1080)
    S.Ctx.x = math.min(x + 2, vp.X - S.Const.CTX_W - 6)
    S.Ctx.y = math.min(y + 2, vp.Y - H - 6)
    S.Ctx.h, S.Ctx.k, S.Ctx.open = H, 0, true
    S.ctxShow(true)
end
function S.ctxClose()
    S.Ctx.open = false
    S.ctxShow(false)
end
-- per frame; returns true when it used this frame's left click
function S.ctxUpdate(dt)
    local C = S.Ctx
    if not C.open then return false end
    if not S.Win.visible or iskeypressed(0x1B) then S.ctxClose() return false end
    C.k = S.animOn() and math.min(1, C.k + dt / 0.12) or 1
    local k = C.k * C.k * (3 - 2 * C.k)
    local op = S.Cfg.opacity * k
    local x, y, W = C.x, C.y + math.floor((1 - k) * 4 + 0.5), S.Const.CTX_W
    C.bg.Position, C.bg.Size, C.bg.Corner = Vector2.new(x, y), Vector2.new(W, C.h), S.CR(6)
    C.bg.Color, C.bg.Transparency = S.Theme.Bg, S.Const.ALPHA_BG * op
    S.Blur.rect("ctx", x, y, W, C.h, S.Const.BLUR_INSET_SMALL)
    S.glassPanel("ctx", C.bg, x, y, W, C.h, op, 6)
    C.head.Text = C.hasHead and S.truncate(C.headText, W - 24) or ""
    C.head.Position, C.head.Color, C.head.Transparency = Vector2.new(x + 12, y + 7), S.Theme.Dim, op
    local top = y + (C.hasHead and 22 or 4)
    local hov
    for i, l in ipairs(C.lbls) do
        local it = C.items[i]
        l.Visible = it ~= nil
        if it then
            local ry = top + (i - 1) * S.Const.CTX_ROW
            local h = S.inRect(S.In.x, S.In.y, x + 4, ry, W - 8, S.Const.CTX_ROW)
            if h then hov = i end
            l.Text = it.Text
            l.Position = Vector2.new(x + 12, ry + math.floor((S.Const.CTX_ROW - S.TH(l, S.FS)) / 2 + 0.5))
            l.Color, l.Transparency = h and S.Theme.White or S.Theme.Text, op
        end
    end
    C.hi.Visible = hov ~= nil
    if hov then
        C.hi.Position, C.hi.Size, C.hi.Corner = Vector2.new(x + 4, top + (hov - 1) * S.Const.CTX_ROW), Vector2.new(W - 8, S.Const.CTX_ROW), S.CR(4)
        C.hi.Color, C.hi.Transparency = S.Theme.C1, 0.22 * op
    end
    if S.In.pressed or S.In.rpressed then
        local inside = S.inRect(S.In.x, S.In.y, x, y, W, C.h)
        local it = hov and C.items[hov]
        S.ctxClose()
        if it and it.Callback then pcall(it.Callback) end
        if S.In.rpressed and not inside then return false end -- right-click elsewhere: may open a new menu
        S.In.rpressed = false
        return S.In.pressed
    end
    return false
end
-- right-click on an option row (any tab except Settings / Home pages) -> favorite menu
function S.ctxFromRow()
    if not S.Win.visible or S.Intro or S.Drop.open or S.Pick.open or S.activeTab == S.SETTINGS_TAB then return end
    local page = S.Pages[S.activeTab]
    if not page or page.isHome then return end
    local mx, my = S.In.x, S.In.y
    if mx <= S.Win.x + S.Sb.cur then return end
    for _, sec in ipairs(page.sections) do
        if sec.vis then
            for _, row in ipairs(sec.rows) do
                local r = row.rect
                if row.vis and row.flag and r and S.inRect(mx, my, r.x, r.y, r.w, r.h) then
                    local flag = row.flag
                    local fav = S.isFav(flag)
                    S.ctxOpen(mx, my, tostring(row.label or flag), {
                        { Text = fav and "Remove from favorites" or "Add to favorites", Callback = function() S.setFav(flag, not fav) end } })
                    return
                end
            end
        end
    end
end
-- favorites: list of flags, saved as "_favs" with the UI state; Home "Own" shows them as tiles (sorted by menu order)
S.FavHooks = {}
function S.favList()
    if not S.Favs then
        local saved = S.Persisted and S.Persisted._favs
        S.Favs = type(saved) == "table" and table.clone(saved) or nil
    end
    return S.Favs or {}
end
function S.isFav(flag)
    for _, f in ipairs(S.favList()) do if f == flag then return true end end
    return false
end
function S.setFav(flag, on)
    local list = table.clone(S.favList())
    for i = #list, 1, -1 do if list[i] == flag then table.remove(list, i) end end
    if on then list[#list + 1] = flag end
    S.Favs = list
    S.markChanged()
    for _, fn in ipairs(S.FavHooks) do pcall(fn) end
    S.toast(on and "Added to favorites" or "Removed from favorites", tostring(S.FlagRows[flag] and S.FlagRows[flag].label or flag), 2)
end
-- favorites in menu order: tab, then card, then row (Home pages and Settings skipped). Returns { { row = , tab = } }
function S.favSorted()
    local want = {}
    for _, f in ipairs(S.favList()) do want[f] = true end
    local out = {}
    for ti = 1, #S.Tabs do
        local page = S.Pages[ti]
        if page and not page.isHome then
            for _, sec in ipairs(page.sections) do
                for _, row in ipairs(sec.rows) do
                    if row.flag and want[row.flag] then out[#out + 1] = { row = row, tab = ti } want[row.flag] = nil end
                end
            end
        end
    end
    return out
end
function S.favValue(r)
    if r.kind == "toggle" then return r.value and "On" or "Off"
    elseif r.kind == "slider" then return S.fmtSlider(r) .. (r.suffix or "")
    elseif r.kind == "dropdown" then return type(r.value) == "table" and table.concat(r.value, ", ") or tostring(r.value or "")
    elseif r.kind == "keybind" then return S.rowKeyName(r)
    elseif r.kind == "textbox" or r.kind == "input" then return tostring(r.value or "") end
    return ""
end
-- drop a row from its card and free its drawings
function S.removeRow(sec, row)
    for i = #sec.rows, 1, -1 do if sec.rows[i] == row then table.remove(sec.rows, i) end end
    for _, o in ipairs(S.rowObjs(row)) do S.freeObj(o) end
    S.Win.dirty = true
end

-- ---- Home page ----
-- Library:CreateHome{ Style = "Reference" | "Own", Name = "Home", Icon = "house", Discord = "invite",
--                     Quick = { "flag", ... } (Own: toggles shown as tiles), Changelog = { "line", ... } (Own) }
-- Values refresh every second while the library is loaded.
function S.homeClock(sec)
    sec = math.floor(sec)
    local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
    return h > 0 and string.format("%d:%02d:%02d", h, m, sec % 60) or string.format("%02d:%02d", m, sec % 60)
end
function S.homePing()
    local ok, v = pcall(function() return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue() end)
    if ok and type(v) == "number" then return math.floor(v + 0.5) end
    local ok2, pg = pcall(function() return game:GetService("Players").LocalPlayer:GetNetworkPing() * 2000 end)
    return ok2 and math.floor(pg + 0.5) or nil
end
-- Rejoin: back into this same server. Server hop: the public server list (games.roblox.com), a random other server
-- with free slots; none found -> toast.
function S.rejoin()
    if S.previewOnly then return end
    local TS, lp = game:GetService("TeleportService"), game:GetService("Players").LocalPlayer
    S.toast("Rejoining", "Teleporting back into this server", 3)
    local ok = pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp) end)
    if not ok then pcall(function() TS:Teleport(game.PlaceId, lp) end) end
end
function S.serverHop()
    if S.previewOnly then return end
    if S.hopBusy then return end
    S.hopBusy = true
    S.toast("Server hop", "Looking for another server", 3)
    task.spawn(function()
        local HS, TS, lp = game:GetService("HttpService"), game:GetService("TeleportService"), game:GetService("Players").LocalPlayer
        local picks, cursor = {}, nil
        for _ = 1, 3 do
            local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100" .. (cursor and ("&cursor=" .. cursor) or "")
            local ok, j = pcall(function() return HS:JSONDecode(S.httpGet(url)) end)
            if not ok or type(j) ~= "table" then break end
            for _, sv in ipairs(j.data or {}) do
                if sv.id ~= game.JobId and tonumber(sv.playing) and tonumber(sv.maxPlayers) and sv.playing < sv.maxPlayers then picks[#picks + 1] = sv.id end
            end
            cursor = j.nextPageCursor
            if #picks >= 10 or not cursor then break end
        end
        S.hopBusy = false
        if #picks == 0 then S.toast("Server hop", "No other server with free slots", 3) return end
        local id = picks[math.random(1, #picks)]
        pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, id, lp) end)
    end)
end
function S.homeCopy(text, what)
    local ok = pcall(setclipboard, text)
    S.toast(ok and "Copied" or "Copy failed", ok and what or "This executor has no clipboard access", 2.5)
end
-- online / in this server from GetFriendsOnline, total from GetFriendsAsync pages (async; refreshed every 60 s)
function S.homeFriends(out)
    if out.busy then return end
    out.busy = true
    task.spawn(function()
        local lp = game:GetService("Players").LocalPlayer
        local ok, online = pcall(function() return lp:GetFriendsOnline(200) end)
        if ok and type(online) == "table" then
            local here = 0
            for _, f in ipairs(online) do if f.GameId == game.JobId then here = here + 1 end end
            out.online, out.here = #online, here
        end
        local okP, pages = pcall(function() return game:GetService("Players"):GetFriendsAsync(lp.UserId) end)
        if okP and pages then
            local n = 0
            for _ = 1, 10 do
                local okC, cur = pcall(function() return pages:GetCurrentPage() end)
                if not okC then break end
                n = n + #cur
                if pages.IsFinished or not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
            end
            out.all = n
        end
        out.at, out.busy = os.clock(), false
    end)
end
-- Home tab (one per window; CreateWindow makes it unless Home = false). CreateWindow{ Home = { Discord = "discord.gg/x",
-- Changelog = { lines }, Quick = { flags }, Name, Icon } }. Layout: greeting across the top; left = Community (Discord),
-- then What's new; right = Favorites (only while there are favorites), then Status (Session | Server sub-tabs).
function S.Library:CreateHome(opts)
    if S.HomeTab then return S.HomeTab end
    opts = opts or {}
    local tab = S.Library:CreateTab(opts.Name or "Home", opts.Icon or "home")
    S.HomeTab = tab
    local P = game:GetService("Players")
    local lp = P.LocalPlayer
    local function who() return S.Cfg.streamer and "Player" or (lp and lp.DisplayName or "Player") end
    local exe = "Unknown"
    pcall(function() exe = tostring((identifyexecutor())) end)
    local region = "--"
    task.spawn(function()
        local ok, r = pcall(function() return game:GetService("LocalizationService"):GetCountryRegionForPlayerAsync(lp) end)
        if ok and r then region = r end
    end)
    local fps, frames, fpsT = 0, 0, os.clock()
    local fc = S.RunService.RenderStepped:Connect(function() frames = frames + 1 end)
    table.insert(S.onUnloadList, function() fc:Disconnect() end)
    local heroSec = tab:CreateSection({ Title = "Home", Side = "left" })
    heroSec.section.span = true -- full width without marking the page "custom" (that saved + froze the Home layout)
    local function greet()
        local hr = tonumber(os.date("%H")) or 12
        return (hr < 5 and "Up late" or hr < 12 and "Good morning" or hr < 18 and "Good afternoon" or "Good evening") .. ", " .. who()
    end
    local hero = heroSec:CreateHero{ Title = greet(), Sub = "" }
    S.Pages[tab.index].isHome = true
    local upd = {}
    -- left: Favorites (right-click any option -> Add to favorites). Real controls mirroring the originals (synced both
    -- ways every 0.1 s); other kinds = a button that jumps there. Quick = { flags } only seeds the list the first time.
    if not S.Favs and not (S.Persisted and type(S.Persisted._favs) == "table") and type(opts.Quick) == "table" then
        S.Favs = table.clone(opts.Quick)
    end
    local fsec = tab:CreateSection({ Title = "Favorites", Side = "right" })
    local fav = { list = {}, dirty = true, rows = {} }
    S.setCardOff(fsec.section, true) -- shown once there is a favorite
    local function buildFavs()
        for _, m in ipairs(fav.rows) do S.removeRow(fsec.section, m.row) end
        fav.rows = {}
        fav.list = S.favSorted()
        local sec = fsec.section
        S.setCardOff(sec, #fav.list == 0)
        if #fav.list == 0 then return end
        for _, e in ipairs(fav.list) do
            local orig, ti = e.row, e.tab
            local m = { orig = orig }
            local function push(v)
                if m.sync then return end
                S.applyRow(orig, type(v) == "table" and table.clone(v) or v)
                S.markChanged()
            end
            if orig.kind == "toggle" then
                m.row = S.addToggle(sec, orig.label, orig.value, nil, push)
            elseif orig.kind == "slider" then
                m.row = S.addSlider(sec, orig.label, orig.min, orig.max, orig.value, orig.suffix, nil, push)
                m.row.inc = orig.inc
            elseif orig.kind == "dropdown" then
                local v = orig.value
                m.row = S.addDropdown(sec, orig.label, orig.options, type(v) == "table" and table.clone(v) or v, nil, push, orig.multi)
            else
                m.row = S.addButton(sec, orig.label .. "  ->  " .. (S.Tabs[ti] and S.Tabs[ti].name or ""), function() S.switchTab(ti) end)
            end
            fav.rows[#fav.rows + 1] = m
        end
        fsec:_refresh()
        S.Win.dirty = true
    end
    task.spawn(function()
        while not UI.unloaded do
            for _, m in ipairs(fav.rows) do
                local o, r = m.orig, m.row
                if r.kind ~= "button" and o.value ~= r.value then
                    m.sync = true
                    r.value = type(o.value) == "table" and table.clone(o.value) or o.value
                    m.sync = false
                    S.Win.dirty = true
                end
                if r.disabled ~= o.disabled then r.disabled = o.disabled S.Win.dirty = true end
            end
            task.wait(0.1)
        end
    end)
    table.insert(S.FavHooks, function() fav.dirty = true end)
    -- right, under Favorites: Status = Session | Server
    local stat = tab:CreateSection({ Title = "Status", Side = "right" })
    local sub = stat:CreateSubTabs({ "Session", "Server" })
    local st = sub.Session:CreateTiles{ Columns = 2, Tiles = {
        { Title = "FPS", Sub = "", Live = true }, { Title = "Ping", Sub = "", Live = true },
        { Title = "Players", Sub = "", Live = true }, { Title = "Session", Sub = "" } } }
    local sv = sub.Server:CreateTiles{ Columns = 2, Tiles = {
        { Title = "Region", Sub = "" }, { Title = "Latency", Sub = "", Live = true },
        { Title = "Players", Sub = "", Live = true }, { Title = "In server for", Sub = "" },
        { Title = "Rejoin", Sub = "This server", Callback = function() S.rejoin() end },
        { Title = "Server hop", Sub = "Another server", Callback = function() S.serverHop() end } } }
    -- left: Community
    if opts.Discord then
        local dc = tab:CreateSection({ Title = "Community", Side = "left" })
        dc:CreateDiscord(opts.Discord)
    end
    -- left, under Community: UI release notes or the consumer's complete replacement.
    local news, newsSource = S.homeNews(opts)
    if #news > 0 then
        local cl = tab:CreateSection({ Title = "What's new", Side = "left", MaxHeight = opts.ChangelogHeight or 170 })
        cl.section.newsSource = newsSource
        cl:CreateChangelog(news)
    end
    local t0 = os.clock()
    upd[1] = function()
        hero:Set(greet(), "Session " .. S.homeClock(os.clock() - t0) .. "  -  " .. exe)
        st:SetTile(1, nil, tostring(fps))
        local pg = S.homePing()
        st:SetTile(2, nil, pg and (pg .. " ms") or "--")
        st:SetTile(3, nil, #P:GetPlayers() .. " / " .. P.MaxPlayers)
        st:SetTile(4, nil, S.homeClock(os.clock() - t0))
        sv:SetTile(1, nil, region)
        sv:SetTile(2, nil, pg and (pg .. " ms") or "--")
        sv:SetTile(3, nil, #P:GetPlayers() .. " / " .. P.MaxPlayers)
        sv:SetTile(4, nil, S.homeClock(workspace.DistributedGameTime))
        -- also rebuild when the found count changes (favorited options whose tabs are made after the Home)
        if fav.dirty or #S.favSorted() ~= #fav.list then fav.dirty = false buildFavs() end
    end
    task.spawn(function()
        while not UI.unloaded do
            local now = os.clock()
            fps = math.floor(frames / math.max(0.001, now - fpsT) + 0.5)
            frames, fpsT = 0, now
            local ok, e = pcall(upd[1])
            if not ok then
                S.perfError("home", e)
                if not S.homeErr then
                    S.homeErr = true
                    print("LEGOSENSE|home: " .. tostring(e))
                end
            end
            task.wait(1)
        end
    end)
    return tab
end

function S.Library:SetPreset(name)
    if S.Presets[name] or name == "Custom" then self:SetFlag("preset", name) end
    S.Win.dirty = true
end
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
-- Matcha: notify(message, title, duration). Elsewhere: the standard Roblox notification.
-- Notify(title, message, duration) or Notify{ Title, Content, Duration }. Themed toast when Drawing works,
-- else the executor's / Roblox's own notification.
function S.Library:Notify(title, message, duration)
    if type(title) == "table" then title, message, duration = title.Title, title.Content or title.Text, title.Duration end
    duration = duration or S.Cfg.notifyTime or 5
    if S.Env.drawing and #UI.Objects > 0 then
        S.toast(title, message, duration)
    elseif S.Env.matcha then
        pcall(notify, tostring(message), tostring(title), duration)
    else
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", { Title = tostring(title), Text = tostring(message), Duration = duration })
        end)
    end
end
-- Dialog{ Title, Content, Buttons = { { Text = "Yes", Callback = fn }, { Text = "No" } } }
function S.Library:Dialog(o) S.openDialog(o or {}) end
function S.Library:Show() S.setVisible(true) end
function S.Library:Hide() S.setVisible(false) end
function S.Library:Toggle() S.setVisible(not S.Win.visible) end
-- replay the opening animation: hides the menu, plays the intro, the menu comes back at its end
-- (ignored while one is already playing, or where the intro can't run: Matcha / no Drawing)
function S.Library:PlayIntro()
    if S.Cfg.perfMode or S.Intro or not UI.created or not S.Env.drawing or S.Env.matcha then return end
    S.setVisible(false)
    S.introStart()
end
function S.Library:IsVisible() return S.Win.visible == true end
-- blur debug: glass rects drawn as red sheets (see where each blur sits vs its panel)
function S.Library:DebugBlur(on) S.Blur.debug = on ~= false end
function S.Library:PerfReport() return S.perfReport("manual") end -- telemetry table (what would be sent)
-- console: one line per live blur = name, panel rect, inset, glass rect (logical px). Returns the lines too.
function S.Library:BlurReport()
    local out = {}
    for key, r in pairs(S.Blur.rects) do
        local name = type(key) == "string" and key or (type(key) == "table" and (key.tt and "toast" or key.title or key.Title or "overlay")) or tostring(key)
        local m = r.m or r.inset or S.Const.BLUR_INSET
        out[#out + 1] = string.format("%-10s panel %4d,%4d %4dx%-4d inset %2d -> glass %4d,%4d %4dx%-4d",
            tostring(name), math.floor(r.x + 0.5), math.floor(r.y + 0.5), math.floor(r.w + 0.5), math.floor(r.h + 0.5), math.floor(m + 0.5),
            math.floor(r.x + m + 0.5), math.floor(r.y + m + 0.5), math.floor(r.w - 2 * m + 0.5), math.floor(r.h - 2 * m + 0.5))
    end
    table.sort(out)
    print(string.format("blur: dof %s  window %d  small %d  intro %d  debug %s", tostring(S.Blur.dof and S.Blur.dof.Enabled),
        math.floor(S.Const.BLUR_INSET), math.floor(S.Const.BLUR_INSET_SMALL), math.floor(S.Const.BLUR_INSET_INTRO), tostring(S.Blur.debug == true)))
    for _, l in ipairs(out) do print("  " .. l) end
    return out
end
-- console: change an inset live. which = "window" | "small" (overlays, picker, menu) | "intro"; px >= 0
-- blur ruler (Library:BlurRuler(true)): for every live blur, magenta = the panel edge, cyan = the glass edge, and 1 px
-- ticks going OUT from the panel (longer every 2 px, a number every 4). Drawings sit on top of the blur, so a screenshot
-- shows how many px the blurred world reaches past the panel on each side.
S.Ruler = { on = false, pool = {}, used = 0 }
function S.rulerObj(kind)
    local R = S.Ruler
    R.used = R.used + 1
    local o = R.pool[R.used]
    if not o or o.kind ~= kind then
        o = { kind = kind, d = S.New(kind, { ZIndex = 300, Transparency = 1, Visible = false }) }
        if kind == "Text" then o.d.Size, o.d.Font, o.d.Outline = 11, 0, true end
        R.pool[R.used] = o
    end
    o.d.Visible = true
    return o.d
end
function S.rulerLine(x1, y1, x2, y2, col)
    local l = S.rulerObj("Line")
    l.From, l.To, l.Color, l.Thickness = Vector2.new(x1, y1), Vector2.new(x2, y2), col, 1 / (S.K or 1) -- 1 screen px
end
function S.rulerStep()
    local R = S.Ruler
    local used = R.used
    R.used = 0
    if R.on and not S.Cfg.perfMode then
        local MAG, CY, W, B = Color3.fromRGB(255, 0, 255), Color3.fromRGB(0, 255, 255), Color3.new(1, 1, 1), Color3.new(0, 0, 0)
        for _, r in pairs(S.Blur.rects) do
            if r.glass and r.f >= S.Blur.frame - 2 and (r.m or 0) > 0 then
                local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
                local g = r.glass
                for _, e in ipairs({ { x0, y0, x1, y0 }, { x1, y0, x1, y1 }, { x0, y1, x1, y1 }, { x0, y0, x0, y1 } }) do S.rulerLine(e[1], e[2], e[3], e[4], MAG) end
                for _, e in ipairs({ { g[1], g[2], g[3], g[2] }, { g[3], g[2], g[3], g[4] }, { g[1], g[4], g[3], g[4] }, { g[1], g[2], g[1], g[4] } }) do S.rulerLine(e[1], e[2], e[3], e[4], CY) end
                -- ticks at the middle of each edge, stepping outward 1 px at a time
                local mx, my = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
                local u = 1 / (S.K or 1) -- ticks step in real screen px (the menu works in UI-scaled px)
                for k = 1, 12 do
                    local col = k % 2 == 0 and W or B
                    local len = (k % 2 == 0) and 14 or 8
                    local d = (k - 0.5) * u
                    S.rulerLine(mx - len, y0 - d, mx + len, y0 - d, col)       -- above top
                    S.rulerLine(mx - len, y1 + d, mx + len, y1 + d, col)       -- below bottom
                    S.rulerLine(x0 - d, my - len, x0 - d, my + len, col)       -- left of left
                    S.rulerLine(x1 + d, my - len, x1 + d, my + len, col)       -- right of right
                    if k % 4 == 0 then
                        local t
                        t = S.rulerObj("Text") t.Text, t.Color, t.Position = tostring(k), W, Vector2.new(mx + 18, y0 - d - 6)
                        t = S.rulerObj("Text") t.Text, t.Color, t.Position = tostring(k), W, Vector2.new(mx + 18, y1 + d - 6)
                        t = S.rulerObj("Text") t.Text, t.Color, t.Position = tostring(k), W, Vector2.new(x0 - d - 4, my + 18)
                        t = S.rulerObj("Text") t.Text, t.Color, t.Position = tostring(k), W, Vector2.new(x1 + d - 4, my + 18)
                    end
                end
            end
        end
    end
    for i = R.used + 1, used do R.pool[i].d.Visible = false end
end
function S.Library:BlurRuler(on) S.Ruler.on = on ~= false end
function S.Library:BlurInset(which, px)
    px = tonumber(px)
    if not px then return end
    S.Const.blurManual = true -- hand-set: the measured auto inset (S.Blur.autoInset) stops overwriting
    if which == "window" then S.Const.BLUR_INSET = px
    elseif which == "small" then S.Const.BLUR_INSET_SMALL = px
    elseif which == "intro" then S.Const.BLUR_INSET_INTRO = px
    elseif which == "yless" then S.Const.BLUR_Y_LESS = px -- top/bottom = side inset minus this
    elseif S.Const.BLUR_EDGE[which] then S.Const.BLUR_EDGE[which] = px end -- "top" / "bottom" / "left" / "right": extra trim
    print("blur inset " .. tostring(which) .. " = " .. tostring(px))
end
function S.Library:Unload() UI.Unload() end
function S.Library:OnUnload(fn) table.insert(S.onUnloadList, fn) end
-- a draggable always-on-top panel; see "Overlays" in the API doc
function S.Library:CreateOverlay(opts) return S.newOverlay(opts) end

function S.centerWin()
    local ok, vp = pcall(function() return S.vpLogical() end)
    if ok and vp then
        S.Win.x = math.floor((vp.X - S.Win.w) / 2)
        S.Win.y = math.floor((vp.Y - S.Win.h) / 2)
        S.Win.dirty = true
    end
end

-- load persisted state from disk (runs once FOLDER/CFGSUB are known, i.e. inside CreateWindow)
function S.loadPersisted()
    S.Cfg.autoLoad = S.readAutoload()   -- autoload pointer is the source of truth
    if S.rAutoLoad then S.rAutoLoad.value = S.Cfg.autoLoad end
    -- old settings.json files also hold UI values: they apply until a global ui.json exists
    local hasUI = isfile(S.UI_PATH)
    local sp = isfile(S.FOLDER .. "/settings.json") and S.FOLDER .. "/settings.json" or (isfile(S.FOLDER .. "/settings.lua") and S.FOLDER .. "/settings.lua" or nil)
    if sp then
        local ok, txt = pcall(readfile, sp)
        if ok and txt then S.loadSnapshot(txt, hasUI and "script" or nil) end
    end
    if S.Cfg.autoLoad and S.Cfg.autoLoad ~= "none" then
        local cp = isfile(S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".json") and S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".json"
            or (isfile(S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".lua") and S.cfgDir() .. "/" .. S.Cfg.autoLoad .. ".lua" or nil)
        if cp then
            local ok, txt = pcall(readfile, cp)
            if ok and txt then S.loadSnapshot(txt, "script") end
        end
        if S.rAutoLoad then S.rAutoLoad.value = S.Cfg.autoLoad end
    end
    if hasUI then
        local ok, txt = pcall(readfile, S.UI_PATH)
        if ok and txt then S.loadSnapshot(txt, "ui") end
    end
    -- built-in (Settings) cards already exist by now; cards made later are restored in addSection
    for idx, page in pairs(S.Pages) do
        for _, sec in ipairs(page.sections) do
            if S.savedCollapsed(idx, sec.title) then sec.collapsed = true sec.colT = 0 end
        end
    end
    -- centred unless "Remember window position" is on (then the saved x / y from ui.json, kept on screen)
    if S.Cfg.rememberPos then
        local ok, vp = pcall(S.vpLogical)
        if ok and vp then
            S.Win.x = math.clamp(S.Win.x, 0, math.max(0, vp.X - S.Win.w))
            S.Win.y = math.clamp(S.Win.y, 0, math.max(0, vp.Y - S.Win.h))
        end
    else
        S.centerWin()
    end
end

function S.sanitizeName(s) return (tostring(s):gsub("[^%w_%-]", "")) end

-- the window is only built/shown when the consumer calls this (nothing on disk is touched
-- and nothing is shown until then). all fields optional; nil keeps the default.
function S.Library:CreateWindow(opts)
    opts = opts or {}
    S.previewOnly = opts.PreviewOnly == true
    S.perfMark("createWindow")
    S.perfStart()
    if opts.Title ~= nil then S.BRAND = tostring(opts.Title) end
    -- storage folder: LegoSense/<Folder or FileSettings.Folder or Title> (see S.ROOT)
    local fname = opts.Folder or (type(opts.FileSettings) == "table" and opts.FileSettings.Folder) or opts.Title
    if fname ~= nil then
        local f = S.sanitizeName(fname)
        if #f > 0 then S.FOLDER = S.ROOT .. "/" .. f S.ensureDir(S.FOLDER) S.migrateOld(f) end
    end
    if opts.Subtitle ~= nil then S.SUBTITLE = tostring(opts.Subtitle) end
    if opts.Version ~= nil then S.VERSION = tostring(opts.Version) end
    if opts.Icon ~= nil then S.WinIcon = opts.Icon end
    if type(opts.FileSettings) == "table" and opts.FileSettings.ConfigFolder then
        local c = S.sanitizeName(opts.FileSettings.ConfigFolder)
        if #c > 0 then S.CFGSUB = c end
    end
    S.BudgetT0 = os.clock()
    S.perfBootMark("assetsStart")
    S.startAssets()
    S.loadYield()
    S.perfBootMark("persistedSettingsStart")
    S.loadPersisted()
    S.perfBootMark("persistedSettingsEnd")
    S.perfPrepare()
    S.loadYield()
    S.loadThemeImage(S.Cfg.preset)   -- force the active theme's bg image once, after config load
    -- Home tab first in the sidebar (Home = false: none; Home = { Discord, Changelog, Quick, Name, Icon })
    if opts.Home ~= false then
        S.perfBootMark("homeBuildStart")
        S.Library:CreateHome(type(opts.Home) == "table" and opts.Home or {})
        S.perfBootMark("homeBuildEnd")
    end
    S.loadYield()
    UI.created = true
    S.perfMark("windowReady")
    -- Spotlight's parts are built on first open (~46 ms frame): build them in idle time a moment after load instead
    if not S.Cfg.perfMode then
        task.delay(2.5, function()
            if UI.created and not S.unloaded and not S.Cfg.perfMode and not S.Spot.open then pcall(S.spotInit) end
        end)
    end
    -- Intro = false in CreateWindow (or the setting off) opens the window straight away
    if not S.Cfg.perfMode and opts.Intro ~= false and S.Cfg.intro ~= false and S.Env.drawing and not S.Env.matcha then
        S.introStart()
    else
        S.setVisible(true)
    end
    S.perfBootMark("windowLayoutStart")
    S.relayout()
    S.perfBootMark("windowLayoutEnd")
    -- crude forcer: poll for a few seconds after load and hard-apply the theme image once its
    -- data arrives (Size before Data, then Visible toggle) so it always shows up on start.
    task.spawn(function()
        local forced = {}
        for _ = 1, 100 do -- 15 s: covers the intro (window hidden) plus a slow image download
            if S.unloaded then return end
            local key = S.themeImageKey(S.Cfg.preset)
            local data = UI.themeImg[key]
            local r = UI.themeImgRect
            if data and r and S.Win.visible and not forced[key] then
                S.perfBootMark("themeImageForceStart")
                pcall(function()
                    S.D.themeImg.Visible = false
                    S.D.themeImg.Size = Vector2.new(r.w, r.h)
                    S.D.themeImg.Position = Vector2.new(r.x, r.y)
                    S.D.themeImg.Data = data
                    S.D.themeImg.Visible = S.Win.visible and S.Cfg.themeImg ~= false
                end)
                UI.themeImgApplied = key
                UI.themeBlurKey = nil -- sharp picture is back: relayout re-applies the blurred one if the slider is up
                forced[key] = true
                S.Win.dirty = true
                S.perfBootMark("themeImageForceEnd")
            end
            task.wait(0.15)
        end
    end)
    return S.Library
end

S.setVisible(false)   -- stay hidden and untouched until CreateWindow is called
S.relayout()
S.perfMark("libraryReady")

-- regular executors: local Lib = loadstring(src)()
-- Matcha drops chunk return values, so there: loadstring(src)() then local Lib = _G.FALUI.Library
return S.Library
