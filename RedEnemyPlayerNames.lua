-- Red Enemy Player Names
-- Makes enemy players easy to spot on the default nameplates: colors their
-- names and adds a small faction icon. Everything else about the nameplates
-- (health bars, size, layout, CVars) is left to Blizzard and other addons.
--
-- Copyright (C) 2026 Ariq
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. It is distributed WITHOUT ANY WARRANTY; see the LICENSE
-- file or <https://www.gnu.org/licenses/> for details.

local DISPLAY_NAME = "Red Enemy Player Names"

local DEFAULTS = {
    enemyPlayers = true,
    enemyPlayerColor = { r = 1, g = 0.1, b = 0.1 },
    colorMode = "custom", -- "custom" or "class"
    factionIcon = true,
    iconSize = 16,
    hostileNPCs = false,
    hostileNPCColor = { r = 1, g = 0.45, b = 0.1 },
}

local db

------------------------------------------------------------------------
-- Saved settings
------------------------------------------------------------------------

local function CopyTable(src)
    local out = {}
    for k, v in pairs(src) do
        out[k] = type(v) == "table" and CopyTable(v) or v
    end
    return out
end

local function FillMissing(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then
                target[k] = CopyTable(v)
            else
                FillMissing(target[k], v)
            end
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

------------------------------------------------------------------------
-- Safe API access
-- Forever can hide some unit information from addons during combat
-- ("secret" values). Treat those, and any API error, as "unknown".
------------------------------------------------------------------------

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok or IsSecret(a) or IsSecret(b) then return nil end
    return a, b
end

local function IsNameplateUnit(unit)
    return type(unit) == "string" and not IsSecret(unit) and unit:find("^nameplate") ~= nil
end

-- Returns "player", "npc", "other", or nil when the game won't tell us.
local function Classify(unit)
    local hostile = SafeCall(UnitIsEnemy, "player", unit)
    if hostile == nil then return nil end
    if not hostile then return "other" end

    local isPlayer = SafeCall(UnitIsPlayer, unit)
    if isPlayer == nil then return nil end
    if isPlayer then return "player" end

    -- Pets and guardians belong to players. Leave them alone.
    local controlled = SafeCall(UnitPlayerControlled, unit)
    if controlled then return "other" end
    return "npc"
end

-- class is the English class token ("MAGE"), or nil if unknown.
local function PickColor(kind, class)
    if kind == "player" and db.enemyPlayers then
        if db.colorMode == "class" and class then
            local c = (C_ClassColor and C_ClassColor.GetClassColor(class))
                or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
            if c then return c.r, c.g, c.b end
        end
        local c = db.enemyPlayerColor
        return c.r, c.g, c.b
    elseif kind == "npc" and db.hostileNPCs then
        local c = db.hostileNPCColor
        return c.r, c.g, c.b
    end
end

local function ColorFor(unit, kind)
    local class
    if kind == "player" and db.colorMode == "class" then
        local _
        _, class = SafeCall(UnitClass, unit)
    end
    return PickColor(kind, class)
end

------------------------------------------------------------------------
-- Name coloring
------------------------------------------------------------------------

local painted = setmetatable({}, { __mode = "k" })  -- frame -> true
local original = setmetatable({}, { __mode = "k" }) -- frame -> Blizzard's color

local function Paint(frame, r, g, b)
    local name = frame.name
    if not painted[frame] then
        -- Remember Blizzard's color so it can be put back exactly.
        local ok, or_, og, ob = pcall(name.GetVertexColor, name)
        original[frame] = (ok and type(or_) == "number") and { or_, og, ob } or nil
        painted[frame] = true
    end
    name:SetVertexColor(r, g, b)
end

local function Unpaint(frame)
    if not painted[frame] then return end
    painted[frame] = nil
    local o = original[frame]
    original[frame] = nil
    if o then
        frame.name:SetVertexColor(o[1], o[2], o[3])
    else
        frame.name:SetVertexColor(1, 1, 1)
    end
end

------------------------------------------------------------------------
-- Faction icon
------------------------------------------------------------------------

-- High-resolution art first. Each list ends with the PvP banner icon, which
-- every client has. Banner icons have a border, so they get trimmed.
local FACTION_ART = {
    Horde = {
        atlases = { "UI-HUD-UnitFrame-Player-PVP-HordeIcon", "QuestPortraitIcon-Horde" },
        file = "Interface\\Icons\\Inv_BannerPVP_01",
    },
    Alliance = {
        atlases = { "UI-HUD-UnitFrame-Player-PVP-AllianceIcon", "QuestPortraitIcon-Alliance" },
        file = "Interface\\Icons\\Inv_BannerPVP_02",
    },
}

-- Pick the first atlas this client has and remember its shape (width / height).
for _, art in pairs(FACTION_ART) do
    art.aspect = 1
    for _, atlas in ipairs(art.atlases) do
        local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
        if info then
            art.atlas = atlas
            if info.width and info.height and info.height > 0 then
                art.aspect = info.width / info.height
            end
            break
        end
    end
end

local icons = setmetatable({}, { __mode = "k" })    -- frame -> texture
local iconFaction = setmetatable({}, { __mode = "k" })

local function SetFactionArt(icon, faction)
    if iconFaction[icon] == faction then return end
    iconFaction[icon] = faction
    local art = FACTION_ART[faction]
    if art.atlas then
        -- Trilinear filtering keeps large art sharp when shrunk to nameplate size.
        icon:SetAtlas(art.atlas, false, "TRILINEAR")
    else
        icon:SetTexture(art.file, nil, nil, "TRILINEAR")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    if icon.SetSnapToPixelGrid then icon:SetSnapToPixelGrid(false) end
    if icon.SetTexelSnappingBias then icon:SetTexelSnappingBias(0) end
end

local function PlaceIcon(frame, icon)
    local name = frame.name
    local art = FACTION_ART[iconFaction[icon]]
    local size = db.iconSize
    icon:SetSize(size * (art and art.aspect or 1), size)
    icon:ClearAllPoints()

    if name:IsShown() then
        -- Sit just left of the visible text, with the icon's bottom level with
        -- the bottom of the name, so it grows upward and never covers the bar.
        local width = SafeCall(name.GetStringWidth, name)
        local justify = name:GetJustifyH()
        if width and justify == "CENTER" then
            icon:SetPoint("BOTTOMRIGHT", name, "BOTTOM", -(width / 2) - 3, 0)
        elseif width and justify == "RIGHT" then
            icon:SetPoint("BOTTOMRIGHT", name, "BOTTOMRIGHT", -width - 3, 0)
        else
            icon:SetPoint("BOTTOMRIGHT", name, "BOTTOMLEFT", -3, 0)
        end
    elseif frame.healthBar then
        icon:SetPoint("RIGHT", frame.healthBar, "LEFT", -3, 0)
    else
        return false
    end
    return true
end

local function UpdateIcon(frame, kind)
    local icon = icons[frame]
    if kind == "player" and db.factionIcon then
        local faction = SafeCall(UnitFactionGroup, frame.unit)
        if FACTION_ART[faction] then
            if not icon then
                icon = frame:CreateTexture(nil, "OVERLAY")
                icons[frame] = icon
            end
            SetFactionArt(icon, faction)
            if PlaceIcon(frame, icon) then
                icon:Show()
                return
            end
        end
    end
    if icon then icon:Hide() end
end

------------------------------------------------------------------------
-- Applying to nameplates
------------------------------------------------------------------------

local function Apply(frame)
    if not db or not frame or not frame.name then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    if not IsNameplateUnit(frame.unit) then return end

    local kind = Classify(frame.unit)
    if kind == nil then return end -- unknown right now: keep what's there

    local r, g, b = ColorFor(frame.unit, kind)
    if r then
        Paint(frame, r, g, b)
    else
        Unpaint(frame)
    end
    UpdateIcon(frame, kind)
end

local function Clear(frame)
    Unpaint(frame)
    if icons[frame] then icons[frame]:Hide() end
end

local function RefreshAll()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        Apply(plate.UnitFrame)
    end
end

-- Blizzard repaints names here (new unit, target change, etc.).
if type(CompactUnitFrame_UpdateName) == "function" then
    hooksecurefunc("CompactUnitFrame_UpdateName", Apply)
end

------------------------------------------------------------------------
-- Settings panel
------------------------------------------------------------------------

local panel = CreateFrame("Frame")
panel.name = DISPLAY_NAME
panel:Hide()

local settingsCategory
local widgets = {}
local UpdatePreview -- defined in BuildPanel

-- Called whenever a setting changes: update live nameplates and the preview.
local function OnSettingChanged()
    RefreshAll()
    if UpdatePreview then UpdatePreview() end
end

local function AddTooltip(region, text)
    region:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    region:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreateCheckbox(label, tooltip, key)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    text:SetText(label)
    cb.labelText = text
    cb:SetScript("OnClick", function(self)
        db[key] = self:GetChecked() and true or false
        for _, w in ipairs(widgets) do w:Refresh() end -- update greyed-out options
        OnSettingChanged()
    end)
    cb.Refresh = function(self) self:SetChecked(db[key]) end
    AddTooltip(cb, tooltip)
    table.insert(widgets, cb)
    return cb
end

-- One of a group of choices. isEnabled (optional) greys it out when false.
local function CreateRadio(label, tooltip, key, value, isEnabled)
    local rb = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
    local text = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    text:SetText(label)
    rb.labelText = text
    rb:SetScript("OnClick", function()
        db[key] = value
        for _, w in ipairs(widgets) do w:Refresh() end
        OnSettingChanged()
    end)
    rb.Refresh = function(self)
        self:SetChecked(db[key] == value)
        local enabled = not isEnabled or isEnabled()
        self:SetEnabled(enabled)
        text:SetFontObject(enabled and "GameFontHighlight" or "GameFontDisable")
    end
    AddTooltip(rb, tooltip)
    table.insert(widgets, rb)
    return rb
end

local function OpenColorPicker(color, onChange)
    local pr, pg, pb = color.r, color.g, color.b
    local function set(r, g, b)
        color.r, color.g, color.b = r, g, b
        onChange()
    end
    local info = {
        r = pr, g = pg, b = pb,
        hasOpacity = false,
        swatchFunc = function() set(ColorPickerFrame:GetColorRGB()) end,
        cancelFunc = function() set(pr, pg, pb) end,
    }
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
    else
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.func = info.swatchFunc
        ColorPickerFrame.cancelFunc = info.cancelFunc
        ColorPickerFrame:SetColorRGB(pr, pg, pb)
        ColorPickerFrame:Show()
    end
end

-- isActive (optional) dims the swatch when its color isn't currently used.
local function CreateSwatch(anchorTo, key, isActive)
    local swatch = CreateFrame("Button", nil, panel)
    swatch:SetSize(18, 18)
    swatch:SetPoint("LEFT", anchorTo.labelText, "RIGHT", 10, 0)
    local border = swatch:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0.85, 0.85, 0.85)
    local fill = swatch:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    swatch.Refresh = function()
        local c = db[key]
        fill:SetColorTexture(c.r, c.g, c.b)
        swatch:SetAlpha((not isActive or isActive()) and 1 or 0.35)
    end
    swatch:SetScript("OnClick", function()
        OpenColorPicker(db[key], function()
            swatch.Refresh()
            OnSettingChanged()
        end)
    end)
    AddTooltip(swatch, "Click to choose a color.")
    table.insert(widgets, swatch)
    return swatch
