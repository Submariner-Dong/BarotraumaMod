--[[
    LOTM Pathways - logic layer v0.3
    Requires LuaCsForBarotrauma. Declared in ModConfig.xml (Lua/Autorun is not
    scanned by LuaCs 1.0.117, so the explicit declaration is required).

    Rules:
      * ASCII only, all player-facing text comes from Texts via TextManager
      * every external API call is wrapped in pcall
      * logic runs on whichever side executes the script; GUI only on client
]]

print("[LOTM] boot: SERVER=" .. tostring(SERVER) .. " CLIENT=" .. tostring(CLIENT))

if LOTM_LOADED then
    print("[LOTM] already loaded, skipping")
    return
end
LOTM_LOADED = true

-- ============================================================
-- localization helpers
-- ============================================================
local function L(key)
    local s = nil
    pcall(function() s = TextManager.Get(key) end)
    if s == nil then return key end
    local str = tostring(s)
    if str == nil or str == "" then return key end
    return str
end

-- ASCII fallbacks in case a text key fails to load
local DEFAULTS = {
    ["lotm.cmd.help"]    = "!lotm",
    ["lotm.cmd.status"]  = "!status",
    ["lotm.cmd.vision"]  = "!vision",
    ["lotm.cmd.hud"]     = "!hud",
    ["lotm.cmd.divine"]  = "!divine",
    ["lotm.kw.monster"]  = "monster,alive,danger,enemy",
    ["lotm.kw.crew"]     = "crew,hurt,team",
}

-- comma separated keyword list from Texts
local function matchAny(q, key)
    local raw = L(key)
    if raw == key and DEFAULTS[key] ~= nil then raw = DEFAULTS[key] end
    for word in string.gmatch(raw, "[^,]+") do
        word = string.lower(word)
        if word ~= "" and string.find(q, word, 1, true) then return true end
    end
    return false
end

