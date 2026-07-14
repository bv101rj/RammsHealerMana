local addonName, ns = ...

------------------------------------------------------------------------
-- Defaults & Constants
------------------------------------------------------------------------

local defaults = {
    font        = "Fonts\\FRIZQT__.TTF",
    fontSize    = 12,
    classColors = true,
}

local FONT_LIST = {
    { name = "Friz Quadrata",  path = "Fonts\\FRIZQT__.TTF"  },
    { name = "Arial Narrow",   path = "Fonts\\ARIALN.TTF"    },
    { name = "Morpheus",       path = "Fonts\\MORPHEUS.TTF"  },
    { name = "Skurri",         path = "Fonts\\SKURRI.TTF"    },
}

local FONT_SIZE_OPTIONS = { 10, 11, 12, 13, 14, 16, 18, 20, 24 }

local UPDATE_INTERVAL = 0.5
local LINE_PAD = 4          -- pixels between each line
local FRAME_PAD = 4         -- inner padding

-- Preview names shown in Edit Mode when no group is active
local PREVIEW_DATA = {
    { name = "Thalindra",   class = "PRIEST",  pct = 82 },
    { name = "Oakbreeze",   class = "DRUID",   pct = 47 },
    { name = "Valorshield", class = "PALADIN", pct = 63 },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local db                    -- reference to RammsHealerManaDB
local healerUnits = {}      -- ordered list of unit tokens
local fontStrings = {}      -- reusable FontString pool
local elapsed = 0
local inEditMode = false
local LEM                   -- LibEditMode ref, set after ADDON_LOADED

------------------------------------------------------------------------
-- Main frame
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "RammsHealerManaFrame", UIParent)
frame:SetSize(180, 60)
frame:SetPoint("CENTER")
frame:SetClampedToScreen(true)

local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.35)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function FontPath()
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

-- Return or create the i-th FontString
local function GetLine(i)
    if not fontStrings[i] then
        local fs = frame:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fontStrings[i] = fs
    end
    return fontStrings[i]
end

local function HideAllLines()
    for _, fs in ipairs(fontStrings) do
        fs:Hide()
    end
end

------------------------------------------------------------------------
-- Edit Mode detection
--   Enter: LEM "layout" callback sets inEditMode = true
--   Exit:  checked in OnUpdate via EditModeManagerFrame
------------------------------------------------------------------------

local function CheckEditModeExit()
    if not inEditMode then return end
    -- EditModeManagerFrame is Blizzard's built-in edit mode manager (DF+)
    if EditModeManagerFrame
        and type(EditModeManagerFrame.IsEditModeActive) == "function"
        and not EditModeManagerFrame:IsEditModeActive() then
        inEditMode = false
        return true   -- state changed
    end
end

------------------------------------------------------------------------
-- Roster scanning — only runs on GROUP_ROSTER_UPDATE / PLAYER_ENTERING_WORLD
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

    -- Stable sort by name so the list doesn't jump around
    table.sort(healerUnits, function(a, b)
        return (UnitName(a) or "") < (UnitName(b) or "")
    end)
end

------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------

local function ApplyFont(fs)
    fs:SetFont(FontPath(), FontSize(), "OUTLINE")
end

local function RenderLine(index, text, r, g, b)
    local fs = GetLine(index)
    ApplyFont(fs)
    local lineH = FontSize() + LINE_PAD
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", FRAME_PAD, -((index - 1) * lineH) - FRAME_PAD)
    fs:SetPoint("RIGHT", frame, "RIGHT", -FRAME_PAD, 0)
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:Show()
    return lineH
end

local function ResizeFrame(lineCount)
    local lineH = FontSize() + LINE_PAD
    local height = math.max(lineCount, 1) * lineH + FRAME_PAD * 2
    local width = math.max(frame:GetWidth(), 120)
    frame:SetSize(width, height)
end

