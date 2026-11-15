-- In-game bug reporter (reusable: copy this file into any addon)
--
-- Addons can't open a browser or send anything over the internet. Instead,
-- this builds a link to the addon's GitHub bug report form with every field
-- already filled in: addon and game version, what the player typed, the most
-- recent error from this addon, loaded addons and settings. The player copies
-- the link (Ctrl+C), pastes it into their browser, checks it and submits.
-- Nothing is sent automatically. A plain-text copy of the same report is shown
-- too, in case the link gets cut off or the form comes up empty.
--
-- Errors are caught two ways:
--   * ns.Guard(fn) wraps this addon's code: errors are recorded (and saved, so
--     they survive a /reload), then passed to the normal error handler, so
--     BugSack or Blizzard's error popup behave exactly as they would anyway.
--   * BugGrabber/BugSack, when installed: its saved errors mentioning this
--     addon's folder name are used too.
--
-- Use, in the addon's main file (this file must load first in the .toc):
--   ns.BugReport.Setup({
--       issueURL = "https://github.com/<owner>/<repo>/issues/new",
--       template = "bug_report.yml",                    -- the issue form's file name
--       getStore = function() return MyAddonDB end,     -- a SavedVariables table (optional)
--       getSettings = function() return "a=1, b=2" end, -- one line describing settings (optional)
--   })
--   hooksecurefunc("SomeFunction", ns.Guard(MyHook))  -- for each entry point
--   ns.BugReport.Open()                                -- from a slash command or button
--
-- The issue form's field ids must match the ones below: addon-version,
-- game-version, what-happened, lua-error, other-addons, environment.
--
-- Copyright (C) 2026 Ariq
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. It is distributed WITHOUT ANY WARRANTY; see the LICENSE
-- file or <https://www.gnu.org/licenses/> for details.

local ADDON_NAME, ns = ...

local BugReport = {}
ns.BugReport = BugReport

local config = {}
local MAX_URL_LENGTH = 7000 -- comfortably under what browsers and GitHub accept
local MAX_SAVED_ERRORS = 10
local MAX_SAVED_REPORTS = 5
local SESSION = (time and time() or 0) .. "-" .. math.random(1000, 9999)

function BugReport.Setup(options)
    for k, v in pairs(options) do config[k] = v end
end

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

local GetNumAddOns_ = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
local GetAddOnInfo_ = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
local IsAddOnLoaded_ = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local GetAddOnMetadata_ = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

