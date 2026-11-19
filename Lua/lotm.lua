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
    ["lotm.cmd.debug"]   = "!debug",
    ["lotm.cmd.pos"]     = "!pos",
    ["lotm.cmd.jump"]      = "!jump",
    ["lotm.cmd.illusion"]  = "!illusion",
    ["lotm.cmd.shift"]     = "!shift",
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
local LIMB_TYPES = {}
pcall(function()
    LIMB_TYPES = { LimbType.Head, LimbType.Torso, LimbType.LeftArm, LimbType.RightArm, LimbType.LeftLeg, LimbType.RightLeg }
end)

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
    -- sum every affliction instance (they may be split across limbs)
    local total = 0
    local got = false
    pcall(function()
        for aff in ch.CharacterHealth.GetAllAfflictions() do
            if aff ~= nil and tostring(aff.Identifier) == id then
                total = total + (aff.Strength or 0)
                got = true
            end
        end
    end)
    if got then return total end

    local v = nil
    pcall(function() v = ch.CharacterHealth.GetAfflictionStrengthByIdentifier(id, true) end)
    if v ~= nil and v > 0 then return v end

    local a = findAff(ch, id)
    if a == nil then return 0 end
    local s = 0
    pcall(function() s = a.Strength end)
    return s or 0
end

local function setAmount(ch, id, value)
    local a = findAff(ch, id)
    if a == nil then
        if value <= 0 then return end
        applyAmount(ch, id, 1)   -- create it, then overwrite the value
        a = findAff(ch, id)
        if a == nil then return end
    end
    -- direct assignment bypasses the engine's 100/MaxVitality normalisation
    pcall(function() a.Strength = value end)
end