-- pipe separated command aliases from Texts
local function aliases(key)
    local raw = L(key)
    if raw == key and DEFAULTS[key] ~= nil then raw = DEFAULTS[key] end
    local list = {}
    for a in string.gmatch(raw, "[^|]+") do
        if a ~= "" then list[#list + 1] = a end
    end
    return list
end

-- ============================================================
-- data
-- ============================================================
local SEQ = {
    [9] = { buff = "lotm_seq9", digest = "lotm_digest9", char = "lotm_char_diviner",  nameKey = "afflictionname.lotm_seq9" },
    [8] = { buff = "lotm_seq8", digest = "lotm_digest8", char = "lotm_char_clown",    nameKey = "afflictionname.lotm_seq8" },
    [7] = { buff = "lotm_seq7", digest = "lotm_digest7", char = "lotm_char_magician", nameKey = "afflictionname.lotm_seq7" },
}
local SEQ_ORDER = { 9, 8, 7 }

local MADNESS = "lotm_madness"
local SPIRIT  = "lotm_spirituality"
local VISION  = "lotm_spiritvision"
local SICK    = "lotm_visionsick"
local CRYSTAL = "lotm_divination_crystal"

local VISION_DRAIN  = 1.5
local DIVINE_COST   = 30
local DIVINE_DIGEST = 8

local COLOR_NORMAL = Color(200, 210, 255, 255)
local COLOR_WARN   = Color(255, 190, 120, 255)
local COLOR_BAD    = Color(255, 90, 90, 255)

local crystalPrefab = nil
pcall(function() crystalPrefab = ItemPrefab.GetItemPrefab(CRYSTAL) end)

-- ============================================================
-- messaging
-- ============================================================
local function send(msgText, color, client)
    local ok = pcall(function()
        local msg = ChatMessage.Create("", msgText, ChatMessageType.Default, nil, nil)
        if color then msg.Color = color end
        if Game.ChatBox ~= nil then
            Game.ChatBox.AddMessage(msg)
        elseif client ~= nil then
            Game.SendDirectChatMessage(msg, client)
        end
    end)
    if not ok then print("[LOTM] " .. tostring(msgText)) end
end

local function tell(key, color)
    send(L(key), color, nil)
end

local function reply(key, color, client)
    send(L(key), color, client)
end

-- ============================================================
-- affliction helpers
-- ============================================================
local function getChar()
    local ch
    pcall(function() ch = Character.Controlled end)
    if ch == nil then return nil end
    local dead = false
    pcall(function() dead = ch.IsDead end)
    if dead then return nil end
    return ch
end

local function findAff(ch, id)
    local a = nil
    pcall(function() a = ch.CharacterHealth.GetAffliction(id, true) end)
    return a
end

local function applyAmount(ch, id, value)
    local prefab = nil
    pcall(function() prefab = AfflictionPrefab.Prefabs[id] end)
    if prefab == nil then
        print("[LOTM] missing affliction prefab: " .. tostring(id))
        return
    end
    pcall(function()
        local limb = ch.AnimController.GetLimb(LimbType.Head)
        ch.CharacterHealth.ApplyAffliction(limb, prefab.Instantiate(value))
    end)
end

local function amount(ch, id)
    local a = findAff(ch, id)
    if a == nil then return 0 end
    local s = 0
    pcall(function() s = a.Strength end)
    return s or 0
end

local function setAmount(ch, id, value)
    local a = findAff(ch, id)
    if a == nil then
        if value > 0 then applyAmount(ch, id, value) end
        return
    end
    pcall(function() a.Strength = value end)
end

local function currentSeq(ch)
    for _, s in ipairs(SEQ_ORDER) do
        if amount(ch, SEQ[s].buff) > 0 then return s end
    end
    return nil
end

local function hasCrystal(ch)
    if crystalPrefab == nil then return false end
    local found = false
    pcall(function()
        for item in ch.Inventory.AllItems do
            if item ~= nil and item.Prefab == crystalPrefab then
                found = true
                break
            end
        end
    end)
    return found
end

-- ============================================================
-- loss of control
-- ============================================================
local function loseControl(ch)
    print("[LOTM] lose control triggered for " .. tostring(ch.Name))
    tell("lotm.msg.losecontrol", COLOR_BAD)
    applyAmount(ch, "internaldamage", 3000)
    pcall(function()
        Entity.Spawner.AddCharacterToSpawnQueue("crawler", ch.WorldPosition, nil)
    end)
end

local lostControl = {}

local function checkLoseControl(ch)
    if ch == nil then return end
    if lostControl[ch.ID] then return end
    if amount(ch, MADNESS) >= 100 then
        lostControl[ch.ID] = true
        loseControl(ch)
    end
end

-- ============================================================
-- potion hook
-- ============================================================
Hook.Add("lotm.potion", "lotm.potion", function(effect, deltaTime, item, targets, worldPosition, element)
    local seq = 9
    pcall(function()
        local v = element.GetAttributeString("custom", "9")
        if v ~= nil then seq = tonumber(v) or 9 end
    end)

    local ch = nil
    if targets ~= nil then ch = targets[1] end
    if ch == nil then return end

    print("[LOTM] potion hook seq=" .. tostring(seq))

    local cur = currentSeq(ch)

    if cur ~= nil and seq == cur then
        applyAmount(ch, MADNESS, 20)
        tell("lotm.msg.potion_same", COLOR_WARN)
        checkLoseControl(ch)
        return true
    end

    local digest = 0
    if cur ~= nil then digest = amount(ch, SEQ[cur].digest) end

    local risk
    if cur == nil then
        risk = 0
    elseif seq == cur - 1 then
        risk = 100 - digest
    else
        risk = 120
    end

    local gain = 6 + risk * 0.6
    applyAmount(ch, MADNESS, gain)

    if risk <= 0 then
        tell("lotm.msg.potion_ok", COLOR_NORMAL)
    elseif risk < 60 then
        tell("lotm.msg.potion_pain", COLOR_WARN)
    else
        tell("lotm.msg.potion_reckless", COLOR_BAD)
    end

    if amount(ch, MADNESS) >= 100 then
        checkLoseControl(ch)
    end
end)

-- ============================================================
-- divination
-- ============================================================
local function countMonstersNear(ch, radius)
    local count = 0
    pcall(function()
        for other in Character.CharacterList do
            if other ~= nil and not other.IsHuman and not other.IsDead then
                local d = 0
                pcall(function() d = Vector2.Distance(other.WorldPosition, ch.WorldPosition) end)
                if d > 0 and d < radius then count = count + 1 end
            end
        end
    end)
    return count
end

local function countHurtCrew()
    local count = 0
    pcall(function()
        for other in Character.CharacterList do
            if other ~= nil and other.IsHuman and not other.IsDead then
                local pct = 100
                pcall(function() pct = other.HealthPercentage * 100 end)
                if pct < 40 then count = count + 1 end
            end
        end
    end)
    return count
end

local function divine(question, client)
    local ch = getChar()
    if ch == nil then return end

    local cur = currentSeq(ch)
    if cur == nil then
        reply("lotm.msg.no_pathway", COLOR_WARN, client)
        return
    end
    if not hasCrystal(ch) then
        reply("lotm.msg.no_crystal", COLOR_WARN, client)
        return
    end

    local sp = amount(ch, SPIRIT)
    if sp < DIVINE_COST then
        applyAmount(ch, MADNESS, 5)
        reply("lotm.msg.no_spirit_divine", COLOR_BAD, client)
        return
    end

    setAmount(ch, SPIRIT, sp - DIVINE_COST)
    applyAmount(ch, SEQ[cur].digest, DIVINE_DIGEST)

    local acc = 0.4 + amount(ch, SEQ[cur].digest) * 0.006
    local q = string.lower(tostring(question or ""))

    local truth
    if matchAny(q, "lotm.kw.monster") then
        truth = countMonstersNear(ch, 4000) > 0
    elseif matchAny(q, "lotm.kw.crew") then
        truth = countHurtCrew() > 0
    else
        truth = math.random() < 0.5
    end

    local wrong = math.random() > acc
    if wrong then truth = not truth end

    local qtext = tostring(question or "")
    local prefix
    if qtext ~= "" then
        local askFmt = L("lotm.msg.divine_ask")
        if type(askFmt) ~= "string" or not string.find(askFmt, "%%s") then askFmt = "%s: " end
        prefix = string.format(askFmt, qtext)
    else
        prefix = L("lotm.msg.divine_prefix")
    end

    local answer = prefix
    if truth then
        answer = answer .. L("lotm.msg.divine_yes")
    else
        answer = answer .. L("lotm.msg.divine_no")
    end
    if wrong then answer = answer .. L("lotm.msg.divine_wrong") end
    if amount(ch, SEQ[cur].digest) < 30 then answer = answer .. L("lotm.msg.divine_lowdigest") end

    send(answer, COLOR_NORMAL, client)
end

-- ============================================================
-- spirit vision
-- ============================================================
local visionOn = {}

local function toggleVision(client)
    local ch = getChar()
    if ch == nil then return end

    if currentSeq(ch) == nil then
        reply("lotm.msg.no_pathway", COLOR_WARN, client)
        return
    end

    if visionOn[ch.ID] then
        visionOn[ch.ID] = nil
        setAmount(ch, VISION, 0)
        reply("lotm.msg.vision_off", COLOR_NORMAL, client)
        return
    end

    if amount(ch, SPIRIT) < 20 then
        reply("lotm.msg.vision_low_spirit", COLOR_WARN, client)
        return
    end

    visionOn[ch.ID] = true
    applyAmount(ch, VISION, 100)
    reply("lotm.msg.vision_on", COLOR_NORMAL, client)
end

-- ============================================================
-- per second logic
-- ============================================================
local tracked = {}
local lastLogic = 0

local function deathDrop()
    for other in Character.CharacterList do
        if other ~= nil and other.IsHuman then
            local s = currentSeq(other)
            if s ~= nil then tracked[other.ID] = s end
            if other.IsDead and tracked[other.ID] ~= nil then
                local seq = tracked[other.ID]
                tracked[other.ID] = nil
                local prefab = ItemPrefab.GetItemPrefab(SEQ[seq].char)
                if prefab ~= nil then
                    print("[LOTM] dropping characteristic seq=" .. tostring(seq))
                    Entity.Spawner.AddItemToSpawnQueue(prefab, other.WorldPosition, nil, nil, nil)
                end
            end
        end
    end
end

local function logicTick()
    local ch = Character.Controlled
    if ch ~= nil and not ch.IsDead then
        if visionOn[ch.ID] then
            local sp = amount(ch, SPIRIT)
            if sp <= VISION_DRAIN then
                visionOn[ch.ID] = nil
                setAmount(ch, VISION, 0)
                applyAmount(ch, SICK, 100)
                tell("lotm.msg.vision_collapse", COLOR_BAD)
            else
                setAmount(ch, SPIRIT, sp - VISION_DRAIN)
            end
        end
        checkLoseControl(ch)
    end
    pcall(deathDrop)
end

-- ============================================================
-- HUD (experimental, client only)
-- ============================================================
local hudReady = false
local hudText = {}
local hudRoot = nil

local function bar(value, maxValue, cells)
    cells = cells or 10
    local filled = math.floor((value / maxValue) * cells + 0.5)
    if filled < 0 then filled = 0 end
    if filled > cells then filled = cells end
    return "[" .. string.rep("#", filled) .. string.rep("-", cells - filled) .. "]"
end

local function buildHUD()
    if not CLIENT then return end
    local ok = pcall(function()
        hudRoot = GUI.Frame(GUI.RectTransform(Vector2(1, 1)), nil)
        hudRoot.CanBeFocused = false

        local panel = GUI.Frame(GUI.RectTransform(Point(400, 250), hudRoot.RectTransform, GUI.Anchor.Center), "GUITextBox")
        panel.RectTransform.AbsoluteOffset = Point(0, 250)
        panel.CanBeFocused = false

        hudText.body = GUI.TextBlock(GUI.RectTransform(Vector2(0.94, 0.62), panel.RectTransform, GUI.Anchor.TopCenter), "", nil, nil, GUI.Alignment.Left)
        hudText.body.TextColor = Color(220, 230, 255, 255)

        local btnVision = GUI.Button(GUI.RectTransform(Vector2(0.44, 0.18), panel.RectTransform, GUI.Anchor.BottomLeft), L("lotm.hud.vision"), GUI.Alignment.Center, "GUIButtonSmall")
        btnVision.OnClicked = function() toggleVision(nil) end

        local btnDivine = GUI.Button(GUI.RectTransform(Vector2(0.44, 0.18), panel.RectTransform, GUI.Anchor.BottomRight), L("lotm.hud.divine"), GUI.Alignment.Center, "GUIButtonSmall")
        btnDivine.OnClicked = function() divine(L("lotm.msg.divine_default"), nil) end

        hudReady = true
        print("[LOTM] HUD created")
        pcall(function()
            local r = panel.RectTransform.Rect
            print(string.format("[LOTM] panel rect %d,%d %dx%d", r.X, r.Y, r.Width, r.Height))
        end)
        pcall(function()
            local r = btnVision.RectTransform.Rect
            print(string.format("[LOTM] btn vision rect %d,%d %dx%d", r.X, r.Y, r.Width, r.Height))
        end)
        pcall(function()
            local r = btnDivine.RectTransform.Rect
            print(string.format("[LOTM] btn divine rect %d,%d %dx%d", r.X, r.Y, r.Width, r.Height))
        end)
    end)
    if not ok then
        print("[LOTM] HUD creation failed, fallback to chat commands")
    end
end

local function updateHUD()
    if not hudReady then return end
    local ch = Character.Controlled
    if ch == nil then return end

    local hp, maxhp = 0, 100
    pcall(function() hp = ch.Health; maxhp = ch.MaxHealth end)

    local seq = currentSeq(ch)
    local sp = amount(ch, SPIRIT)
    local mad = amount(ch, MADNESS)
    local dig = 0
    if seq ~= nil then dig = amount(ch, SEQ[seq].digest) end

    pcall(function()
        local title = seq and L(SEQ[seq].nameKey) or L("lotm.hud.novice")
        local lines = {}
        lines[1] = L("lotm.hud.title") .. " - " .. title
        lines[2] = L("lotm.hud.hp")  .. " " .. bar(hp, maxhp) .. " " .. math.floor(hp + 0.5) .. "/" .. math.floor(maxhp + 0.5)
        lines[3] = L("lotm.hud.sp")  .. " " .. bar(sp, 100) .. " " .. math.floor(sp + 0.5)
        lines[4] = L("lotm.hud.mad") .. " " .. bar(mad, 100) .. " " .. math.floor(mad + 0.5)
        lines[5] = L("lotm.hud.dig") .. " " .. (seq and (bar(dig, 100) .. " " .. math.floor(dig + 0.5)) or L("lotm.hud.none"))
        hudText.body.Text = table.concat(lines, "\n")
    end)
end

local function onFrame()
    local now = 0
    pcall(function() now = os.clock() end)
    if now - lastLogic >= 1.0 then
        lastLogic = now
        pcall(logicTick)
    end
    pcall(updateHUD)
end

-- ============================================================
-- chat commands
-- ============================================================
Hook.Add("chatMessage", "lotm.chat", function(message, client)
    if message == nil then return end

    for _, a in ipairs(aliases("lotm.cmd.help")) do
        if message == a then
            send("[LOTM] online SERVER=" .. tostring(SERVER) .. " CLIENT=" .. tostring(CLIENT), COLOR_NORMAL, client)
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.status")) do
        if message == a then
            local ch = Character.Controlled
            if ch == nil then return true end
            local seq = currentSeq(ch)
            local hp, maxhp = 0, 0
            pcall(function() hp = ch.Health; maxhp = ch.MaxHealth end)
            local text = L("lotm.msg.status_prefix")
                .. " " .. math.floor(hp) .. "/" .. math.floor(maxhp)
                .. " | " .. L("lotm.hud.sp") .. " " .. math.floor(amount(ch, SPIRIT))
                .. " | " .. L("lotm.hud.mad") .. " " .. math.floor(amount(ch, MADNESS))
                .. " | " .. L("lotm.hud.dig") .. " " .. (seq and math.floor(amount(ch, SEQ[seq].digest)) or 0)
                .. " | " .. (seq and L(SEQ[seq].nameKey) or L("lotm.msg.seq_none"))
            send(text, COLOR_NORMAL, client)
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.vision")) do
        if message == a then
            toggleVision(client)
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.hud")) do
        if message == a then
            if hudRoot ~= nil then
                pcall(function() hudRoot.Visible = not hudRoot.Visible end)
                send("[LOTM] hud toggled", COLOR_NORMAL, client)
            else
                send("[LOTM] hud not available", COLOR_WARN, client)
            end
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.divine")) do
        if string.sub(message, 1, #a) == a then
            divine(string.sub(message, #a + 1), client)
            return true
        end
    end
end)

-- ============================================================
-- mount
-- ============================================================
buildHUD()

pcall(function()
    Hook.Patch("Barotrauma.GameScreen", "AddToGUIUpdateList", function()
        if hudRoot ~= nil then
            pcall(function() hudRoot.AddToGUIUpdateList() end)
        end
        onFrame()
    end)
    print("[LOTM] GameScreen patch applied")
end)

print("[LOTM] init done")