-- Called every UPDATE_INTERVAL seconds
local function RefreshDisplay()
    HideAllLines()

    -- Edit Mode preview --------------------------------------------------
    if inEditMode and #healerUnits == 0 then
        local useClass = ClassColorsEnabled()
        for i, data in ipairs(PREVIEW_DATA) do
            local r, g, b = 1, 1, 1
            if useClass then
                local color = RAID_CLASS_COLORS[data.class]
                if color then r, g, b = color.r, color.g, color.b end
            end
            RenderLine(i, string.format("%s: %d%%", data.name, data.pct), r, g, b)
        end
        ResizeFrame(#PREVIEW_DATA)
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
            local power    = UnitPower(unit, Enum.PowerType.Mana)
            local maxPower = UnitPowerMax(unit, Enum.PowerType.Mana)
            local pct = 0
            if maxPower > 0 then
                pct = math.floor(power / maxPower * 100 + 0.5)
            end

            local r, g, b = 1, 1, 1
            if useClass then
                local _, classFile = UnitClass(unit)
                local color = RAID_CLASS_COLORS[classFile]
                if color then r, g, b = color.r, color.g, color.b end
            end

            RenderLine(i, string.format("%s: %d%%", name, pct), r, g, b)
        end
    end

    ResizeFrame(#healerUnits)
    frame:Show()
end

------------------------------------------------------------------------
-- Throttled OnUpdate
------------------------------------------------------------------------

frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < UPDATE_INTERVAL then return end
    elapsed = 0

    -- Lightweight edit-mode exit check (runs at same 0.5s cadence)
    if CheckEditModeExit() then
        RefreshDisplay()
        return
    end

    RefreshDisplay()
end)

------------------------------------------------------------------------
-- LibEditMode integration
------------------------------------------------------------------------

local function SetupLEM()
    LEM = LibStub and LibStub("LibEditMode", true)
    if not LEM then
        print("|cffff6060RammsHealerMana:|r LibEditMode not found.")
        return
    end

    LEM:AddFrame(frame, {
        name = "Healer Mana",
        defaultX = GetScreenWidth() / 2 - 90,
        defaultY = GetScreenHeight() / 2,
    })

    -- Layout callback — fires when entering Edit Mode
    LEM:RegisterCallback("layout", function()
        inEditMode = true
        RefreshDisplay()
    end)

    -- Build font option lists
    local fontNames = {}
    for _, f in ipairs(FONT_LIST) do
        fontNames[#fontNames + 1] = f.name
    end

    local fontSizeStrings = {}
    for _, s in ipairs(FONT_SIZE_OPTIONS) do
        fontSizeStrings[#fontSizeStrings + 1] = tostring(s)
    end

    local function indexOf(tbl, val)
        for i, v in ipairs(tbl) do
            if v == val then return i end
        end
        return 1
    end

    LEM:AddFrameSettings(frame, {
        -- Font family
        {
            settingType = LEM.SettingType.Dropdown,
            name = "Font",
            options = fontNames,
            get = function()
                local cur = FontPath()
                for i, f in ipairs(FONT_LIST) do
                    if f.path == cur then return i end
                end
                return 1
            end,
            set = function(idx)
                db.font = FONT_LIST[idx].path
                RefreshDisplay()
            end,
        },
        -- Font size
        {
            settingType = LEM.SettingType.Dropdown,
            name = "Font Size",
            options = fontSizeStrings,
            get = function()
                return indexOf(FONT_SIZE_OPTIONS, FontSize())
            end,
            set = function(idx)
                db.fontSize = FONT_SIZE_OPTIONS[idx]
                RefreshDisplay()
            end,
        },
        -- Class colors toggle
        {
            settingType = LEM.SettingType.Dropdown,
            name = "Class Colors",
            options = { "Enabled", "Disabled" },
            get = function()
                return ClassColorsEnabled() and 1 or 2
            end,
            set = function(idx)
                db.classColors = (idx == 1)
                RefreshDisplay()
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

        -- Init saved variables
        if not RammsHealerManaDB then
            RammsHealerManaDB = CopyTable(defaults)
        end
        db = RammsHealerManaDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

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
SlashCmdList["RHM"] = function()
    print("|cff00ccffRammsHealerMana|r — Enter Edit Mode to move, resize, and configure.")
    print("  Font, font size, and class colors are in the frame's Edit Mode settings.")
end