local function addAmount(ch, id, delta)
    if delta == nil or delta == 0 then return end
    local cur = amount(ch, id)
    local target = cur + delta
    if target < 0 then target = 0 end
    setAmount(ch, id, target)
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
        for item in ch.Inventory.AllItemsMod do
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
        addAmount(ch, MADNESS, 40)
        tell("lotm.msg.potion_same", COLOR_WARN)
        checkLoseControl(ch)
        return true
    end

    -- a mortal drinking anything above sequence 9 goes mad almost instantly
    if cur == nil and seq < 9 then
        local rolled = math.random()
        print("[LOTM] mortal drank seq=" .. tostring(seq) .. " roll=" .. string.format("%.3f", rolled))
        if rolled < 0.99 then
            addAmount(ch, MADNESS, 100)
            tell("lotm.msg.potion_skip", COLOR_BAD)
            checkLoseControl(ch)
        else
            addAmount(ch, MADNESS, 85)
            tell("lotm.msg.potion_skip_survive", COLOR_WARN)
        end
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
        risk = 140
    end

    local gain
    if cur == nil then
        gain = 15          -- first potion: no digestion exists yet, fixed cost
    else
        gain = 6 + risk * 0.6
    end
    addAmount(ch, MADNESS, gain)

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
-- sequence application (direct assignment, no vitality scaling)
-- ============================================================
Hook.Add("lotm.seq", "lotm.seq", function(effect, deltaTime, item, targets, worldPosition, element)
    local seq = 9
    pcall(function()
        local v = element.GetAttributeString("custom", "9")
        if v ~= nil then seq = tonumber(v) or 9 end
    end)
    local ch = nil
    if targets ~= nil then ch = targets[1] end
    if ch == nil then return end
    setAmount(ch, SEQ[seq].buff, 100)
    setAmount(ch, SPIRIT, 100)
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
        addAmount(ch, MADNESS, 5)
        reply("lotm.msg.no_spirit_divine", COLOR_BAD, client)
        return
    end

    setAmount(ch, SPIRIT, sp - DIVINE_COST)
    addAmount(ch, SEQ[cur].digest, DIVINE_DIGEST)

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
    setAmount(ch, VISION, 100)
    reply("lotm.msg.vision_on", COLOR_NORMAL, client)
end

-- ============================================================
-- v0.4 skills: paper figure, damage transfer, flame jump, illusion
-- ============================================================
local PAPER = "lotm_paper_figure"
local ILLUSION = "lotm_illusion"

local Keys = nil
pcall(function() Keys = LuaUserData.CreateStatic("Microsoft.Xna.Framework.Input.Keys", true) end)

local cooldowns = {}
local illusionUntil = {}

local function nowSeconds()
    local t = 0
    pcall(function() t = os.clock() end)
    return t
end

local function cdReady(ch, skill, seconds)
    local key = tostring(ch.ID) .. ":" .. skill
    local t = nowSeconds()
    if t - (cooldowns[key] or -99999) >= seconds then
        cooldowns[key] = t
        return true
    end
    return false
end

local function itemById(id)
    local p = nil
    pcall(function() p = ItemPrefab.GetItemPrefab(id) end)
    return p
end

local function countItem(ch, id)
    local prefab = itemById(id)
    if prefab == nil then return 0 end
    local n = 0
    pcall(function()
        for item in ch.Inventory.AllItemsMod do
            if item ~= nil and item.Prefab == prefab then n = n + 1 end
        end
    end)
    return n
end

local function consumeItem(ch, id)
    local prefab = itemById(id)
    if prefab == nil then return false end
    local target = nil
    pcall(function()
        for item in ch.Inventory.AllItemsMod do
            if item ~= nil and item.Prefab == prefab then target = item; break end
        end
    end)
    if target == nil then return false end
    pcall(function()
        if target.Inventory ~= nil then target.Inventory.RemoveItem(target) end
    end)
    pcall(function() target.Remove() end)
    return true
end

local function setVitality(ch, v)
    pcall(function() ch.CharacterHealth.SetVitality(v) end)
end

-- paper figure blocks a lethal hit (seq 8+), damage transfer splits a heavy hit (seq 7)
Hook.Add("character.applyDamage", "lotm.damage", function(characterHealth, attackResult, hitLimb, allowStacking)
    local ch = nil
    pcall(function() ch = characterHealth.Character end)
    if ch == nil or attackResult == nil then return end
    local human = false
    pcall(function() human = ch.IsHuman end)
    if not human then return end

    local seq = currentSeq(ch)
    if seq == nil then return end

    local dmg = 0
    pcall(function() dmg = attackResult.Damage end)
    if dmg == nil or dmg <= 0 then return end

    local hp, maxhp = 100, 100
    pcall(function() hp = ch.Health; maxhp = ch.MaxHealth end)
    if maxhp == nil or maxhp <= 0 then maxhp = 100 end

    if dmg >= hp and seq <= 8 then
        if countItem(ch, PAPER) > 0 and cdReady(ch, "paper", 90) then
            consumeItem(ch, PAPER)
            pcall(function() attackResult.Damage = 0 end)
            setVitality(ch, maxhp * 0.15)
            applyAmount(ch, "bleeding", 25)
            applyAmount(ch, "internaldamage", 25)
            addAmount(ch, MADNESS, 25)
            addAmount(ch, SEQ[seq].digest, 10)
            tell("lotm.msg.paper_save", COLOR_BAD)
            return
        end
    end


end)

-- flame jump: short blink toward the cursor, no wall phasing (best effort)
local function flameJump(client)
    local ch = getChar()
    if ch == nil then return end
    local seq = currentSeq(ch)
    if seq == nil or seq > 7 then reply("lotm.msg.need_seq7", COLOR_WARN, client) return end
    if amount(ch, SPIRIT) < 35 then reply("lotm.msg.low_spirit", COLOR_WARN, client) return end
    if not cdReady(ch, "jump", 20) then reply("lotm.msg.cooldown", COLOR_WARN, client) return end

    local from, to = nil, nil
    pcall(function() from = ch.WorldPosition; to = ch.CursorWorldPosition end)
    if from == nil or to == nil then return end

    local dx, dy = to.X - from.X, to.Y - from.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end

    local dist = 300
    if len < dist then dist = len end
    local dest = Vector2(from.X + dx / len * dist, from.Y + dy / len * dist)

    setAmount(ch, SPIRIT, amount(ch, SPIRIT) - 35)
    addAmount(ch, SEQ[seq].digest, 12)
    pcall(function() ch.TeleportTo(dest) end)
    reply("lotm.msg.jump_on", COLOR_NORMAL, client)
end

-- illusion: monsters ignore you for 8 seconds
local function castIllusion(client)
    local ch = getChar()
    if ch == nil then return end
    local seq = currentSeq(ch)
    if seq == nil or seq > 7 then reply("lotm.msg.need_seq7", COLOR_WARN, client) return end
    if amount(ch, SPIRIT) < 25 then reply("lotm.msg.low_spirit", COLOR_WARN, client) return end
    if not cdReady(ch, "illusion", 45) then reply("lotm.msg.cooldown", COLOR_WARN, client) return end

    setAmount(ch, SPIRIT, amount(ch, SPIRIT) - 25)
    setAmount(ch, ILLUSION, 100)
    addAmount(ch, SEQ[seq].digest, 8)
    illusionUntil[ch.ID] = nowSeconds() + 8
    reply("lotm.msg.illusion_on", COLOR_NORMAL, client)
end

-- key bindings come from LuaCs config (Config/ConfigClient.xml, Type="control"),
-- so players can rebind them in the LuaCs mod settings menu.
local SettingControl = nil
pcall(function() SettingControl = LuaUserData.CreateStatic("Barotrauma.LuaCs.Data.ISettingControl") end)

local function findOwnPackage()
    local found = nil
    pcall(function()
        for pkg in ContentPackageManager.AllPackages do
            local path = ""
            pcall(function() path = tostring(pkg.Path) end)
            if string.find(path, "LOTM_Pathways", 1, true) ~= nil then
                found = pkg
                break
            end
        end
    end)
    return found
end

local jumpKey, illusionKey, visionKey, transferKey = nil, nil, nil, nil
do
    local pkg = nil
    if SettingControl ~= nil then pkg = findOwnPackage() end
    local function load(name)
        local cfg = nil
        if pkg ~= nil then
            pcall(function()
                local ok, c = ConfigService.TryGetConfig(SettingControl, pkg, name)
                if ok then cfg = c end
            end)
        end
        return cfg
    end
    jumpKey = load("JumpKey")
    illusionKey = load("IllusionKey")
    visionKey = load("VisionKey")
    transferKey = load("TransferKey")
    print("[LOTM] keys jump=" .. tostring(jumpKey ~= nil) .. " illusion=" .. tostring(illusionKey ~= nil) .. " vision=" .. tostring(visionKey ~= nil) .. " transfer=" .. tostring(transferKey ~= nil))
end

-- active: move wounds from the most injured limb to the least injured one
local FALLBACK_WOUND_IDS = { "damage", "lacerations", "bleeding", "burn", "gunshotwound", "bitewounds", "deepwounds", "internaldamage", "acidburn" }

local function limbWoundList(ch, limb)
    local out = {}
    pcall(function()
        for aff in ch.CharacterHealth.GetAllAfflictions() do
            local l = nil
            pcall(function() l = ch.CharacterHealth.GetAfflictionLimb(aff) end)
            if l ~= nil and l == limb then
                local id = tostring(aff.Identifier)
                if string.sub(id, 1, 4) ~= "lotm" then
                    local s = 0
                    pcall(function() s = aff.Strength end)
                    if s ~= nil and s > 0 then
                        out[#out + 1] = { id = id, strength = s }
                    end
                end
            end
        end
    end)
    if #out == 0 then
        for _, id in ipairs(FALLBACK_WOUND_IDS) do
            local a = nil
            pcall(function() a = ch.CharacterHealth.GetAffliction(id, limb) end)
            if a ~= nil then
                local s = 0
                pcall(function() s = a.Strength end)
                if s ~= nil and s > 0 then
                    out[#out + 1] = { id = id, strength = s }
                end
            end
        end
    end
    return out
end

-- explicit destination preference: legs -> arms, torso -> legs, arms -> legs
local SHIFT_DEST = {
    [LimbType.LeftLeg]  = LimbType.LeftArm,
    [LimbType.RightLeg] = LimbType.RightArm,
    [LimbType.LeftArm]  = LimbType.LeftLeg,
    [LimbType.RightArm] = LimbType.RightLeg,
    [LimbType.Torso]    = LimbType.LeftLeg,
}
local function shiftWounds(client)
    local ch = getChar()
    if ch == nil then return end
    local seq = currentSeq(ch)
    if seq == nil or seq > 7 then reply("lotm.msg.need_seq7", COLOR_WARN, client) return end
    if amount(ch, SPIRIT) < 25 then reply("lotm.msg.low_spirit", COLOR_WARN, client) return end
    if not cdReady(ch, "shift", 25) then reply("lotm.msg.cooldown", COLOR_WARN, client) return end

    local maxhp = 100
    pcall(function() maxhp = ch.MaxHealth end)
    if maxhp == nil or maxhp <= 0 then maxhp = 100 end
    local vs = maxhp / 100

    local limbs = {}
    for _, lt in ipairs({ LimbType.Torso, LimbType.LeftArm, LimbType.RightArm, LimbType.LeftLeg, LimbType.RightLeg }) do
        local limb = nil
        pcall(function() limb = ch.AnimController.GetLimb(lt) end)
        if limb ~= nil then
            local list = limbWoundList(ch, limb)
            local total = 0
            for _, w in ipairs(list) do total = total + w.strength end
            limbs[#limbs + 1] = { limb = limb, list = list, total = total, lt = lt }
        end
    end

    table.sort(limbs, function(a, b) return a.total > b.total end)
    if #limbs < 2 then reply("lotm.msg.no_wound", COLOR_WARN, client) return end

    local src = limbs[1]
    if src.total <= 1 then
        reply("lotm.msg.no_wound", COLOR_WARN, client)
        return
    end

    -- pick the destination: legs go to arms, arms/torso go to legs
    local dst = nil
    local wanted = SHIFT_DEST[src.lt]
    if wanted ~= nil then
        for _, entry in ipairs(limbs) do
            if entry.lt == wanted then dst = entry; break end
        end
    end
    if dst == nil or dst.limb == src.limb then
        for i = #limbs, 1, -1 do
            if limbs[i].limb ~= src.limb then dst = limbs[i]; break end
        end
    end
    if dst == nil then
        reply("lotm.msg.no_wound", COLOR_WARN, client)
        return
    end

    local moved = 0
    for _, w in ipairs(src.list) do
        local amount = w.strength        -- move the whole wound, not a fraction
        -- take it off the source limb
        pcall(function() ch.CharacterHealth.ReduceAfflictionOnLimb(src.limb, w.id, amount, nil, nil) end)

        -- create it on the destination, then write the strength directly so the
        -- engine's 100/MaxVitality normalisation and max-strength clamp do not eat it
        local prefab = AfflictionPrefab.Prefabs[w.id]
        if prefab ~= nil then
            local dstAff = nil
            pcall(function() dstAff = ch.CharacterHealth.GetAffliction(w.id, dst.limb) end)
            if dstAff == nil then
                pcall(function() ch.CharacterHealth.ApplyAffliction(dst.limb, prefab.Instantiate(0.1)) end)
                pcall(function() dstAff = ch.CharacterHealth.GetAffliction(w.id, dst.limb) end)
            end
            if dstAff ~= nil then
                local cur = 0
                pcall(function() cur = dstAff.Strength end)
                if cur == nil then cur = 0 end
                pcall(function() dstAff.Strength = cur + amount end)
            end
        end
        moved = moved + amount
    end

    if moved <= 0 then
        reply("lotm.msg.no_wound", COLOR_WARN, client)
        return
    end
    setAmount(ch, SPIRIT, amount(ch, SPIRIT) - 25)
    addAmount(ch, SEQ[seq].digest, 8)
    reply("lotm.msg.shift_ok", COLOR_NORMAL, client)
end
Hook.Add("keyUpdate", "lotm.keys", function(deltaTime)
    -- never fire while typing in chat or a text box
    local busy = false
    pcall(function() busy = GUI.KeyboardDispatcher.Subscriber ~= nil end)
    if busy then return end

    local function hit(cfg)
        if cfg == nil then return false end
        local r = false
        pcall(function() r = cfg.IsHit() end)
        return r
    end

    if hit(jumpKey) then flameJump(nil) end
    if hit(illusionKey) then castIllusion(nil) end
    if hit(visionKey) then toggleVision(nil) end
    if hit(transferKey) then shiftWounds(nil) end

    -- fallback for when the config service is unavailable
    if jumpKey == nil and Keys ~= nil then
        local alt, j = false, false
        pcall(function() alt = PlayerInput.IsAltDown() end)
        if alt then
            pcall(function() j = PlayerInput.KeyHit(Keys.D1) end)
            if j then flameJump(nil) end
        end
    end
end)
-- ============================================================
-- per second logic
-- ============================================================
local tracked = {}
local dropped = {}
local wardUntil = {}

-- ============================================================
-- death watch: save the character BEFORE the death routine finishes
-- ============================================================
local lastDeathWatch = 0

local function paperSave(ch)
    local seq = tracked[ch.ID]
    if seq == nil then seq = currentSeq(ch) end
    if seq == nil or seq > 8 then return false end
    if countItem(ch, PAPER) <= 0 then return false end
    if not cdReady(ch, "paper", 90) then return false end

    consumeItem(ch, PAPER)
    local maxhp = 100
    pcall(function() maxhp = ch.MaxHealth end)
    setVitality(ch, maxhp * 0.35)
    setAmount(ch, "lotm_paperward", 100)
    pcall(function() ch.CharacterHealth.ReduceAfflictionOnAllLimbs("pressure", 1000, nil, nil) end)
    pcall(function() ch.CharacterHealth.ReduceAfflictionOnAllLimbs("oxygenlow", 1000, nil, nil) end)
    wardUntil[ch.ID] = nowSeconds() + 5
    pcall(function() ch.Unkillable = true end)
    applyAmount(ch, "bleeding", 15)
    applyAmount(ch, "internaldamage", 15)
    addAmount(ch, MADNESS, 25)
    addAmount(ch, SEQ[seq].digest, 10)
    print("[LOTM] paper figure saved " .. tostring(ch.Name))
    tell("lotm.msg.paper_save", COLOR_BAD)
    return true
end

-- catch near-zero vitality a few times per second, before the engine kills the character
Hook.Add("think", "lotm.deathwatch", function(deltaTime)
    local now = 0
    pcall(function() now = os.clock() end)
    if now - lastDeathWatch < 0.15 then return end
    lastDeathWatch = now

    pcall(function()
        for ch in Character.CharacterList do
            if ch ~= nil and ch.IsHuman and not ch.IsDead then
                local hp, maxhp = 100, 100
                pcall(function() hp = ch.Health; maxhp = ch.MaxHealth end)
                if hp ~= nil and maxhp ~= nil and maxhp > 0 and hp <= maxhp * 0.03 then
                    paperSave(ch)
                end
            end
        end
    end)
end)

-- fallback: if death still happens, revive and drop the characteristic
Hook.Add("character.death", "lotm.death", function(character, causeAffliction, causeDeathType)
    if character == nil then return end
    local human = false
    pcall(function() human = character.IsHuman end)
    if not human then return end

    -- if a paper ward is still active, force the revival without spending another figure
    if wardUntil[character.ID] ~= nil and nowSeconds() < wardUntil[character.ID] then
        pcall(function() character.Revive(false, true) end)
        local maxhp = 100
        pcall(function() maxhp = character.MaxHealth end)
        setVitality(character, maxhp * 0.35)
        return
    end

    if paperSave(character) then
        pcall(function() character.Revive(false, true) end)
        local maxhp = 100
        pcall(function() maxhp = character.MaxHealth end)
        setVitality(character, maxhp * 0.35)
        setAmount(character, "lotm_paperward", 100)
        pcall(function() character.CharacterHealth.ReduceAfflictionOnAllLimbs("oxygenlow", 1000, nil, nil) end)
        wardUntil[character.ID] = nowSeconds() + 5
        pcall(function() character.Unkillable = true end)
        return
    end

    -- drop the beyonder characteristic exactly once
    local seq = tracked[character.ID]
    if seq == nil then seq = currentSeq(character) end
    if seq ~= nil and not dropped[character.ID] then
        dropped[character.ID] = true
        tracked[character.ID] = nil
        local prefab = ItemPrefab.GetItemPrefab(SEQ[seq].char)
        if prefab ~= nil then
            print("[LOTM] dropping characteristic seq=" .. tostring(seq))
            pcall(function()
                Entity.Spawner.AddItemToSpawnQueue(prefab, character.WorldPosition, nil, nil, nil)
            end)
        end
    end
end)

local lastLogic = 0

local function logicTick()
    local ch = Character.Controlled
    if ch ~= nil and not ch.IsDead then
        if visionOn[ch.ID] then
            local sp = amount(ch, SPIRIT)
            if sp <= VISION_DRAIN then
                visionOn[ch.ID] = nil
                setAmount(ch, VISION, 0)
                setAmount(ch, SICK, 100)
                tell("lotm.msg.vision_collapse", COLOR_BAD)
            else
                setAmount(ch, SPIRIT, sp - VISION_DRAIN)
            end
        end
        if illusionUntil[ch.ID] ~= nil and nowSeconds() > illusionUntil[ch.ID] then
            illusionUntil[ch.ID] = nil
            setAmount(ch, ILLUSION, 0)
        end
        if wardUntil[ch.ID] ~= nil and nowSeconds() > wardUntil[ch.ID] then
            wardUntil[ch.ID] = nil
            pcall(function() ch.Unkillable = false end)
        end
        checkLoseControl(ch)
    end
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
    return "[" .. string.rep("=", filled) .. string.rep("-", cells - filled) .. "]"
end

local HUD_PRESETS = { { 0, 96 }, { 0, 250 }, { 0, 470 }, { -680, 120 }, { -680, 420 } }
local hudPanel = nil
local hudPreset = 1

local bars = {}

local function makeRow(parent, y, label, color)
    local name = GUI.TextBlock(GUI.RectTransform(Point(44, 14), parent.RectTransform, GUI.Anchor.TopLeft), label, nil, nil, GUI.Alignment.Left)
    name.RectTransform.AbsoluteOffset = Point(2, y)
    name.TextScale = 0.8
    name.TextColor = Color(205, 215, 235, 255)

    local bg = GUI.Frame(GUI.RectTransform(Point(170, 12), parent.RectTransform, GUI.Anchor.TopLeft), "GUITextBox")
    bg.RectTransform.AbsoluteOffset = Point(48, y + 1)
    bg.RectTransform.MinSize = Point(170, 12)
    bg.Color = Color(14, 18, 26, 220)

    local fill = GUI.Frame(GUI.RectTransform(Vector2(1, 1), bg.RectTransform, GUI.Anchor.TopLeft), "GUITextBox")
    fill.Color = color
    fill.RectTransform.MinSize = Point(0, 12)

    local val = GUI.TextBlock(GUI.RectTransform(Point(92, 14), parent.RectTransform, GUI.Anchor.TopLeft), "", nil, nil, GUI.Alignment.Left)
    val.RectTransform.AbsoluteOffset = Point(222, y)
    val.TextScale = 0.8
    val.TextColor = Color(205, 215, 235, 255)

    return { fill = fill, value = val }
end

local function setBar(row, v, maxv)
    if row == nil then return end
    local pct = v / maxv
    if pct < 0 then pct = 0 end
    if pct > 1 then pct = 1 end
    pcall(function() row.fill.RectTransform.RelativeSize = Vector2(pct, 1) end)
    pcall(function() row.value.Text = string.format("%d/%d", math.floor(v + 0.5), maxv) end)
end

local function buildHUD()
    if not CLIENT then return end
    local ok = pcall(function()
        hudRoot = GUI.Frame(GUI.RectTransform(Vector2(1, 1)), nil)
        hudRoot.CanBeFocused = false

        -- sits above the vanilla character panel in the bottom-right corner
        local panel = GUI.Frame(GUI.RectTransform(Point(320, 104), hudRoot.RectTransform, GUI.Anchor.TopCenter), "GUITextBox")
        panel.RectTransform.AbsoluteOffset = Point(HUD_PRESETS[hudPreset][1], HUD_PRESETS[hudPreset][2])
        hudPanel = panel
        panel.RectTransform.MinSize = Point(320, 104)
        panel.CanBeFocused = false

        hudText.title = GUI.TextBlock(GUI.RectTransform(Point(316, 16), panel.RectTransform, GUI.Anchor.TopLeft), "", nil, nil, GUI.Alignment.Left)
        hudText.title.RectTransform.AbsoluteOffset = Point(2, 2)
        hudText.title.TextScale = 0.85
        hudText.title.TextColor = Color(255, 214, 140, 255)

        bars.sp  = makeRow(panel, 22, L("lotm.hud.sp"),  Color(70, 145, 255, 255))
        bars.mad = makeRow(panel, 40, L("lotm.hud.mad"), Color(190, 70, 210, 255))
        bars.dig = makeRow(panel, 58, L("lotm.hud.dig"), Color(230, 170, 80, 255))

        local btnVision = GUI.Button(GUI.RectTransform(Point(150, 22), panel.RectTransform, GUI.Anchor.BottomLeft), L("lotm.hud.vision"), GUI.Alignment.Center, "GUIButtonSmall")
        btnVision.OnClicked = function() toggleVision(nil) end

        local btnDivine = GUI.Button(GUI.RectTransform(Point(150, 22), panel.RectTransform, GUI.Anchor.BottomRight), L("lotm.hud.divine"), GUI.Alignment.Center, "GUIButtonSmall")
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

    local seq = currentSeq(ch)
    local sp = amount(ch, SPIRIT)
    local mad = amount(ch, MADNESS)
    local dig = 0
    if seq ~= nil then dig = amount(ch, SEQ[seq].digest) end

    pcall(function()
        local hp, maxhp = 0, 100
        pcall(function() hp = ch.Health; maxhp = ch.MaxHealth end)
        if hp == nil then hp = 0 end
        if maxhp == nil or maxhp <= 0 then maxhp = 100 end
        hudText.title.Text = L("lotm.hud.title") .. " - " .. (seq and L(SEQ[seq].nameKey) or L("lotm.hud.novice"))
            .. "  " .. L("lotm.hud.hp") .. " " .. math.floor(hp + 0.5) .. "/" .. math.floor(maxhp + 0.5)
    end)
    setBar(bars.sp, sp, 100)
    setBar(bars.mad, mad, 100)
    setBar(bars.dig, dig, 100)
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
            if hp == nil then hp = 0 end
            if maxhp == nil then maxhp = 0 end
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

    for _, a in ipairs(aliases("lotm.cmd.debug")) do
        if message == a then
            local ch = Character.Controlled
            if ch == nil then return true end
            local lines = {}
            local v = nil
            pcall(function() v = ch.CharacterHealth.GetAfflictionStrengthByIdentifier("lotm_madness", true) end)
            lines[#lines + 1] = "api=" .. string.format("%.1f", v or -1)
            for _, lt in ipairs(LIMB_TYPES) do
                local limb = nil
                pcall(function() limb = ch.AnimController.GetLimb(lt) end)
                if limb ~= nil then
                    local aff = nil
                    pcall(function() aff = ch.CharacterHealth.GetAffliction("lotm_madness", limb) end)
                    if aff ~= nil then
                        local s = 0
                        pcall(function() s = aff.Strength end)
                        lines[#lines + 1] = tostring(lt) .. "=" .. string.format("%.1f", s)
                    end
                end
            end
            send(table.concat(lines, " "), COLOR_NORMAL, client)
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.pos")) do
        if message == a then
            hudPreset = hudPreset % #HUD_PRESETS + 1
            if hudPanel ~= nil then
                pcall(function() hudPanel.RectTransform.AbsoluteOffset = Point(HUD_PRESETS[hudPreset][1], HUD_PRESETS[hudPreset][2]) end)
            end
            send("[LOTM] position " .. tostring(hudPreset), COLOR_NORMAL, client)
            return true
        end
    end
    for _, a in ipairs(aliases("lotm.cmd.jump")) do
        if message == a then
            flameJump(client)
            return true
        end
    end

    for _, a in ipairs(aliases("lotm.cmd.illusion")) do
        if message == a then
            castIllusion(client)
            return true
        end
    end
    for _, a in ipairs(aliases("lotm.cmd.shift")) do
        if message == a then
            shiftWounds(client)
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