local function StripColors(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function FirstLine(text, maxChars)
    local line = tostring(text or ""):match("^[^\n]*") or ""
    if #line > maxChars then line = line:sub(1, maxChars - 3) .. "..." end
    return line
end

local function Metadata(field)
    if not GetAddOnMetadata_ then return nil end
    local ok, value = pcall(GetAddOnMetadata_, ADDON_NAME, field)
    return ok and value or nil
end

local function AddOnTitle()
    return StripColors(Metadata("Title") or ADDON_NAME)
end

local function AddOnVersion()
    return Metadata("Version") or "unknown"
end

-- The addon's SavedVariables table, once it has loaded (nil before that).
local function Store()
    local ok, store = pcall(config.getStore or function() end)
    return ok and type(store) == "table" and store or nil
end

local function SavedList(key)
    local store = Store()
    if not store then return nil end
    if type(store[key]) ~= "table" then store[key] = {} end
    return store[key]
end

------------------------------------------------------------------------
-- Catching this addon's errors
------------------------------------------------------------------------

local sessionErrors = {} -- used until the saved table is available

local function RecordError(message, stack)
    local list = SavedList("bugReportErrors") or sessionErrors
    local last = list[#list]
    if last and last.message == message then
        last.count = (last.count or 1) + 1
        last.session = SESSION
        return
    end
    if #list >= MAX_SAVED_ERRORS then table.remove(list, 1) end
    list[#list + 1] = { message = message, stack = stack, count = 1, session = SESSION }
end

local function OnError(err)
    local ok = pcall(RecordError, tostring(err), debugstack and debugstack(2) or "")
    if not ok then -- never let the reporter itself cause trouble
        sessionErrors[#sessionErrors + 1] = { message = tostring(err), stack = "", count = 1, session = SESSION }
    end
    local handler = geterrorhandler and geterrorhandler()
    if handler then pcall(handler, err) end
    return err
end

-- Wraps a function (up to 3 arguments). No tables or closures are created per
-- call, since nameplate and event code runs often.
local gFn, gA, gB, gC
local function GuardedCall() return gFn(gA, gB, gC) end

function ns.Guard(fn)
    return function(a, b, c)
        local pFn, pA, pB, pC = gFn, gA, gB, gC -- in case of nested calls
        gFn, gA, gB, gC = fn, a, b, c
        xpcall(GuardedCall, OnError)
        gFn, gA, gB, gC = pFn, pA, pB, pC
    end
end

local function BugGrabberLatest()
    local grabber = _G.BugGrabber
    if type(grabber) ~= "table" or type(grabber.GetDB) ~= "function" then return nil end
    local ok, errors = pcall(grabber.GetDB, grabber)
    if not ok or type(errors) ~= "table" then return nil end
    local needle = "AddOns/" .. ADDON_NAME .. "/"
    local needle2 = "AddOns\\" .. ADDON_NAME .. "\\"
    for i = #errors, 1, -1 do
        local e = errors[i]
        if type(e) == "table" then
            local message, stack = StripColors(e.message), StripColors(e.stack)
            local mine = message:find(needle, 1, true) or stack:find(needle, 1, true)
                or message:find(needle2, 1, true) or stack:find(needle2, 1, true)
            if mine then
                return { message = message, stack = stack, count = tonumber(e.counter) or 1, source = "BugSack" }
            end
        end
    end
    return nil
end

-- The most relevant error: this session's own record, then BugSack's, then
-- one this addon saved in an earlier session.
local function LatestError()
    local list = SavedList("bugReportErrors")
    local candidates = { sessionErrors[#sessionErrors] }
    if list then candidates[#candidates + 1] = list[#list] end
    for _, e in ipairs(candidates) do
        if e and e.session == SESSION then
            return { message = e.message, stack = e.stack, count = e.count, source = "this session" }
        end
    end
    local fromGrabber = BugGrabberLatest()
    if fromGrabber then return fromGrabber end
    local older = list and list[#list]
    if older then
        return { message = older.message, stack = older.stack, count = older.count, source = "an earlier session" }
    end
    return nil
end

------------------------------------------------------------------------
-- Gathering the report
------------------------------------------------------------------------

local function LoadedAddOns()
    if not (GetNumAddOns_ and GetAddOnInfo_ and IsAddOnLoaded_) then return "unknown" end
    local names = {}
    for i = 1, GetNumAddOns_() do
        local name = GetAddOnInfo_(i)
        if name and name ~= ADDON_NAME and IsAddOnLoaded_(name) then names[#names + 1] = name end
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "none"
end

local function GameVersion()
    if not GetBuildInfo then return "unknown" end
    local version, build = GetBuildInfo()
    return ("%s (%s)"):format(tostring(version), tostring(build))
end

local function Environment()
    local lines = {}
    if GetBuildInfo then
        local _, _, _, toc = GetBuildInfo()
        lines[#lines + 1] = "Interface: " .. tostring(toc)
    end
    if GetLocale then lines[#lines + 1] = "Locale: " .. tostring(GetLocale()) end
    if config.getSettings then
        local ok, settings = pcall(config.getSettings)
        if ok and settings then lines[#lines + 1] = "Settings: " .. tostring(settings) end
    end
    return table.concat(lines, "\n")
end

-- description: what the player typed. err: LatestError() or nil.
local function Gather(description, err)
    local report = {
        addonVersion = AddOnVersion(),
        gameVersion = GameVersion(),
        description = description,
        addons = LoadedAddOns(),
        environment = Environment(),
        errorText = "",
    }
    if err then
        report.errorText = err.message .. "\n\n" .. (err.stack or "")
        if err.count and err.count > 1 then
            report.errorText = report.errorText .. "\n(happened " .. err.count .. " times)"
        end
    end
    if description ~= "" then
        report.title = FirstLine(description, 70)
    elseif err then
        report.title = "Lua error: " .. FirstLine(err.message, 60)
    else
        report.title = "Bug report"
    end
    return report
end

local function Encode(text)
    return (tostring(text):gsub("[^%w%-%._~]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

local function MakeLink(report)
    local base = config.issueURL or ""
    local errorLimit, addonLimit = 3000, 1500
    local url
    for _ = 1, 8 do -- shorten the long parts until the link is a safe length
        local parts = {}
        local function Add(key, value)
            if value and value ~= "" then parts[#parts + 1] = key .. "=" .. Encode(value) end
        end
        Add("template", config.template or "bug_report.yml")
        Add("title", "[Bug] " .. report.title)
        Add("addon-version", report.addonVersion)
        Add("game-version", report.gameVersion)
        Add("what-happened", report.description)
        Add("lua-error", report.errorText:sub(1, errorLimit))
        Add("other-addons", report.addons:sub(1, addonLimit))
        Add("environment", report.environment)
        url = base .. "?" .. table.concat(parts, "&")
        if #url <= MAX_URL_LENGTH then break end
        errorLimit = math.floor(errorLimit * 0.7)
        addonLimit = math.floor(addonLimit * 0.7)
    end
    return url
end

-- The same report as text, to paste into the issue if the link doesn't work.
local function MakeText(report)
    local lines = {
        "**Addon:** " .. ADDON_NAME .. " " .. report.addonVersion,
        "**Game:** " .. report.gameVersion,
        "",
        "**What happened:** " .. (report.description ~= "" and report.description or "(not written)"),
        "",
        "**Other addons:** " .. report.addons,
        "",
        report.environment,
    }
    if report.errorText ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "**Lua error:**"
        lines[#lines + 1] = "```"
        lines[#lines + 1] = report.errorText
        lines[#lines + 1] = "```"
    end
    return table.concat(lines, "\n")
end

local function SaveReport(text)
    local list = SavedList("bugReports")
    if not list then return end
    if list[#list] == text then return end
    list[#list + 1] = text
    while #list > MAX_SAVED_REPORTS do table.remove(list, 1) end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------

local window
local WIDTH, INNER = 500, 468

local function AddBorder(frame, r, g, b)
    local function Edge(p1, p2, horizontal)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, 1)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    end
    Edge("TOPLEFT", "TOPRIGHT", true)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    Edge("TOPLEFT", "BOTTOMLEFT", false)
    Edge("TOPRIGHT", "BOTTOMRIGHT", false)
end

local function Label(parent, font, text)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetWidth(INNER)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- A box whose text can be selected and copied but not edited.
local function MakeReadOnly(box, getValue, onCopy)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(getValue())
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnKeyDown", function(_, key)
        if key == "C" and IsControlKeyDown() then onCopy() end
    end)
end

local function BuildWindow()
    local f = CreateFrame("Frame", ADDON_NAME .. "BugReportWindow", UIParent)
    f:SetSize(WIDTH, 480)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, f:GetName()) -- Escape closes it

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.96)
    AddBorder(f, 0.4, 0.4, 0.4)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Report a bug: " .. AddOnTitle())

    -- 1. What happened?
    local askLabel = Label(f, "GameFontNormal", "1. What happened? (optional, you can also write it on GitHub)")
    askLabel:SetPoint("TOPLEFT", 16, -44)

    local descBox = CreateFrame("EditBox", nil, f)
    descBox:SetPoint("TOPLEFT", askLabel, "BOTTOMLEFT", 0, -6)
    descBox:SetSize(INNER, 62)
    descBox:SetMultiLine(true)
    descBox:SetAutoFocus(false)
    descBox:SetMaxLetters(300)
    descBox:SetFontObject(ChatFontNormal)
    descBox:SetTextInsets(6, 6, 6, 6)
    descBox:SetScript("OnEscapePressed", descBox.ClearFocus)
    local descBg = descBox:CreateTexture(nil, "BACKGROUND")
    descBg:SetAllPoints()
    descBg:SetColorTexture(0, 0, 0, 0.6)
    AddBorder(descBox, 0.3, 0.3, 0.3)

    local placeholder = descBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("TOPLEFT", 6, -6)
    placeholder:SetText("Click here to type. Example: names stay white in battlegrounds.")

    local errorLine = Label(f, "GameFontHighlightSmall", "")
    errorLine:SetPoint("TOPLEFT", descBox, "BOTTOMLEFT", 0, -10)

    local includeError = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    includeError:SetSize(24, 24)
    includeError:SetPoint("TOPLEFT", errorLine, "BOTTOMLEFT", -4, -2)
    includeError:SetChecked(true)
    local includeText = includeError:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    includeText:SetPoint("LEFT", includeError, "RIGHT", 2, 1)
    includeText:SetText("Include this error in the report")

    -- 2. The link
    local linkLabel = Label(f, "GameFontNormal",
        "2. Press Ctrl+C to copy this link, then paste it into your web browser. The form fills itself in:")
    linkLabel:SetPoint("TOPLEFT", 16, -196)

    local linkBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    linkBox:SetPoint("TOPLEFT", linkLabel, "BOTTOMLEFT", 6, -6)
    linkBox:SetSize(INNER - 8, 22)
    linkBox:SetAutoFocus(false)
    linkBox:SetMaxLetters(0)
    if linkBox.SetMaxBytes then linkBox:SetMaxBytes(0) end
    linkBox:SetFontObject(ChatFontNormal)

    local status = Label(f, "GameFontHighlightSmall", "")
    status:SetPoint("TOPLEFT", linkBox, "BOTTOMLEFT", -6, -6)

    -- Backup: the same report as text
    local textLabel = Label(f, "GameFontNormalSmall",
        "If the form comes up empty, copy this instead (click, then Ctrl+C) and paste it into the issue:")
    textLabel:SetPoint("TOPLEFT", 16, -282)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", textLabel, "BOTTOMLEFT", 0, -6)
    scroll:SetSize(INNER - 24, 96)
    local scrollBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    scrollBg:SetPoint("TOPLEFT", scroll, -4, 4)
    scrollBg:SetPoint("BOTTOMRIGHT", scroll, 4, -4)
    scrollBg:SetColorTexture(0, 0, 0, 0.6)

    local textBox = CreateFrame("EditBox", nil, scroll)
    textBox:SetMultiLine(true)
    textBox:SetAutoFocus(false)
    textBox:SetMaxLetters(0)
    if textBox.SetMaxBytes then textBox:SetMaxBytes(0) end
    textBox:SetFontObject(GameFontHighlightSmall)
    textBox:SetWidth(INNER - 28)
    scroll:SetScrollChild(textBox)

    local privacy = Label(f, "GameFontDisableSmall",
        "Nothing is sent automatically. You'll see the whole report on GitHub before you submit it.")
    privacy:SetPoint("BOTTOMLEFT", 16, 44)

    local done = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    done:SetSize(100, 22)
    done:SetPoint("BOTTOMRIGHT", -16, 14)
    done:SetText(CLOSE or "Close")
    done:SetScript("OnClick", function() f:Hide() end)

    local selectLink = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectLink:SetSize(120, 22)
    selectLink:SetPoint("RIGHT", done, "LEFT", -8, 0)
    selectLink:SetText("Select link")

    local currentURL, currentText, currentError = "", "", nil

    local function SelectLink()
        linkBox:SetFocus()
        linkBox:SetCursorPosition(0)
        linkBox:HighlightText()
    end

    local function Rebuild()
        local typed = (descBox:GetText() or ""):gsub("||", "|")
        typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
        placeholder:SetShown(descBox:GetText() == "" and not descBox:HasFocus())
        local report = Gather(typed, includeError:GetChecked() and currentError or nil)
        currentURL = MakeLink(report)
        currentText = MakeText(report)
        linkBox:SetText(currentURL)
        linkBox:SetCursorPosition(0)
        textBox:SetText(currentText)
        textBox:SetCursorPosition(0)
        if linkBox:HasFocus() then linkBox:HighlightText() end
    end

    f.Refresh = function()
        currentError = LatestError()
        if currentError then
            errorLine:SetText(("|cffff6060Error found (%s):|r %s"):format(
                currentError.source, FirstLine(currentError.message, 80)))
            includeError:Show()
        else
            errorLine:SetText("|cff80ff80No errors from this addon were recorded.|r")
            includeError:Hide()
        end
        status:SetText("")
        Rebuild()
    end

    descBox:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            Rebuild()
        else
            placeholder:SetShown(descBox:GetText() == "" and not descBox:HasFocus())
        end
    end)
    descBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    descBox:SetScript("OnEditFocusLost", function() placeholder:SetShown(descBox:GetText() == "") end)
    descBox:SetScript("OnTabPressed", SelectLink)

    includeError:SetScript("OnClick", Rebuild)

    MakeReadOnly(linkBox, function() return currentURL end, function()
        SaveReport(currentText)
        status:SetText("|cff80ff80Copied!|r Paste it into your browser's address bar and press Enter.")
    end)
    linkBox:SetScript("OnEnterPressed", linkBox.ClearFocus)

    MakeReadOnly(textBox, function() return currentText end, function()
        SaveReport(currentText)
        status:SetText("|cff80ff80Report text copied!|r Paste it into the issue on GitHub.")
    end)

    selectLink:SetScript("OnClick", SelectLink)
    f:SetScript("OnShow", function()
        f.Refresh()
        SelectLink()
    end)
    f:SetScript("OnHide", function()
        descBox:ClearFocus()
        linkBox:ClearFocus()
        textBox:ClearFocus()
    end)

    return f
end

function BugReport.Open()
    if not window then
        local ok, result = pcall(BuildWindow)
        if not ok then
            -- Last resort: at least tell the player where to report.
            print(("|cffff6060%s:|r couldn't open the bug report window. Please report bugs at %s")
                :format(AddOnTitle(), tostring(config.issueURL)))
            geterrorhandler()(result)
            return
        end
        window = result
    end
    if window:IsShown() then
        window.Refresh()
    else
        window:Show()
    end
end
