local GLOBAL = GLOBAL
local TheSim = GLOBAL.TheSim
local TheNet = GLOBAL.TheNet

-- Server check
local function IsServer()
    return TheNet ~= nil and (TheNet:GetIsServer() or TheNet:IsDedicated())
end

-- Read configuration options (use MODNAME to avoid "modname must be supplied" error)
local CONF_NO_OVERHEAT =
    GetModConfigData and GetModConfigData("NO_WILLOW_OVERHEAT", MODNAME) ~= false
local CONF_NO_AOE_PENALTIES =
    GetModConfigData and GetModConfigData("NO_WILLOW_AOE_PENALTIES", MODNAME) ~= false
local CONF_NO_BURN_ON_HITTING =
    GetModConfigData and GetModConfigData("NO_BURN_DAMAGE_ON_HITTING", MODNAME) ~= false
local CONF_NO_SMOLDER_FROM_WILLOW =
    GetModConfigData and GetModConfigData("NO_SMOLDERING_FROM_WILLOW", MODNAME) ~= false
local CONF_NO_FIRE_SPREAD =
    GetModConfigData and GetModConfigData("NO_WILLOW_FIRE_SPREAD", MODNAME) ~= false
local CONF_SHOW_VISUAL_INDICATOR =
    GetModConfigData and GetModConfigData("SHOW_VISUAL_INDICATOR", MODNAME) == true

----------------------------------------------------------------
-- Utilities (defensive)
----------------------------------------------------------------

-- Safe check for valid entity
local function IsValidEntity(e)
    return e ~= nil and type(e.IsValid) == "function" and e:IsValid()
end

-- Safe extinguish / remove propagation / prevent smolder on an entity
local function SafeExtinguish(ent)
    if not ent or (type(ent.IsValid) == "function" and not ent:IsValid()) then return end

    local prop = ent.components and ent.components.propagator
    if prop then
        if prop.acceptsheat ~= nil then prop.acceptsheat = false end
        if prop.heatoutput ~= nil then prop.heatoutput = 0 end
        if type(prop.SetRange) == "function" then
            -- use pcall-less defensive call
            local ok, _ = pcall and pcall(prop.SetRange, prop, 0) or (prop.SetRange(prop, 0) and true)
            -- ignore result; no error propagation
        end
        if type(prop.StopSpreading) == "function" then
            prop:StopSpreading()
        end
        if type(prop.StopSpreadingSmoke) == "function" then
            prop:StopSpreadingSmoke()
        end
    end

    local burn = ent.components and ent.components.burnable
    if burn then
        if type(burn.IsBurning) == "function" and burn:IsBurning() then
            if type(burn.Extinguish) == "function" then
                burn:Extinguish(true)
            end
        end
        if burn.canstartsmoldering ~= nil then burn.canstartsmoldering = false end
        if burn.canlite ~= nil then burn.canlite = false end
        -- override Ignite to a no-op if possible
        if type(burn.Ignite) == "function" then
            -- avoid pcall if not necessary; replace function reference directly
            burn.Ignite = function() return false end
        end
    end

    if ent.AddTag then
        ent:AddTag("loot_fireproof")
        ent:AddTag("fireimmune")
    end
end

-- Lightweight detection if a given source was created/owned by Willow.
-- This checks common owner/creator fields and tags — intentionally lightweight.
local function IsWillowSource(src)
    if not src then return false end

    -- direct prefab
    if src.prefab == "willow" then return true end

    -- tag checks
    if type(src.HasTag) == "function" then
        if src:HasTag("willow") or src:HasTag("willow_fire_source") or src:HasTag("willowfire") then
            return true
        end
    end

    -- owner / creator / _owner / _creator fields commonly used by fx
    local owner = src._owner or src.owner or src.creator or src._creator
    if owner and type(owner) == "table" and owner.prefab == "willow" then
        return true
    end

    -- parent entity
    if src.entity and src.entity:GetParent() then
        local parent = src.entity:GetParent()
        if parent and parent.prefab == "willow" then
            return true
        end
    end

    return false
end

