--------------------------------------------------------------------------
-- modmain.lua (UNIFIED) - Willow Ally Fire Safety (centralized)
-- Put this file at the root of the mod (replace existing modmain.lua)
--------------------------------------------------------------------------

local GLOBAL = GLOBAL
local TheNet = GLOBAL.TheNet
local TheSim = GLOBAL.TheSim
local TheWorld = GLOBAL.TheWorld
local SpawnPrefab = GLOBAL.SpawnPrefab
local Vector3 = GLOBAL.Vector3

-- Local API shortcuts (available inside modmain)
local AddPrefabPostInit = GLOBAL.AddPrefabPostInit
local AddPrefabPostInitAny = GLOBAL.AddPrefabPostInitAny or function() end
local AddComponentPostInit = GLOBAL.AddComponentPostInit
local AddPlayerPostInit = GLOBAL.AddPlayerPostInit

local function IsServer()
    return TheNet ~= nil and (TheNet:GetIsServer() or TheNet:IsDedicated())
end

--------------------------------------------------------------------------
-- CONFIG: list of fire-like prefab names to watch (extend if needed)
--------------------------------------------------------------------------
local FIRE_PREFABS = {
    "fire", "campfire", "torchfire", "smallfire", "fx_fire", "lunar_fire", "shadowfire", "willowfirefx", "willowfx"
}