end

local function CreateSizeSlider(label, key, minValue, maxValue)
    local holder = CreateFrame("Frame", nil, panel)
    holder:SetSize(300, 40)

    local text = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT")
    text:SetText(label)

    local slider = CreateFrame("Slider", nil, holder)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(180, 16)
    slider:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -6)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.25, 0.25, 0.25, 0.9)
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")

    local valueText = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    valueText:SetPoint("LEFT", slider, "RIGHT", 10, 0)

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        valueText:SetText(value)
        if not self.refreshing and db[key] ~= value then
            db[key] = value
            OnSettingChanged()
        end
    end)

    holder.Refresh = function()
        slider.refreshing = true
        slider:SetValue(db[key])
        valueText:SetText(db[key])
        slider.refreshing = false
    end
    table.insert(widgets, holder)
    return holder
end

local function RefreshWidgets()
    for _, w in ipairs(widgets) do w:Refresh() end
    if UpdatePreview then UpdatePreview() end
end

-- Sample nameplates drawn with the same coloring and icon code as the real ones.
local PREVIEW_ROWS = {
    { label = "Vorgash", kind = "player", class = "WARRIOR", faction = "Horde" },
    { label = "Elarion", kind = "player", class = "MAGE", faction = "Alliance" },
    { label = "Forest Wolf", kind = "npc" },
}