----------------------------------------------------------------
-- LOOT PROTECTION (Option A): protect loot if the source entity was burning at death
-- Implementation approach:
-- 1) Add a death listener to entities with health: mark victim._died_burning if it was burning at death
-- 2) Override lootdropper.SpawnLootPrefab to apply SafeExtinguish/remove propagator to spawned loot
-- 3) As extra fallback, death handler runs a delayed sweep and extinguishes nearby dropped items
----------------------------------------------------------------

-- 1) death listener installer
if AddPrefabPostInitAny then
    AddPrefabPostInitAny(function(inst)
        if not IsServer() then return end
        if not inst or not inst.components then return end
        if not inst.components.health then return end

        if inst._willow_death_listener_installed then return end

        inst:ListenForEvent("death", function(victim, data)
            if not victim or (type(victim.IsValid) == "function" and not victim:IsValid()) then return end

            -- mark if died while burning
            local died_burning = false
            if victim.components and victim.components.burnable and type(victim.components.burnable.IsBurning) == "function" then
                died_burning = victim.components.burnable:IsBurning()
            end

            victim._died_burning = died_burning

            -- delayed fallback: extinguish spawned loot nearby shortly after death
            if CONF_NO_SMOLDER_FROM_WILLOW and died_burning then
                victim:DoTaskInTime(0.15, function()
                    if not victim or (type(victim.IsValid) == "function" and not victim:IsValid()) then return end
                    local x, y, z = victim.Transform:GetWorldPosition()
                    -- find inventory items (dropped loot) within small radius and protect them
                    local ents = TheSim:FindEntities(x, y, z, 4, { "inventoryitem" })
                    for _, e in ipairs(ents) do
                        if e and (type(e.IsValid) ~= "function" or e:IsValid()) then
                            -- remove propagator if present (safe)
                            if e.components and e.components.propagator then
                                e:RemoveComponent("propagator")
                            end
                            SafeExtinguish(e)
                        end
                    end
                end)
            end
        end)

        inst._willow_death_listener_installed = true
    end)
end

-- 2) Override lootdropper.SpawnLootPrefab to secure spawned loot
if AddComponentPostInit then
    AddComponentPostInit("lootdropper", function(self)
        if not IsServer() then return end
        if not self or not self.inst then return end
        if type(self.SpawnLootPrefab) ~= "function" then return end

        local orig_SpawnLootPrefab = self.SpawnLootPrefab
        self.SpawnLootPrefab = function(self2, lootprefab, pt, ...)
            -- call original to spawn the loot
            local loot = orig_SpawnLootPrefab(self2, lootprefab, pt, ...)
            if not loot or (type(loot.IsValid) == "function" and not loot:IsValid()) then
                return loot
            end

            -- Option A: protect loot if the source entity died burning
            local source_inst = self2 and self2.inst
            local protect = false
            if CONF_NO_SMOLDER_FROM_WILLOW and source_inst then
                if source_inst._died_burning == true then
                    protect = true
                end
            end

            if protect then
                -- remove propagator if present (safer than toggling internals)
                if loot.components and loot.components.propagator then
                    loot:RemoveComponent("propagator")
                end
                -- extinguish / prevent smolder
                SafeExtinguish(loot)

                -- ensure stacked items remain protected
                if loot.components and loot.components.stackable then
                    loot.components.stackable.onstacksizechange = function(stack_inst)
                        if stack_inst then SafeExtinguish(stack_inst) end
                    end
                end
            end

            return loot
        end
    end)
end