--------------------------------------------------------------------------
-- Utility: defensive safe call
--------------------------------------------------------------------------
local function SafePcall(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        print("[WillowFireSafety] SafePcall error:", tostring(res))
    end
    return ok, res
end

--------------------------------------------------------------------------
-- TryMarkWillowFire: tag fire prefabs that originate from Willow
-- We try multiple common fields (_owner, creator, parent, etc.)
--------------------------------------------------------------------------
local function TryMarkWillowFire(inst)
    if not inst or inst:HasTag == nil then return end
    if inst:HasTag("willow_fire_source") then return end

    inst:DoTaskInTime(0, function()
        SafePcall(function()
            local owner = inst._owner or inst.creator or inst._creator or inst.owner
            local is_willow = false

            if owner then
                if type(owner) == "string" then
                    if owner == "willow" then is_willow = true end
                else
                    -- owner may be an entity
                    if owner.prefab and owner.prefab == "willow" then
                        is_willow = true
                    elseif owner:HasTag and owner:HasTag("willow") then
                        is_willow = true
                    end
                end
            end

            -- parent chain
            if not is_willow and inst.entity and inst.entity:GetParent() then
                local parent = inst.entity:GetParent()
                if parent and parent.prefab and parent.prefab == "willow" then
                    is_willow = true
                end
            end

            if is_willow then
                inst:AddTag("willow_fire_source")
                -- defensive: reduce propagation/heat if possible
                if inst.components and inst.components.propagator then
                    pcall(function()
                        inst.components.propagator.spreadrange = 0
                        inst.components.propagator.heatoutput = 0
                        if type(inst.components.propagator.SetRange) == "function" then
                            inst.components.propagator:SetRange(0)
                        end
                    end)
                end
                if inst.components and inst.components.burner and inst.components.burner.heat ~= nil then
                    pcall(function() inst.components.burner.heat = 0 end)
                end
            end
        end)
    end)
end

-- Attach TryMarkWillowFire to common fire prefabs
if AddPrefabPostInit then
    for _, pf in ipairs(FIRE_PREFABS) do
        AddPrefabPostInit(pf, function(inst)
            if not IsServer() then return end
            SafePcall(function() TryMarkWillowFire(inst) end)
        end)
    end
end

-- Fallback: watch any prefab with 'fire'/'flame' in name
if AddPrefabPostInitAny and type(AddPrefabPostInitAny) == "function" then
    AddPrefabPostInitAny(function(inst)
        if not IsServer() then return end
        if not inst or not inst.prefab then return end
        local name = tostring(inst.prefab)
        if string.find(name, "fire") or string.find(name, "flame") or string.find(name, "ember") then
            SafePcall(function() TryMarkWillowFire(inst) end)
        end
    end)
end

--------------------------------------------------------------------------
-- FIRE PROTECTOR: prevent players/loot/structures/passive mobs from burning
-- Keep monsters/hostile burning normally.
--------------------------------------------------------------------------

local function IsProtectedFromFire(inst)
    if not inst or not inst:IsValid() then return false end

    -- players
    if inst:HasTag("player") then return true end

    -- structures/walls
    if inst:HasTag("structure") or inst:HasTag("wall") then return true end

    -- items on ground
    if inst.components and inst.components.inventoryitem then return true end

    -- passive animals / small creatures
    if inst:HasTag("prey") or inst:HasTag("bird") or inst:HasTag("smallcreature") or inst:HasTag("animal") or inst:HasTag("companion") or inst:HasTag("beefalo") or inst:HasTag("catcoon") or inst:HasTag("butterfly") then
        return true
    end

    -- explicit opt-in protected tag
    if inst:HasTag("willow_fire_protected") then return true end

    return false
end

local function IsMonsterOrHostile(inst)
    if not inst then return false end
    return inst:HasTag("monster") or inst:HasTag("hostile") or inst:HasTag("scarytoprey") or inst:HasTag("epic") or inst:HasTag("largecreature")
end

local function TryStopSpreading(inst)
    if not inst or not inst.components or not inst.components.propagator then return end
    SafePcall(function()
        local p = inst.components.propagator
        if type(p.StopSpreading) == "function" then
            p:StopSpreading()
        else
            p.spreadrange = 0
            p.heatoutput = 0
            if type(p.SetRange) == "function" then p:SetRange(0) end
        end
    end)
end

local function OnIgniteHandler(ent)
    if not ent or not ent:IsValid() then return end
    if not ent.components or not ent.components.burnable then return end

    -- If protected (players/loot/structures/passive), extinguish immediately and stop propagation
    if IsProtectedFromFire(ent) then
        SafePcall(function()
            if ent.components.burnable:IsBurning() then
                if type(ent.components.burnable.Extinguish) == "function" then
                    ent.components.burnable:Extinguish(true)
                end
            end
            TryStopSpreading(ent)
        end)
        return
    end

    -- If not explicit monster/hostile, extinguish defensively
    if not IsMonsterOrHostile(ent) then
        SafePcall(function()
            if ent.components.burnable:IsBurning() then
                if type(ent.components.burnable.Extinguish) == "function" then
                    ent.components.burnable:Extinguish(true)
                end
            end
            TryStopSpreading(ent)
        end)
        return
    end

    -- else: monster/hostile => allow burning
end

-- Apply fire protector to all prefabs that have burnable
if AddPrefabPostInitAny and type(AddPrefabPostInitAny) == "function" then
    AddPrefabPostInitAny(function(inst)
        if not IsServer() then return end
        if not inst then return end
        inst:DoTaskInTime(0, function()
            SafePcall(function()
                if inst and inst.components and inst.components.burnable then
                    if not inst._willow_fire_protector_installed then
                        inst:ListenForEvent("onignite", function() OnIgniteHandler(inst) end)
                        inst._willow_fire_protector_installed = true
                    end
                end
            end)
        end)
    end)
end

--------------------------------------------------------------------------
-- Wrap burnable:Ignite (store original) to tag things burned by Willow
-- This lets other code know a mob/item was burned specifically by Willow.
--------------------------------------------------------------------------

if AddComponentPostInit then
    AddComponentPostInit("burnable", function(self)
        if not IsServer() then return end
        if not self or not self.inst then return end

        local orig_Ignite = self.Ignite
        if type(orig_Ignite) ~= "function" then
            return
        end

        self.Ignite = function(self2, igniter, ...)
            local result
            SafePcall(function()
                result = orig_Ignite(self2, igniter, ...)
                -- detect willow source
                local is_willow = false
                if igniter then
                    if igniter.prefab and igniter.prefab == "willow" then
                        is_willow = true
                    elseif igniter:HasTag and igniter:HasTag("willow_fire_source") then
                        is_willow = true
                    elseif igniter:HasTag and igniter:HasTag("willow") then
                        is_willow = true
                    end
                end
                if not is_willow then
                    -- some ignite calls pass an owner parent; try self2.inst._owner fields
                    local owner = self2.inst and (self2.inst._owner or self2.inst.creator or self2.inst._creator)
                    if owner and owner.prefab and owner.prefab == "willow" then
                        is_willow = true
                    end
                end

                if is_willow and self2.inst and self2.inst.AddTag then
                    self2.inst:AddTag("burned_by_willow")
                    -- schedule removal later (defensive)
                    if self2._willow_tag_task then self2._willow_tag_task:Cancel() end
                    self2._willow_tag_task = self2.inst:DoTaskInTime(30, function()
                        if self2.inst and self2.inst:HasTag and self2.inst:HasTag("burned_by_willow") and (not self2.IsBurning or not self2:IsBurning()) then
                            self2.inst:RemoveTag("burned_by_willow")
                        end
                    end)
                end
            end)
            return result
        end
    end)
end

--------------------------------------------------------------------------
-- Intercept lootdropper:DropLoot to extinguish smolder on dropped items when killed/burned by Willow
--------------------------------------------------------------------------

if AddComponentPostInit then
    AddComponentPostInit("lootdropper", function(self)
        if not IsServer() then return end
        if not self or not self.inst then return end
        local orig_DropLoot = self.DropLoot
        if type(orig_DropLoot) ~= "function" then return end

        self.DropLoot = function(self2, doer, ...)
            local res
            SafePcall(function()
                res = orig_DropLoot(self2, doer, ...)
                local inst = self2.inst
                local mark = false
                if doer and doer.prefab and doer.prefab == "willow" then mark = true end
                if inst and inst:HasTag and inst:HasTag("burned_by_willow") then mark = true end

                if mark then
                    local x, y, z = inst.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 3)
                    for _, e in ipairs(ents) do
                        SafePcall(function()
                            if e and e.components and e.components.burnable then
                                if type(e.components.burnable.IsSmoldering) == "function" and e.components.burnable:IsSmoldering() then
                                    if type(e.components.burnable.Extinguish) == "function" then
                                        e.components.burnable:Extinguish()
                                    end
                                end
                                if e.components.burnable.canstartsmoldering ~= nil then
                                    e.components.burnable.canstartsmoldering = false
                                end
                                e:AddTag("no_smolder_from_willow")
                            end
                        end)
                    end
                end
            end)
            return res
        end
    end)
