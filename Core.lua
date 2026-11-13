local addonName, ns = ...

------------------------------------------------------------------------
-- Defaults & Constants
------------------------------------------------------------------------

local defaults = {
    font         = "Friz Quadrata",
    fontSize     = 11,
    classColors  = true,
    updateRate   = 0.1,
    barHeight    = 14,
    barWidth     = 160,
    barTexture   = "Blizzard",
}

local DEFAULT_POSITION = { point = "CENTER", x = 0, y = 0 }

-- Built-in fallbacks (used when LSM is not available)
local BUILTIN_FONTS = {
    { name = "Friz Quadrata",  path = "Fonts\\FRIZQT__.TTF"  },
    { name = "Arial Narrow",   path = "Fonts\\ARIALN.TTF"    },
    { name = "Morpheus",       path = "Fonts\\MORPHEUS.TTF"  },
    { name = "Skurri",         path = "Fonts\\SKURRI.TTF"    },
}

local BUILTIN_TEXTURES = {
    { name = "Blizzard",       path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { name = "Blizzard Raid",  path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"  },
    { name = "Solid",          path = "Interface\\Buttons\\WHITE8X8"            },
}

local FONT_SIZE_OPTIONS = { 9, 10, 11, 12, 13, 14, 16 }

local BAR_HEIGHT_OPTIONS = { 10, 12, 14, 16, 18, 20, 24 }

local BAR_WIDTH_OPTIONS = { 120, 140, 160, 180, 200, 220, 240 }

local UPDATE_RATE_OPTIONS = {
    { label = "Fastest (50ms)",   value = 0.05 },
    { label = "Fast (100ms)",     value = 0.1  },
    { label = "Normal (250ms)",   value = 0.25 },
    { label = "Relaxed (500ms)",  value = 0.5  },
}

local GAP = 2  -- pixels between bars

local MANA_COLOR = { r = 0.0, g = 0.44, b = 0.87 }  -- default mana blue

local PREVIEW_DATA = {
    { name = "Thalindra",   class = "PRIEST",  pct = 82 },
    { name = "Oakbreeze",   class = "DRUID",   pct = 47 },
    { name = "Valorshield", class = "PALADIN", pct = 63 },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local db
local healerUnits = {}
local barPool = {}          -- reusable bar frames
local LEM
local LSM                   -- LibSharedMedia ref, set after ADDON_LOADED

------------------------------------------------------------------------
-- LibSharedMedia integration (optional)
-- If LSM is loaded by another addon, we pull its texture/font lists.
-- Otherwise we fall back to built-in WoW assets.
------------------------------------------------------------------------

local function GetTextureList()
    if LSM then
        local names = LSM:List("statusbar")
        local list = {}
        for i, name in ipairs(names) do
            list[i] = { name = name, path = LSM:Fetch("statusbar", name) }
        end
        return list
    end
    return BUILTIN_TEXTURES
end

local function GetFontList()
    if LSM then
        local names = LSM:List("font")
        local list = {}
        for i, name in ipairs(names) do
            list[i] = { name = name, path = LSM:Fetch("font", name) }
        end
        return list
    end
    return BUILTIN_FONTS
end

local FALLBACK_FONT    = "Fonts\\FRIZQT__.TTF"
local FALLBACK_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

-- Returns true if the string looks like a file path rather than a
-- media name (old DB versions stored paths; LSM stores names)
local function LooksLikePath(s)
    return s:find("\\", 1, true) ~= nil
        or s:find("/", 1, true) ~= nil
        or s:lower():find("%.ttf$") ~= nil
        or s:lower():find("%.otf$") ~= nil
        or s:lower():find("%.blp$") ~= nil
        or s:lower():find("%.tga$") ~= nil
end

local function ResolveTexturePath(textureName)
    if type(textureName) ~= "string" or textureName == "" then
        return FALLBACK_TEXTURE
    end
    -- Old DB format stored raw paths — use them directly
    if LooksLikePath(textureName) then
        return textureName
    end
    if LSM then
        local ok, path = pcall(LSM.Fetch, LSM, "statusbar", textureName, true)
        if ok and path then return path end
    end
    for _, t in ipairs(BUILTIN_TEXTURES) do
        if t.name == textureName then return t.path end
    end
    return FALLBACK_TEXTURE
end

local function ResolveFontPath(fontName)
    if type(fontName) ~= "string" or fontName == "" then
        return FALLBACK_FONT
    end
    -- Old DB format stored raw paths — use them directly
    if LooksLikePath(fontName) then
        return fontName
    end
    if LSM then
        local ok, path = pcall(LSM.Fetch, LSM, "font", fontName, true)
        if ok and path then return path end
    end
    for _, f in ipairs(BUILTIN_FONTS) do
        if f.name == fontName then return f.path end
    end
    return FALLBACK_FONT
end

------------------------------------------------------------------------
-- Main container frame
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "RammsHealerManaFrame", UIParent)
frame:SetSize(160, 50)
frame:SetPoint(DEFAULT_POSITION.point, DEFAULT_POSITION.x, DEFAULT_POSITION.y)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:EnableMouse(false)  -- click-through unless /rhm mouse or Edit Mode

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function FontPath()
    local name = db and db.font or defaults.font
    return ResolveFontPath(name)
end

local function FontName()
    return db and db.font or defaults.font
end

local function FontSize()
    return db and db.fontSize or defaults.fontSize
end

local function ClassColorsEnabled()
    if not db then return defaults.classColors end
    if db.classColors == nil then return defaults.classColors end
    return db.classColors
end

local function UpdateRate()
    return db and db.updateRate or defaults.updateRate
end

local function BarHeight()
    return db and db.barHeight or defaults.barHeight
end

local function BarWidth()
    return db and db.barWidth or defaults.barWidth
end

local function BarTextureName()
    return db and db.barTexture or defaults.barTexture
end

local function BarTexturePath()
    return ResolveTexturePath(BarTextureName())
end

local function IsInEditMode()
    return LEM and LEM:IsInEditMode()
end

------------------------------------------------------------------------
-- Update model — no OnUpdate anywhere
--
-- Each bar subscribes to its own unit's power events with
-- RegisterUnitEvent, which filters C-side: the handler only runs for
-- that healer, and only when their mana actually changes. A healer
-- sitting at full mana costs nothing.
--
-- Layout work (sizes, anchors, fonts, colors, names) runs only on
-- roster or settings changes, never per update.
--
-- "Update Rate" caps how often one bar may redraw. The first change
-- draws immediately; further changes inside the window collapse into a
-- single trailing redraw, so the final value always lands.
------------------------------------------------------------------------

local format, floor = string.format, math.floor

-- issecretvalue exists only on clients with secret values (Midnight).
-- Everywhere else nothing is ever secret.
local IsSecret = issecretvalue or function() return false end

------------------------------------------------------------------------
-- Secret-safe percentage (Midnight)
--
-- UnitPowerPercent + CurveConstants.ScaleTo100. The curve argument's
-- position differs between builds:
--   Form A: UnitPowerPercent(unit, powerType, curve)
--   Form B: UnitPowerPercent(unit, powerType, unmodified, curve)
-- The wrong form can succeed yet return 0–1 instead of 0–100 ("1%" at
-- full mana), and a secret can't be inspected to notice. So we probe
-- with the player's own health — not secret, comparable — and cache
-- whichever form actually scales.
------------------------------------------------------------------------

local pctForm          -- "A" or "B" once known
local nextProbe = 0    -- if probing fails, retry at most every 5s

local function ProbeA()
    return UnitHealthPercent("player", CurveConstants.ScaleTo100) > 1.5
end

local function ProbeB()
    return UnitHealthPercent("player", true, CurveConstants.ScaleTo100) > 1.5
end

local function PctForm()
    if pctForm then return pctForm end
    if not (UnitPowerPercent and UnitHealthPercent
            and CurveConstants and CurveConstants.ScaleTo100) then
        return nil
    end
    local now = GetTime()
    if now < nextProbe then return nil end
    nextProbe = now + 5
    local okA, scaledA = pcall(ProbeA)
    if okA and scaledA then pctForm = "A" return pctForm end
    local okB, scaledB = pcall(ProbeB)
    if okB and scaledB then pctForm = "B" return pctForm end
    return nil
end

------------------------------------------------------------------------
-- Draw one bar. Always called through pcall as a safety net, but the
-- normal path throws nothing — secrets are detected, not tripped over.
------------------------------------------------------------------------

local function UpdatePower(bar)
    local unit = bar.unit
    if not unit then return end

    local power, maxPower = UnitPower(unit, 0), UnitPowerMax(unit, 0)
    local plain = not (IsSecret(power) or IsSecret(maxPower))

    -- Fill: StatusBar accepts secrets and does the division C-side.
    -- Max mana rarely changes, so only push it after layout or
    -- UNIT_MAXPOWER — or, with plain numbers, when it actually differs.
    -- (Short-circuit keeps a secret max from ever being compared.)
    if bar.needMax or (plain and maxPower ~= bar.lastMax) then
        bar.needMax = false
        bar.lastMax = plain and maxPower or nil
        bar:SetMinMaxValues(0, maxPower)
    end
    bar:SetValue(power)

    if plain then
        -- Plain numbers (Forever, Classic, unrestricted contexts).
        -- Skip the redraw if the whole-number percent didn't move.
        local pct = maxPower > 0 and floor(power / maxPower * 100 + 0.5) or 0
        if pct ~= bar.lastPct then
            bar.lastPct = pct
            bar.text:SetFormattedText("%s%d%%", bar.prefix, pct)
        end
        return
    end

    -- Secret numbers (Midnight): string.format is whitelisted for
    -- secrets, concatenation with a secret string is allowed, and
    -- SetText accepts the result.
    local form = PctForm()
    if form == "A" then
        bar.text:SetText(bar.prefix
            .. format("%d%%", UnitPowerPercent(unit, 0, CurveConstants.ScaleTo100)))
    elseif form == "B" then
        bar.text:SetText(bar.prefix
            .. format("%d%%", UnitPowerPercent(unit, 0, true, CurveConstants.ScaleTo100)))
    else
        bar.text:SetText(bar.name)  -- fill still shows the level
    end
end

local function OnPowerEvent(bar, event, _, powerType)
    -- Druids in forms also fire energy/rage events; skip non-mana.
    -- Check secrecy first: comparing a secret would throw.
    if powerType and not IsSecret(powerType) and powerType ~= "MANA" then
        return
    end
    if event == "UNIT_MAXPOWER" then
        bar.needMax = true
    end

    local now = GetTime()
    local wait = UpdateRate() - (now - bar.lastUpdate)
    if wait <= 0 then
        bar.lastUpdate = now
        pcall(UpdatePower, bar)
    elseif not bar.pending then
        bar.pending = true
        C_Timer.After(wait, bar.flush)
    end
end

------------------------------------------------------------------------
-- Bar pool
------------------------------------------------------------------------

local function GetBar(index)
    local bar = barPool[index]
    if bar then return bar end

    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetStatusBarTexture(BarTexturePath())

    -- Dark background behind the bar
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.bg = bg

    -- Name + percentage text overlay
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", bar, "LEFT", 4, 0)
    text:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    bar.text = text

    bar.lastUpdate = 0
    -- Trailing redraw for the throttle. One closure per bar, made once.
    bar.flush = function()
        bar.pending = false
        bar.lastUpdate = GetTime()
        pcall(UpdatePower, bar)
    end
    bar:SetScript("OnEvent", OnPowerEvent)

    barPool[index] = bar
    return bar
end

-- Point a bar's event subscriptions at a unit, or at nothing.
local function BindBar(bar, unit)
    if bar.unit == unit then return end
    bar:UnregisterAllEvents()
    bar.unit = unit
    if not unit or not bar.RegisterUnitEvent then return end
    -- FREQUENT gives smooth updates; fall back where it doesn't exist.
    -- Registering an unknown event throws, hence the pcalls.
    if not pcall(bar.RegisterUnitEvent, bar, "UNIT_POWER_FREQUENT", unit) then
        pcall(bar.RegisterUnitEvent, bar, "UNIT_POWER_UPDATE", unit)
    end
    pcall(bar.RegisterUnitEvent, bar, "UNIT_MAXPOWER", unit)
end

------------------------------------------------------------------------
-- Roster scanning — runs only when the group changes
--
-- Midnight/retail (interface 12xxxx): track assigned HEALER roles.
-- Forever (16001) and the Classic flavors (_Classic.toc): no reliable
-- role assignments, so track every group member with a mana pool.
-- Detected by interface number, not WOW_PROJECT_ID (Forever has no
-- documented project constant — the MidnightStatus lesson).
------------------------------------------------------------------------

local NO_ROLES = (select(4, GetBuildInfo()) or 0) < 100000

local MANA_CLASSES = {  -- covers members whose mana hasn't synced yet
    PRIEST = true, PALADIN = true, SHAMAN = true,
    DRUID = true, MAGE = true, WARLOCK = true, HUNTER = true,
}

local function TrackUnit(unit)
    if NO_ROLES then
        local maxPower = UnitPowerMax(unit, 0)
        if not IsSecret(maxPower) and maxPower > 0 then
            return true
        end
        local _, classFile = UnitClass(unit)
        return (classFile and MANA_CLASSES[classFile]) or false
    end
    return UnitGroupRolesAssigned(unit) == "HEALER"
end

local function ByName(a, b)
    return (UnitName(a) or "") < (UnitName(b) or "")
end

local function ScanHealers()
    wipe(healerUnits)

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit)
                and not UnitIsUnit(unit, "player")
                and TrackUnit(unit) then
                healerUnits[#healerUnits + 1] = unit
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            if UnitExists(unit) and TrackUnit(unit) then
                healerUnits[#healerUnits + 1] = unit
            end
        end
    end

    table.sort(healerUnits, ByName)
end

------------------------------------------------------------------------
-- Layout — runs on roster change, settings change, Edit Mode enter /
-- exit, and /rhm mouse. This is the only place bars are sized,
-- anchored, styled, named, colored, shown or hidden.
------------------------------------------------------------------------

local function ClassRGB(classFile)
    local color = classFile and RAID_CLASS_COLORS[classFile]
    if color then return color.r, color.g, color.b end
    return MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
end

-- Apply font with fallback — never hard-errors on a bad path. Cached
-- per fontstring so an unchanged font is never re-applied.
local function SafeSetFont(fs)
    local path, size = FontPath(), FontSize()
    if fs.rhmFontPath == path and fs.rhmFontSize == size then
        return
    end
    local ok = pcall(fs.SetFont, fs, path, size, "OUTLINE")
    if not ok or not fs:GetFont() then
        pcall(fs.SetFont, fs, FALLBACK_FONT, size, "OUTLINE")
        path = FALLBACK_FONT
    end
    fs.rhmFontPath = path
    fs.rhmFontSize = size
end

local function Layout()
    local placing = IsInEditMode()
        or (db and db.mouse and not frame.__lemManaged)
    local preview = placing and #healerUnits == 0
    local count = preview and #PREVIEW_DATA or #healerUnits

    -- Release bars we won't use: hide them and drop their events
    for i = count + 1, #barPool do
        BindBar(barPool[i], nil)
        barPool[i]:Hide()
    end

    if count == 0 then
        frame:Hide()
        return
    end

    local bw, bh = BarWidth(), BarHeight()
    local texture = BarTexturePath()
    local useClass = ClassColorsEnabled()

    for i = 1, count do
        local bar = GetBar(i)
        bar:SetSize(bw, bh)
        bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -((i - 1) * (bh + GAP)))
        bar:SetStatusBarTexture(texture)
        SafeSetFont(bar.text)
        bar.lastPct = nil   -- whoever is in this slot may have changed
        bar.needMax = true

        local r, g, b = MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
        if preview then
            local data = PREVIEW_DATA[i]
            BindBar(bar, nil)
            if useClass then r, g, b = ClassRGB(data.class) end
            bar:SetStatusBarColor(r, g, b, 0.85)
            bar:SetMinMaxValues(0, 100)
            bar:SetValue(data.pct)
            bar.text:SetFormattedText("%s: %d%%", data.name, data.pct)
        else
            local unit = healerUnits[i]
            local name = UnitName(unit) or "?"
            bar.name = name
            bar.prefix = name .. ": "
            if useClass then
                local _, classFile = UnitClass(unit)
                r, g, b = ClassRGB(classFile)
            end
            bar:SetStatusBarColor(r, g, b, 0.85)
            BindBar(bar, unit)
            bar.lastUpdate = GetTime()
            pcall(UpdatePower, bar)  -- draw now; events take it from here
        end
        bar:Show()
    end

    frame:SetSize(bw, count * (bh + GAP) - GAP)
    frame:Show()
end

-- GROUP_ROSTER_UPDATE arrives in bursts (raid joins, zone-ins);
-- coalesce each burst into one scan + layout.
local rosterPending = false

local function FlushRoster()
    rosterPending = false
    ScanHealers()
    Layout()
end

local function QueueRoster()
    if rosterPending then return end
    rosterPending = true
    C_Timer.After(0.2, FlushRoster)
end

------------------------------------------------------------------------
-- Position — one shared spot, not per Edit Mode layout (same model as
-- MidnightStatus). Edit Mode layouts follow spec, so per-layout storage
-- made the frame jump around on spec swap.
------------------------------------------------------------------------

-- Set while we place the frame ourselves, so a position callback that
-- LibEditMode fires in response to our own SetPoint can't overwrite the
-- store with a value it just handed us.
local applyingPos = false

local function GetPos()
    local p = db.position
    if type(p) ~= "table"
        or type(p.point) ~= "string"
        or type(p.x) ~= "number"
        or type(p.y) ~= "number" then
        p = CopyTable(DEFAULT_POSITION)
        db.position = p
    end
    return p
end

local function SetPos(point, x, y)
    if applyingPos or type(point) ~= "string" then
        return
    end
    db.position = { point = point, x = x or 0, y = y or 0 }
end

local function ApplyPos()
    local p = GetPos()
    applyingPos = true
    frame:ClearAllPoints()
    frame:SetPoint(p.point, UIParent, p.point, p.x, p.y)
    applyingPos = false
end

local function ApplyMouse()
    frame:EnableMouse(db.mouse and true or false)
end

-- Plain drag only when LibEditMode isn't managing the frame
frame:SetScript("OnDragStart", function(self)
    if not self.__lemManaged then
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    if not self.__lemManaged then
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        SetPos(point, x, y)
    end
end)

------------------------------------------------------------------------
-- LibEditMode glue (optional — loaded by any addon that ships it)
-- Field names verified against working RammsRuneforge code:
--   kind, values, get(layoutName), set(layoutName, value)
------------------------------------------------------------------------

local function SetupLEM()
    if not LibStub then
        return
    end
    local ok, lib = pcall(LibStub, "LibEditMode", true)
    if not ok or not lib then
        return
    end
    LEM = lib

    LEM:RegisterCallback("layout", function()
        ApplyPos()
    end)

    pcall(LEM.RegisterCallback, LEM, "enter", function()
        frame:EnableMouse(true)
        pcall(Layout)
    end)
    pcall(LEM.RegisterCallback, LEM, "exit", function()
        ApplyMouse()
        pcall(Layout)
    end)

    LEM:AddFrame(frame, function(_, _, point, x, y)
        SetPos(point, x, y)
    end, DEFAULT_POSITION)

    frame.__lemManaged = true

    if not (LEM.AddFrameSettings and LEM.SettingType) then
        return
    end

    -- Build option value tables from LSM or built-in lists
    local fontList = GetFontList()
    local fontValues = {}
    for i, f in ipairs(fontList) do
        fontValues[i] = { text = f.name, value = i }
    end

    local textureList = GetTextureList()
    local textureValues = {}
    for i, t in ipairs(textureList) do
        textureValues[i] = { text = t.name, value = i }
    end

    local fontSizeValues = {}
    for i, s in ipairs(FONT_SIZE_OPTIONS) do
        fontSizeValues[i] = { text = tostring(s), value = i }
    end

    local barHeightValues = {}
    for i, h in ipairs(BAR_HEIGHT_OPTIONS) do
        barHeightValues[i] = { text = tostring(h) .. "px", value = i }
    end

    local barWidthValues = {}
    for i, w in ipairs(BAR_WIDTH_OPTIONS) do
        barWidthValues[i] = { text = tostring(w) .. "px", value = i }
    end

    local updateRateValues = {}
    for i, opt in ipairs(UPDATE_RATE_OPTIONS) do
        updateRateValues[i] = { text = opt.label, value = i }
    end

    -- Index lookups (name-based matching)
    local function fontIdx()
        local cur = FontName()
        for i, f in ipairs(fontList) do
            if f.name == cur then return i end
        end
        return 1
    end

    local function textureIdx()
        local cur = BarTextureName()
        for i, t in ipairs(textureList) do
            if t.name == cur then return i end
        end
        return 1
    end

    local function sizeIdx()
        local cur = FontSize()
        for i, s in ipairs(FONT_SIZE_OPTIONS) do
            if s == cur then return i end
        end
        return 3
    end

    local function barHIdx()
        local cur = BarHeight()
        for i, h in ipairs(BAR_HEIGHT_OPTIONS) do
            if h == cur then return i end
        end
        return 3
    end

    local function barWIdx()
        local cur = BarWidth()
        for i, w in ipairs(BAR_WIDTH_OPTIONS) do
            if w == cur then return i end
        end
        return 3
    end

    local function rateIdx()
        local cur = UpdateRate()
        for i, opt in ipairs(UPDATE_RATE_OPTIONS) do
            if opt.value == cur then return i end
        end
        return 2
    end

    pcall(LEM.AddFrameSettings, LEM, frame, {
        {
            name    = "Bar Texture",
            kind    = LEM.SettingType.Dropdown,
            default = 1,
            values  = textureValues,
            get = function(layoutName) return textureIdx() end,
            set = function(layoutName, val)
                db.barTexture = textureList[val].name
                Layout()
            end,
        },
        {
            name    = "Bar Width",
            kind    = LEM.SettingType.Dropdown,
            default = 3,
            values  = barWidthValues,
            get = function(layoutName) return barWIdx() end,
            set = function(layoutName, val)
                db.barWidth = BAR_WIDTH_OPTIONS[val]
                Layout()
            end,
        },
        {
            name    = "Bar Height",
            kind    = LEM.SettingType.Dropdown,
            default = 3,
            values  = barHeightValues,
            get = function(layoutName) return barHIdx() end,
            set = function(layoutName, val)
                db.barHeight = BAR_HEIGHT_OPTIONS[val]
                Layout()
            end,
        },
        {
            name    = "Font",
            kind    = LEM.SettingType.Dropdown,
            default = 1,
            values  = fontValues,
            get = function(layoutName) return fontIdx() end,
            set = function(layoutName, val)
                db.font = fontList[val].name
                Layout()
            end,
        },
        {
            name    = "Font Size",
            kind    = LEM.SettingType.Dropdown,
            default = 3,
            values  = fontSizeValues,
            get = function(layoutName) return sizeIdx() end,
            set = function(layoutName, val)
                db.fontSize = FONT_SIZE_OPTIONS[val]
                Layout()
            end,
        },
        {
            name    = "Class Colors",
            kind    = LEM.SettingType.Dropdown,
            default = 1,
            values  = {
                { text = "Enabled",  value = 1 },
                { text = "Disabled", value = 2 },
            },
            get = function(layoutName) return ClassColorsEnabled() and 1 or 2 end,
            set = function(layoutName, val)
                db.classColors = (val == 1)
                Layout()
            end,
        },
        {
            name    = "Update Rate",
            kind    = LEM.SettingType.Dropdown,
            default = 2,
            values  = updateRateValues,
            get = function(layoutName) return rateIdx() end,
            set = function(layoutName, val)
                db.updateRate = UPDATE_RATE_OPTIONS[val].value
            end,
        },
    })
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- Pull any older per-layout (db.layouts) or drag (db.dragPosition)
-- position into the single shared slot, then drop the old keys.
local function MigratePosition()
    if type(db.position) ~= "table" then
        local src = db.dragPosition
        if type(src) ~= "table" and type(db.layouts) == "table" then
            for _, v in pairs(db.layouts) do
                if type(v) == "table" and type(v.point) == "string" then
                    src = v
                    break
                end
            end
        end
        if type(src) == "table" and type(src.point) == "string" then
            db.position = {
                point = src.point,
                x = tonumber(src.x) or 0,
                y = tonumber(src.y) or 0,
            }
        end
    end
    db.layouts = nil
    db.dragPosition = nil
end

local booted = false

-- Runs once at login, after every addon has loaded, so a LibEditMode or
-- LibSharedMedia shipped inside some other addon is already registered.
local function Boot()
    LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    ApplyMouse()
    pcall(SetupLEM)
    if not frame.__lemManaged then
        ApplyPos()
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Role swaps (retail). Guarded: registering an event a client doesn't
-- have throws, and at file scope that would abort the whole load.
pcall(frame.RegisterEvent, frame, "PLAYER_ROLES_ASSIGNED")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded ~= addonName then return end

        if not RammsHealerManaDB then
            RammsHealerManaDB = {}
        end
        db = RammsHealerManaDB

        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

        -- Sanitize types (protects against mixed-version SavedVariables)
        if type(db.font) ~= "string" then db.font = defaults.font end
        if type(db.barTexture) ~= "string" then db.barTexture = defaults.barTexture end
        if type(db.fontSize) ~= "number" then db.fontSize = defaults.fontSize end
        if type(db.barHeight) ~= "number" then db.barHeight = defaults.barHeight end
        if type(db.barWidth) ~= "number" then db.barWidth = defaults.barWidth end
        if type(db.updateRate) ~= "number" then db.updateRate = defaults.updateRate end
        if type(db.classColors) ~= "boolean" then db.classColors = defaults.classColors end
        if db.mouse == nil then db.mouse = false end

        MigratePosition()
        ApplyPos()

        frame:UnregisterEvent("ADDON_LOADED")
        return
    end

    if (event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD") and not booted then
        booted = true
        Boot()
    end

    if event == "PLAYER_ENTERING_WORLD" then
        FlushRoster()  -- zone-in: unit tokens may have shifted, scan now
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
        QueueRoster()
    end
end)

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------

SLASH_RHM1 = "/rhm"
SlashCmdList["RHM"] = function(msg)
    msg = strtrim(msg):lower()
    if msg == "reset" then
        RammsHealerManaDB = {}
        db = RammsHealerManaDB
        for k, v in pairs(defaults) do db[k] = v end
        db.mouse = false
        ApplyMouse()
        ApplyPos()
        Layout()
        print("|cff00ccffRammsHealerMana|r — Settings reset to defaults.")
        return
    end

    if msg == "mouse" then
        db.mouse = not db.mouse
        ApplyMouse()
        Layout()
        print("|cff00ccffRammsHealerMana|r — mouse " .. (db.mouse and "on" or "off"))
        return
    end

    print("|cff00ccffRammsHealerMana|r — Select the frame in Edit Mode to configure.")
    print("  |cffffcc00/rhm mouse|r — Toggle drag-to-move (no Edit Mode needed).")
    print("  |cffffcc00/rhm reset|r — Reset all settings to defaults.")
end
