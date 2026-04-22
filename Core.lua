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
local elapsed = 0
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

local function ResolveTexturePath(textureName)
    if LSM then
        local path = LSM:Fetch("statusbar", textureName, true)
        if path then return path end
    end
    for _, t in ipairs(BUILTIN_TEXTURES) do
        if t.name == textureName then return t.path end
    end
    return BUILTIN_TEXTURES[1].path
end

local function ResolveFontPath(fontName)
    if LSM then
        local path = LSM:Fetch("font", fontName, true)
        if path then return path end
    end
    for _, f in ipairs(BUILTIN_FONTS) do
        if f.name == fontName then return f.path end
    end
    return BUILTIN_FONTS[1].path
end

------------------------------------------------------------------------
-- Main container frame
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "RammsHealerManaFrame", UIParent)
frame:SetSize(160, 50)
frame:SetPoint(DEFAULT_POSITION.point, DEFAULT_POSITION.x, DEFAULT_POSITION.y)
frame:SetClampedToScreen(true)

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
-- Bar pool — create or reuse a healer bar
------------------------------------------------------------------------

local function GetBar(index)
    if barPool[index] then return barPool[index] end

    local bar = CreateFrame("StatusBar", nil, frame)
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

    barPool[index] = bar
    return bar
end

local function ApplyTextureToAll()
    local path = BarTexturePath()
    for _, bar in ipairs(barPool) do
        bar:SetStatusBarTexture(path)
    end
end

local function HideAllBars()
    for _, bar in ipairs(barPool) do
        bar:Hide()
    end
end

------------------------------------------------------------------------
-- Text helper — try arithmetic for "%", fall back to name only
------------------------------------------------------------------------

local function GetPctText(unit, name)
    local ok, text = pcall(function()
        local power    = UnitPower(unit, 0)
        local maxPower = UnitPowerMax(unit, 0)
        local pct = 0
        if maxPower > 0 then
            pct = math.floor(power / maxPower * 100 + 0.5)
        end
        return string.format("%s: %d%%", name, pct)
    end)
    if ok then return text end

    -- Secret values — bar fill shows the proportion, text shows name only
    return name
end

------------------------------------------------------------------------
-- Bar fill — secret-safe via StatusBar C-side math
--
-- StatusBar:SetMinMaxValues(0, maxPower) — maxPower is non-secret
-- StatusBar:SetValue(power) — power may be secret, but SetValue
-- accepts secrets and handles the proportion internally in C code.
------------------------------------------------------------------------

local function SetBarPower(bar, unit)
    local ok, maxPower = pcall(function()
        return UnitPowerMax(unit, 0)
    end)
    if not ok or not maxPower or maxPower == 0 then
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        return
    end

    bar:SetMinMaxValues(0, maxPower)

    -- SetValue with secret power — C-side handles the fill
    pcall(function()
        bar:SetValue(UnitPower(unit, 0))
    end)
end

------------------------------------------------------------------------
-- Roster scanning
------------------------------------------------------------------------