end

--------------------------------------------------------------------------
-- Prevent players from receiving burn/contact damage from willow fires
-- Listen to 'attacked' and 'onhitother' to heal/extinguish as necessary.
--------------------------------------------------------------------------

if AddPlayerPostInit then
    AddPlayerPostInit(function(player)
        if not IsServer() then return end
        if not player or not player.ListenForEvent then return end

        player:ListenForEvent("attacked", function(inst, data)
            if not data then return end
            local attacker = data.attacker
            if not attacker then return end
            local attacker_is_willowfire = false
            if attacker:HasTag and attacker:HasTag("willow_fire_source") then attacker_is_willowfire = true end
            if not attacker_is_willowfire and attacker:HasTag and attacker:HasTag("willow") then attacker_is_willowfire = true end
            if attacker_is_willowfire then
                -- restore HP equal to damage (if present)
                if data.damage and inst.components and inst.components.health and not inst.components.health:IsDead() then
                    SafePcall(function()
                        inst.components.health:DoDelta(data.damage, false, "willow_fire_safe")
                    end)
                end
                -- extinguish if set on fire
                if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                    SafePcall(function() inst.components.burnable:Extinguish() end)
                end
            end
        end)

        -- When player hits others, ensure they don't get contact burns if target burned_by_willow
        player:ListenForEvent("onhitother", function(inst, data)
            if not data or not data.target then return end
            local target = data.target
            if target and target:HasTag and target:HasTag("burned_by_willow") then
                if inst.components and inst.components.burnable and type(inst.components.burnable.Extinguish) == "function" then
                    SafePcall(function()
                        inst.components.burnable:Extinguish()
                        if type(inst.components.burnable.IsSmoldering) == "function" and inst.components.burnable:IsSmoldering() then
                            inst.components.burnable:Extinguish()
                        end
                    end)
                end
            end
        end)
    end)
