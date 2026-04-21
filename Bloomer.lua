local addonName, addonTable = ...

-- Configuración y Constantes
local LIFEBLOOM_ID = 33763
local PANDEMIC_THRESHOLD = 4.5
local SCAN_INTERVAL = 0.1
local SOUND_COOLDOWN = 3

-- Cargar LibSharedMedia
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- Valores por defecto
local DEFAULTS = {
    missingText = "LIFEBLOOM MISSING!",
    refreshText = "REFRESH LIFEBLOOM!",
    fontSize = 24,
    outline = "OUTLINE",
    hasShadow = true,
    posX = 0,
    posY = 150,
    alertType = "SOUND", -- "SOUND", "TTS", "NONE"
    missingSound = "Raid Warning",
    ttsText = "Lifebloom",
    ttsVoice = 0,
    ttsRate = 0,
    ttsVolume = 100
}

-- Variables de estado
local LIFEBLOOM_NAME = C_Spell.GetSpellName(LIFEBLOOM_ID) or "Lifebloom"
local isRestoDruid = false
local lastSoundTime = 0
local forceShow = false
local db
local category

-- Frame principal y Alerta Visual
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

local alertFrame = CreateFrame("Frame", nil, UIParent)
alertFrame:SetSize(600, 100)
alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
alertFrame.text:SetPoint("CENTER")
alertFrame:Hide()

local function ApplySettings()
    if not db then return end
    alertFrame:ClearAllPoints()
    alertFrame:SetPoint("CENTER", UIParent, "CENTER", db.posX, db.posY)
    local fontPath = alertFrame.text:GetFont()
    alertFrame.text:SetFont(fontPath, db.fontSize, (db.outline == "NONE") and "" or db.outline)
    if db.hasShadow then
        alertFrame.text:SetShadowColor(0, 0, 0, 1)
        alertFrame.text:SetShadowOffset(2, -2)
    else
        alertFrame.text:SetShadowColor(0, 0, 0, 0)
    end
end

-------------------------------------------------------------------------------
-- LÓGICA DE ALERTAS (SONIDO / TTS)
-------------------------------------------------------------------------------
local function SpeakTTS()
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
    local text = (db.ttsText and db.ttsText ~= "") and db.ttsText or "Lifebloom"
    local voices = C_VoiceChat.GetTtsVoices() or {}
    local voiceID = db.ttsVoice or (voices[1] and voices[1].voiceID) or 0
    
    -- Pequeño delay para evitar conflictos de audio
    C_Timer.After(0.01, function()
        C_VoiceChat.SpeakText(voiceID, text, db.ttsRate, db.ttsVolume, true)
    end)
end

local function PlayAlert()
    if not db or db.alertType == "NONE" then return end
    local now = GetTime()
    if now - lastSoundTime > SOUND_COOLDOWN then
        if db.alertType == "TTS" then
            SpeakTTS()
        elseif db.alertType == "SOUND" then
            local soundPath = LSM and LSM:Fetch("sound", db.missingSound)
            if soundPath then
                PlaySoundFile(soundPath, "Master")
            else
                PlaySound(8959, "Master")
            end
        end
        lastSoundTime = now
    end
end

local function UpdateSettings()
    local _, class = UnitClass("player")
    local specIndex = GetSpecialization()
    if class == "DRUID" and specIndex then
        local specID = GetSpecializationInfo(specIndex)
        isRestoDruid = (specID == 105)
    else
        isRestoDruid = false
    end
    if not LIFEBLOOM_NAME or LIFEBLOOM_NAME == "" then
        LIFEBLOOM_NAME = C_Spell.GetSpellName(LIFEBLOOM_ID) or "Lifebloom"
    end
end

local function GetLifebloomExpiration(unit)
    local aura = C_UnitAuras.GetAuraDataBySpellName(unit, LIFEBLOOM_NAME, "HELPFUL|PLAYER")
    return aura and aura.expirationTime or nil
end