local function ScanHealers()
    wipe(healerUnits)

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit)
                and not UnitIsUnit(unit, "player")
                and UnitGroupRolesAssigned(unit) == "HEALER" then
                healerUnits[#healerUnits + 1] = unit
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            if UnitExists(unit)
                and UnitGroupRolesAssigned(unit) == "HEALER" then
                healerUnits[#healerUnits + 1] = unit
            end
        end
    end

    table.sort(healerUnits, function(a, b)
        return (UnitName(a) or "") < (UnitName(b) or "")
    end)
end

------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------

local function GetClassColor(unit)
    local _, classFile = UnitClass(unit)
    if classFile then
        local color = RAID_CLASS_COLORS[classFile]
        if color then return color.r, color.g, color.b end
    end
    return MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
end

local function GetClassColorFromFile(classFile)
    local color = RAID_CLASS_COLORS[classFile]
    if color then return color.r, color.g, color.b end
    return MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
end

local function RenderBar(index, text, r, g, b, pctOverride)
    local bw = BarWidth()
    local bh = BarHeight()
    local bar = GetBar(index)

    bar:SetSize(bw, bh)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -((index - 1) * (bh + GAP)))

    bar.text:SetFont(FontPath(), FontSize(), "OUTLINE")
    bar.text:SetText(text)

    -- Bar color
    bar:SetStatusBarColor(r, g, b, 0.85)

    -- If preview (pctOverride), set bar fill directly
    if pctOverride then
        bar:SetMinMaxValues(0, 100)
        bar:SetValue(pctOverride)
    end

    bar:Show()
end

local function RefreshDisplay()
    HideAllBars()

    local bh = BarHeight()
    local bw = BarWidth()

    -- Edit Mode preview --------------------------------------------------
    if IsInEditMode() and #healerUnits == 0 then
        local useClass = ClassColorsEnabled()
        for i, data in ipairs(PREVIEW_DATA) do
            local r, g, b = MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
            if useClass then
                r, g, b = GetClassColorFromFile(data.class)
            end
            RenderBar(i, string.format("%s: %d%%", data.name, data.pct), r, g, b, data.pct)
        end
        frame:SetSize(bw, #PREVIEW_DATA * (bh + GAP) - GAP)
        frame:Show()
        return
    end

    -- No healers ---------------------------------------------------------
    if #healerUnits == 0 then
        frame:Hide()
        return
    end

    -- Live data ----------------------------------------------------------
    local useClass = ClassColorsEnabled()
    for i, unit in ipairs(healerUnits) do
        if UnitExists(unit) then
            local name = UnitName(unit) or "?"
            local text = GetPctText(unit, name)
            local r, g, b = MANA_COLOR.r, MANA_COLOR.g, MANA_COLOR.b
            if useClass then
                r, g, b = GetClassColor(unit)
            end
            RenderBar(i, text, r, g, b)
            -- Set bar fill from actual power (secret-safe)
            SetBarPower(barPool[i], unit)
        end
    end

    frame:SetSize(bw, #healerUnits * (bh + GAP) - GAP)
    frame:Show()
end

------------------------------------------------------------------------
-- Throttled OnUpdate
------------------------------------------------------------------------

frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < UpdateRate() then return end
    elapsed = 0
    RefreshDisplay()
end)

------------------------------------------------------------------------
-- LibEditMode integration
-- Field names verified against working RammsRuneforge code:
--   kind, values, get(layoutName), set(layoutName, value)
------------------------------------------------------------------------

local function SetupLEM()
    LEM = LibStub and LibStub("LibEditMode", true)
    if not LEM then
        print("|cffff6060RammsHealerMana:|r LibEditMode not found.")
        return
    end

    local function OnPositionChanged(f, layoutName, point, x, y)
        db.layouts[layoutName] = { point = point, x = x, y = y }
    end

    LEM:AddFrame(frame, OnPositionChanged, DEFAULT_POSITION)

    LEM:RegisterCallback("layout", function(layoutName)
        local pos = db.layouts[layoutName]
        if not pos then
            pos = CopyTable(DEFAULT_POSITION)
            db.layouts[layoutName] = pos
        end
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, pos.x, pos.y)
    end)

    LEM:RegisterCallback("enter", function()
        RefreshDisplay()
    end)
    LEM:RegisterCallback("exit", function()
        RefreshDisplay()
    end)

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

    LEM:AddFrameSettings(frame, {
        {
            name    = "Bar Texture",
            kind    = LEM.SettingType.Dropdown,
            default = 1,
            values  = textureValues,
            get = function(layoutName) return textureIdx() end,
            set = function(layoutName, val)
                db.barTexture = textureList[val].name
                ApplyTextureToAll()
                RefreshDisplay()
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
                RefreshDisplay()
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
                RefreshDisplay()
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
                RefreshDisplay()
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
                RefreshDisplay()
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
                RefreshDisplay()
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

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

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
        if not db.layouts then db.layouts = {} end

        -- Initialize LibSharedMedia (optional)
        LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

        SetupLEM()
        ScanHealers()
        RefreshDisplay()

        frame:UnregisterEvent("ADDON_LOADED")

    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        ScanHealers()
        RefreshDisplay()
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
        db.layouts = {}
        frame:ClearAllPoints()
        frame:SetPoint(DEFAULT_POSITION.point, DEFAULT_POSITION.x, DEFAULT_POSITION.y)
        RefreshDisplay()
        print("|cff00ccffRammsHealerMana|r — Settings reset to defaults.")
        return
    end

    print("|cff00ccffRammsHealerMana|r — Select the frame in Edit Mode to configure.")
    print("  |cffffcc00/rhm reset|r — Reset all settings to defaults.")
end