end

--------------------------------------------------------------------------
-- OPTIONAL: reduce player temperature changes coming from willow fires
-- Wrap player's temperature.DoDelta to ignore heating events when source is willow fire (if source passed)
--------------------------------------------------------------------------

if AddPlayerPostInit then
    AddPlayerPostInit(function(player)
        if not IsServer() then return end
        if not player or not player.components or not player.components.temperature then return end
        local temp = player.components.temperature
        if type(temp.DoDelta) ~= "function" then return end

        local orig_DoDelta = temp.DoDelta
        temp.DoDelta = function(self, delta, ...)
            local source = select(1, ...)
            if delta > 0 and source and source:HasTag and source:HasTag("willow_fire_source") then
                -- ignore heating events with explicit willow source
                return
            end
            return orig_DoDelta(self, delta, ...)
        end
    end)
end

--------------------------------------------------------------------------
-- SYSTEM: Track when Willow-fire burns an enemy
--------------------------------------------------------------------------

-- Mark enemies burned by Willow
local function MarkAsBurnedByWillow(inst)
    if inst and inst:IsValid() then
        inst:AddTag("burned_by_willow")

        -- auto-clear after 10s (avoid stacking)
        inst:DoTaskInTime(10, function()
            if inst and inst:IsValid() then
                inst:RemoveTag("burned_by_willow")
            end
        end)
    end
end

--------------------------------------------------------------------------
-- INTERCEPT FIRE DAMAGE TO MARK WILLOW DAMAGE
--------------------------------------------------------------------------

AddComponentPostInit("combat", function(self)
    local old_GetAttacked = self.GetAttacked

    self.GetAttacked = function(comp, attacker, damage, weapon, stimuli, ...)
        -- If attacker is Willow or a Willow-fire prefab
        if attacker then
            if attacker:HasTag("willow_fire_source") or attacker:HasTag("willow_fire") then
                MarkAsBurnedByWillow(comp.inst)
            end
        end

        return old_GetAttacked(comp, attacker, damage, weapon, stimuli, ...)
    end
end)

--------------------------------------------------------------------------
-- WHEN LOOT DROPS, PROTECT ONLY IF SOURCE HAD "burned_by_willow"
--------------------------------------------------------------------------

local function MakeFireproof(inst)
    if not inst or not inst:IsValid() then return end
    if not inst.components then return end

    inst:DoTaskInTime(0, function()
        if inst.components.burnable then
            inst.components.burnable.canstartsmoldering = false
            inst.components.burnable.canlite = false
            if inst.components.burnable:IsBurning() then
                inst.components.burnable:Extinguish(true)
            end
            if inst.components.burnable:IsSmoldering() then
                inst.components.burnable:Extinguish(true)
            end
        end

        if inst.components.propagator then
            inst.components.propagator.spreading = false
            inst.components.propagator.acceptheat = false
            inst.components.propagator.heatoutput = 0
            inst.components.propagator:SetRange(0)
        end

        inst:AddTag("loot_fireproof")
    end)
end

-- Intercept death events
AddPrefabPostInitAny(function(inst)
    if not TheNet:GetIsServer() then return end
    if not inst.components or not inst.components.health then return end

    inst:ListenForEvent("death", function(inst)
        if not inst:HasTag("burned_by_willow") then
            return -- not killed by Willow fire → normal loot
        end

        inst:DoTaskInTime(0, function()
            if inst.components.lootdropper then
                local loot = inst.components.lootdropper:GenerateLoot()
                for _, item in ipairs(loot) do
                    MakeFireproof(item)
                end
            end
        end)
    end)
end)

--------------------------------------------------------------------------
-- Print ready
--------------------------------------------------------------------------

print("[WillowFireSafety] Unified modmain loaded - protections active (server only).")