local function CheckLifebloom()
    if not isRestoDruid or (not InCombatLockdown() and not forceShow) then alertFrame:Hide(); return end
    local foundActive, minRemaining = false, nil
    local unitsToScan = {"player", "target", "focus"}
    for _, unit in ipairs(unitsToScan) do
        if UnitExists(unit) then
            local exp = GetLifebloomExpiration(unit)
            if exp then
                foundActive = true
                local rem = exp - GetTime()
                if not minRemaining or rem < minRemaining then minRemaining = rem end
            end
        end
    end
    if not foundActive then
        local numGroup = GetNumGroupMembers()
        if numGroup > 0 then
            local prefix = IsInRaid() and "raid" or "party"
            local maxIdx = IsInRaid() and numGroup or (numGroup - 1)
            for i = 1, maxIdx do
                local unit = prefix .. i
                if UnitExists(unit) then
                    local exp = GetLifebloomExpiration(unit)
                    if exp then
                        foundActive = true; local rem = exp - GetTime()
                        if not minRemaining or rem < minRemaining then minRemaining = rem end
                    end
                end
            end
        end
    end

    if not foundActive then
        alertFrame.text:SetText(db.missingText); alertFrame.text:SetTextColor(1, 0, 0); alertFrame:Show()
        if InCombatLockdown() then PlayAlert() end
    elseif minRemaining and minRemaining <= PANDEMIC_THRESHOLD then
        alertFrame.text:SetText(db.refreshText); alertFrame.text:SetTextColor(1.0, 1.0, 0.6); alertFrame:Show()
    else
        alertFrame:Hide()
    end
end

-------------------------------------------------------------------------------
-- MENÚ DESPLEGABLE CON SCROLL (GENÉRICO)
-------------------------------------------------------------------------------
local scrollMenu
local function GetOrCreateScrollMenu()
    if scrollMenu then return scrollMenu end
    local f = CreateFrame("Frame", "BloomerScrollMenu", UIParent, "BackdropTemplate")
    f:SetSize(250, 300); f:SetFrameStrata("TOOLTIP")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    local sf = CreateFrame("ScrollFrame", "BloomerScrollFrame", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 8, -8); sf:SetPoint("BOTTOMRIGHT", -28, 8)
    local content = CreateFrame("Frame", nil, sf); content:SetSize(210, 10); sf:SetScrollChild(content)
    f.content = content; f.buttons = {}
    local blocker = CreateFrame("Frame", nil, UIParent)
    blocker:SetAllPoints(); blocker:SetFrameStrata("DIALOG"); blocker:Hide()
    blocker:EnableMouse(true); blocker:SetScript("OnMouseDown", function() f:Hide(); blocker:Hide() end)
    f.blocker = blocker; scrollMenu = f
    return f
end

local function ShowGenericMenu(anchor, items, onClick)
    local menu = GetOrCreateScrollMenu()
    local btnH = 20
    menu.content:SetSize(210, #items * btnH)
    for i, item in ipairs(items) do
        local btn = menu.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, menu.content)
            btn:SetSize(210, btnH); btn:SetNormalFontObject("GameFontNormalSmall")
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            menu.buttons[i] = btn
        end
        btn:SetText(item.label); btn:Show(); btn:SetPoint("TOPLEFT", 0, -(i-1)*btnH)
        btn:SetScript("OnClick", function() onClick(item.value, item.label); menu:Hide(); menu.blocker:Hide() end)
    end
    for i = #items + 1, #menu.buttons do menu.buttons[i]:Hide() end
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2); menu:Show(); menu.blocker:Show()
end