local function FirstFont(...)
    for i = 1, select("#", ...) do
        local font = _G[select(i, ...)]
        if font then return font end
    end
end

local function BuildPreview()
    local box = CreateFrame("Frame", nil, panel)
    box:SetSize(220, 190)
    box:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -76)

    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)

    local header = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOP", 0, -8)
    header:SetText("Preview")

    local nameFont = FirstFont("SystemFont_NamePlate", "SystemFont_NamePlateFixed", "GameFontHighlightSmall")
    local rows = {}

    for i, sample in ipairs(PREVIEW_ROWS) do
        local row = {}
        row.healthBar = CreateFrame("StatusBar", nil, box)
        row.healthBar:SetSize(150, 10)
        row.healthBar:SetPoint("TOP", box, "TOP", 0, -30 - (i * 46) + 18)
        row.healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        row.healthBar:SetStatusBarColor(0.8, 0, 0)
        row.healthBar:SetMinMaxValues(0, 1)
        row.healthBar:SetValue(1)

        local barBg = row.healthBar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(0, 0, 0, 0.6)

        row.name = box:CreateFontString(nil, "ARTWORK")
        row.name:SetFontObject(nameFont)
        row.name:SetPoint("BOTTOM", row.healthBar, "TOP", 0, 3)
        row.name:SetJustifyH("CENTER")
        row.name:SetText(sample.label)

        row.icon = box:CreateTexture(nil, "OVERLAY")
        row.sample = sample
        rows[i] = row
    end

    local note = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("BOTTOM", 0, 8)
    note:SetText("Sample names, for illustration only")

    UpdatePreview = function()
        for _, row in ipairs(rows) do
            local s = row.sample
            local r, g, b = PickColor(s.kind, s.class)
            row.name:SetVertexColor(r or 1, g or 1, b or 1)

            if s.kind == "player" and db.factionIcon then
                SetFactionArt(row.icon, s.faction)
                PlaceIcon(row, row.icon)
                row.icon:Show()
            else
                row.icon:Hide()
            end
        end
    end