----------------------------------------------------------------
-- PLAYER PROTECTIONS: neutralize damage & contact burns from willow-origin sources
-- Lightweight detection via IsWillowSource (owner/creator/parent/tags).
----------------------------------------------------------------
if AddPlayerPostInit then
    AddPlayerPostInit(function(player)
        if not player or not player.components then return end

        -- AOE / proximity penalties: attacked event handler
        player:ListenForEvent("attacked", function(inst, data)
            if not data then return end
            local attacker = data.attacker
            if not attacker then return end

            -- If we can detect attacker as Willow source, neutralize AOE/burn
            if CONF_NO_AOE_PENALTIES and IsWillowSource(attacker) then
                if data.damage and data.damage > 0 and inst.components and inst.components.health then
                    -- heal back the damage to achieve 0 net damage
                    inst.components.health:DoDelta(data.damage, false, "willow_fire_safe")
                end
                -- extinguish player if they are burning
                if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                    inst.components.burnable:Extinguish(true)
                end
            end

            -- If NO_OVERHEAT set, ensure temperature effects are mitigated
            if CONF_NO_OVERHEAT and IsWillowSource(attacker) then
                if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                    inst.components.burnable:Extinguish(true)
                end
            end
        end)

        -- Prevent contact burn when hitting burning targets (if enabled)
        if CONF_NO_BURN_ON_HITTING then
            player:ListenForEvent("onhitother", function(inst, data)
                if not data or not data.target then return end
                local target = data.target
                if target and (target._died_burning == true or (target.components and target.components.burnable and type(target.components.burnable.IsBurning) == "function" and target.components.burnable:IsBurning())) then
                    if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                        inst.components.burnable:Extinguish(true)
                    end
                end
            end)
        end

        -- Temperature DoDelta wrapper: ignore positive deltas if from willow source
        if CONF_NO_OVERHEAT and player.components and player.components.temperature and type(player.components.temperature.DoDelta) == "function" then
            local temp = player.components.temperature
            local orig_DoDelta = temp.DoDelta
            temp.DoDelta = function(self2, delta, source, ...)
                if delta and delta > 0 and source and IsWillowSource(source) then
                    return
                end
                return orig_DoDelta(self2, delta, source, ...)
            end
        end
    end)
end

----------------------------------------------------------------
-- FIRE PREFAB POSTINIT: attempt to stop spread for willow-origin fires
-- Lightweight and defensive: check owner/creator and apply only when detected.
----------------------------------------------------------------
local FIRE_PREFABS = {
    "fire", "campfire", "torchfire", "smallfire", "fx_fire",
    "lunar_fire", "shadowfire", "willowfirefx", "willowfx", "ember", "willow_ember"
}

if AddPrefabPostInit then
    for _, pf in ipairs(FIRE_PREFABS) do
        AddPrefabPostInit(pf, function(inst)
            if not IsServer() then return end
            if not inst then return end

            -- run shortly after spawn to allow owner/creator fields to populate
            inst:DoTaskInTime(0, function()
                if not inst or (type(inst.IsValid) == "function" and not inst:IsValid()) then return end

                if CONF_NO_FIRE_SPREAD and IsWillowSource(inst) then
                    if inst.components and inst.components.propagator then
                        local p = inst.components.propagator
                        if p.spreadrange ~= nil then p.spreadrange = 0 end
                        if p.heatoutput ~= nil then p.heatoutput = 0 end
                        if type(p.SetRange) == "function" then p:SetRange(0) end
                        if type(p.StopSpreading) == "function" then p:StopSpreading() end
                        if type(p.StopSpreadingSmoke) == "function" then p:StopSpreadingSmoke() end
                    end

                    if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                        if type(inst.components.burnable.IsBurning) == "function" and inst.components.burnable:IsBurning() then
                            inst.components.burnable:Extinguish(true)
                        end
                    end
                end
            end)
        end)
    end
end

----------------------------------------------------------------
-- Final log
----------------------------------------------------------------
print("[WillowFireSafety - Option A] Loaded. Configs:",
      "NO_OVERHEAT=" .. tostring(CONF_NO_OVERHEAT),
      "NO_AOE_PENALTIES=" .. tostring(CONF_NO_AOE_PENALTIES),
      "NO_BURN_ON_HITTING=" .. tostring(CONF_NO_BURN_ON_HITTING),
      "NO_SMOLDER_FROM_WILLOW=" .. tostring(CONF_NO_SMOLDER_FROM_WILLOW),
      "NO_FIRE_SPREAD=" .. tostring(CONF_NO_FIRE_SPREAD),
      "SHOW_VISUAL_INDICATOR=" .. tostring(CONF_SHOW_VISUAL_INDICATOR))