-------------------------------------------------------------------------------
-- MENÚ DE OPCIONES
-------------------------------------------------------------------------------
local function CreateOptionsPanel()
    if not db then return end
    local panel = CreateFrame("Frame", "BloomerOptionsPanel", UIParent); panel.name = "Bloomer"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("Bloomer Options")

    -- 1. Alerta Tipo (SOUND / TTS / NONE)
    local typeLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    typeLbl:SetPoint("TOPLEFT", 16, -50); typeLbl:SetText("Alert Type:")
    
    local types = { {label="Sound", value="SOUND"}, {label="TTS (Voice)", value="TTS"}, {label="None (Visual Only)", value="NONE"} }
    local typeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    typeBtn:SetSize(180, 25); typeBtn:SetPoint("TOPLEFT", 16, -70)
    local currentLabel = "Sound"
    for _, t in ipairs(types) do if t.value == db.alertType then currentLabel = t.label end end
    typeBtn:SetText(currentLabel .. " ▼")
    typeBtn:SetScript("OnClick", function(self)
        ShowGenericMenu(self, types, function(val, lbl) db.alertType = val; self:SetText(lbl .. " ▼") end)
    end)

    -- 2. Configuración de Sonido
    local soundBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    soundBtn:SetSize(250, 25); soundBtn:SetPoint("TOPLEFT", 16, -120); soundBtn:SetText(db.missingSound .. " ▼")
    soundBtn:SetScript("OnClick", function(self)
        local sounds = LSM:List("sound"); local items = {}
        for _, s in ipairs(sounds) do table.insert(items, {label=s, value=s}) end
        ShowGenericMenu(self, items, function(val, lbl)
            db.missingSound = val; self:SetText(val .. " ▼")
            local path = LSM:Fetch("sound", val); if path then PlaySoundFile(path, "Master") end
        end)
    end)
    local sLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sLbl:SetPoint("BOTTOMLEFT", soundBtn, "TOPLEFT", 0, 2); sLbl:SetText("Sound Selection (for Sound mode):")

    -- 3. Configuración de TTS
    local ttsEB = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    ttsEB:SetSize(200, 30); ttsEB:SetPoint("TOPLEFT", 16, -170); ttsEB:SetAutoFocus(false); ttsEB:SetText(db.ttsText)
    ttsEB:SetScript("OnEnterPressed", function(self) db.ttsText = self:GetText(); self:ClearFocus() end)
    local ttsLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ttsLbl:SetPoint("BOTTOMLEFT", ttsEB, "TOPLEFT", 0, 2); ttsLbl:SetText("TTS Text:")

    local voiceBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    voiceBtn:SetSize(200, 25); voiceBtn:SetPoint("LEFT", ttsEB, "RIGHT", 10, 0); voiceBtn:SetText("Select Voice ▼")
    voiceBtn:SetScript("OnClick", function(self)
        local voices = C_VoiceChat.GetTtsVoices(); local items = {}
        for _, v in ipairs(voices) do table.insert(items, {label=v.name, value=v.voiceID}) end
        ShowGenericMenu(self, items, function(val, lbl) db.ttsVoice = val; SpeakTTS() end)
    end)

    -- Sliders (TTS y Visual)
    local function CreateMySlider(label, min, max, val, x, y, key)
        local s = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", x, y); s:SetMinMaxValues(min, max); s:SetValueStep(1); s:SetValue(val); s:SetWidth(200)
        s.Text:SetText(label .. ": " .. val)
        s:SetScript("OnValueChanged", function(self, value)
            local v = math.floor(value); db[key] = v; self.Text:SetText(label .. ": " .. v); ApplySettings()
        end)
    end
    CreateMySlider("TTS Vol", 0, 100, db.ttsVolume, 16, -220, "ttsVolume")
    CreateMySlider("TTS Speed", -10, 10, db.ttsRate, 230, -220, "ttsRate")
    CreateMySlider("Font Size", 10, 72, db.fontSize, 16, -270, "fontSize")
    CreateMySlider("PosX", -600, 600, db.posX, 16, -320, "posX")
    CreateMySlider("PosY", -600, 600, db.posY, 230, -320, "posY")

    -- 4. Textos de Alerta
    local function CreateSmallEB(label, val, x, y, key)
        local eb = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        eb:SetSize(200, 30); eb:SetPoint("TOPLEFT", x, y); eb:SetAutoFocus(false); eb:SetText(val)
        eb:SetScript("OnEnterPressed", function(self) db[key] = self:GetText(); self:ClearFocus() end)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("BOTTOMLEFT", eb, "TOPLEFT", 0, 2); lbl:SetText(label)
    end
    CreateSmallEB("Text (Missing):", db.missingText, 16, -370, "missingText")
    CreateSmallEB("Text (Refresh):", db.refreshText, 230, -370, "refreshText")

    -- Botones finales
    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(150, 25); testBtn:SetPoint("TOPLEFT", 16, -420); testBtn:SetText("Test Alert"); testBtn:SetScript("OnClick", function() PlayAlert() end)
    
    local testModeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testModeBtn:SetSize(150, 25); testModeBtn:SetPoint("LEFT", testBtn, "RIGHT", 10, 0); testModeBtn:SetText("Toggle Test Mode")
    testModeBtn:SetScript("OnClick", function() forceShow = not forceShow; print("|cFF00FF00Bloomer:|r Test mode " .. (forceShow and "ON" or "OFF")) end)

    category = Settings.RegisterCanvasLayoutCategory(panel, "Bloomer")
    Settings.RegisterAddOnCategory(category)
end

frame:SetScript("OnUpdate", function(self, elapsed)
    self.timer = (self.timer or 0) + elapsed
    if self.timer >= SCAN_INTERVAL then CheckLifebloom(); self.timer = 0 end
end)

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Bloomer" then
        if not BloomerDB then BloomerDB = {} end
        for k, v in pairs(DEFAULTS) do if BloomerDB[k] == nil then BloomerDB[k] = v end end
        db = BloomerDB
        if not category then CreateOptionsPanel() end
    elseif event == "PLAYER_LOGIN" then UpdateSettings(); ApplySettings()
    else UpdateSettings() end
end)

SLASH_BLOOMER1 = "/bloomer"
SlashCmdList["BLOOMER"] = function() if category then Settings.OpenToCategory(category:GetID()) end end