end

local function BuildPanel()
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(DISPLAY_NAME)

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    sub:SetWidth(560)
    sub:SetJustifyH("LEFT")
    sub:SetText("Makes enemy players easy to spot on the default nameplates. Nothing else about the nameplates is changed.")

    BuildPreview()

    local players = CreateCheckbox("Color enemy player names",
        "Color the names of enemy players, using the option chosen below.", "enemyPlayers")
    players:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -2, -16)

    local playersOn = function() return db.enemyPlayers end

    local custom = CreateRadio("Custom color",
        "Every enemy player's name uses the color on the right.",
        "colorMode", "custom", playersOn)
    custom:SetPoint("TOPLEFT", players, "BOTTOMLEFT", 26, -4)
    CreateSwatch(custom, "enemyPlayerColor", function()
        return db.enemyPlayers and db.colorMode == "custom"
    end)

    local class = CreateRadio("Class colors",
        "Each enemy player's name uses their class color. Falls back to the custom color when the game hides the class (for example, in some combat situations).",
        "colorMode", "class", playersOn)
    class:SetPoint("TOPLEFT", custom, "BOTTOMLEFT", 0, -6)

    local icon = CreateCheckbox("Show faction icon next to enemy player names",
        "Adds a small Horde or Alliance icon to the left of enemy player names.", "factionIcon")
    icon:SetPoint("TOPLEFT", players, "BOTTOMLEFT", 0, -50)

    local size = CreateSizeSlider("Faction icon size", "iconSize", 10, 32)
    size:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 26, -6)

    local npcs = CreateCheckbox("Color hostile NPC names",
        "Hostile mobs' names use the color on the right. Off by default.", "hostileNPCs")
    npcs:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -56)
    CreateSwatch(npcs, "hostileNPCColor")

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOPLEFT", npcs, "BOTTOMLEFT", 2, -24)
    reset:SetText("Reset to defaults")
    reset:SetScript("OnClick", function()
        wipe(db)
        FillMissing(db, DEFAULTS)
        RefreshWidgets()
        OnSettingChanged()
    end)

    panel:SetScript("OnShow", RefreshWidgets)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, DISPLAY_NAME)
        Settings.RegisterAddOnCategory(settingsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function OpenSettings()
    if settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(settingsCategory.GetID and settingsCategory:GetID() or settingsCategory.ID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

SLASH_REDENEMYPLAYERNAMES1 = "/redenemy"
SLASH_REDENEMYPLAYERNAMES2 = "/renp"
SlashCmdList.REDENEMYPLAYERNAMES = OpenSettings

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local plateForUnit = {} -- nameplate token -> UnitFrame

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("UNIT_FACTION")
events:RegisterEvent("PLAYER_TARGET_CHANGED")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "RedEnemyPlayerNames" then return end
        RedEnemyPlayerNamesDB = RedEnemyPlayerNamesDB or {}
        db = RedEnemyPlayerNamesDB
        -- Older versions stored class colors as a separate checkbox.
        if db.classColors ~= nil then
            db.colorMode = db.classColors and "class" or "custom"
            db.classColors = nil
        end
        FillMissing(db, DEFAULTS)
        BuildPanel()
        self:UnregisterEvent("ADDON_LOADED")
    elseif not db then
        return
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local plate = C_NamePlate.GetNamePlateForUnit(arg1)
        local frame = plate and plate.UnitFrame
        plateForUnit[arg1] = frame
        Apply(frame)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        -- Nameplates are recycled. Hand this one back clean.
        local frame = plateForUnit[arg1]
        plateForUnit[arg1] = nil
        if frame then Clear(frame) end
    elseif event == "UNIT_FACTION" then
        if plateForUnit[arg1] then Apply(plateForUnit[arg1]) end
    else
        -- Let Blizzard finish its own update first, then reapply.
        C_Timer.After(0, RefreshAll)
    end
end)
