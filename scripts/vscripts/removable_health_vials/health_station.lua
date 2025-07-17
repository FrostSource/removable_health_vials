--[[
]]

local version = "v1.0.0"

RegisterAlyxLibAddon("Removable Health Vials", version, "3527754624", "removable_vials", "v2.0.0")

EasyConvars:RegisterConvar("close_health_station_on_vial_removal", "0", "If set to 1, the station will close up when the vial is removed")
EasyConvars:SetPersistent("close_health_station_on_vial_removal", true)

---
---Turns a regular item_healthcharger into one that can have its vial removed at any point.
---
---@param station EntityHandle # The item_healthcharger to convert
function ConvertHealthStationToRemovable(station)
    if not IsValidEntity(station) or station:GetClassname() ~= "item_healthcharger" then
        return warn("ConvertHealthStationToRemovable: Invalid station provided")
    end

    if isinstance(station, "RemovableHealthVialStation") then
        return warn("ConvertHealthStationToRemovable: Station is already removable")
    end

    inherit(RemovableHealthVialStation, station)
    ---@cast station RemovableHealthVialStation
    station:Init()
end


if thisEntity then
    -- Inherit this script if attached to entity
    -- Will also load the script at the same time if needed
    inherit(GetScriptFile())
    return
end

---@class RemovableHealthVialStation : EntityClass
local base = entity("RemovableHealthVialStation")

---
---Must be called after inheriting this class to setup the station.
---
function base:Init()
    local charger = self:GetChild("item_health_station_charger")
    if charger then
        charger:RedirectOutput("OnCompletionA_Forward", "HandleVialCrushSignal", self)
    end
    local lerp = self:GetChild("trigger_lerp_object")
    if lerp then
        lerp:RedirectOutput("OnLerpFinished", "HealthVialInserted", self)
    end

    if self:GetAttachedVial() then
        self:HealthVialInserted()
    end
end

---
---Finds the health vial attached to this station if one exists.
---
---@return EntityHandle? # The health vial attached
function base:GetAttachedVial()
    for child in self:IterateChildren() do
        if IsValidEntity(child)
        and child:GetClassname() == "item_hlvr_health_station_vial"
        and child:GetName() ~= self:GetName() .. "_vial_proxy" -- ignore pickup proxy
        then
            return child
        end
    end
end

---
---Tells the station to close up.
---
function base:AnimateClose()
    local charger = self:GetChild("item_health_station_charger")
    if not charger then
        return warn("Could not find charger!")
    end

    charger:EntFire("SetReturnToCompletionAmount", 0)
    charger:EntFire("EnableReturnToCompletion")
end

---
---Resets the station by cloning and destroying this one.
---
---@return RemovableHealthVialStation? # The new station if it was successfully created
function base:ResetStation()
    -- get completion values
    -- kill self (and all related)
    -- create new station at transform with completion value
    -- set new health station as removable

    local charger = self:GetChild("item_health_station_charger")
    if not charger then
        return warn("Could not find charger!")
    end

    local completion = charger:GetCycle()

    local keys = {
        class = self:GetClassname(),
        targetname = self:GetName(),
        origin = self:GetOrigin(),
        angles = self:GetAngles(),
        -- if reset in the middle of squishing, a 
	    start_with_vial = false --self:GetChild("item_hlvr_health_station_vial") ~= nil
    }

    -- Try to get the current internals animation if not retracted
    local internals = self:GetChild("item_healthcharger_internals")
    local internalsSequence
    if internals and internals:GetSequence() ~= "idle_retracted" then
        internalsSequence = internals:GetSequence()
    end

    -- Stop lp sound before killing to avoid infinite loop
    self:StopSound('HealthStation.Loop')
    self:Kill()

    local newStation = SpawnEntityFromTableSynchronous(keys.class, keys)
    ConvertHealthStationToRemovable(newStation)
    ---@cast newStation RemovableHealthVialStation

    newStation:SetOpenAmount(completion)

    -- Animate the internals retracting if out
    local newCharger = newStation:GetChild("item_health_station_charger")
    local newInternals = newStation:GetChild("item_healthcharger_internals")
    if newCharger and newInternals then
        if completion > 0.5 and internalsSequence then
            newInternals:SetSequence(internalsSequence)
            newInternals:EntFire("SetAnimationTransition", internalsSequence)
            newInternals:EntFire("SetAnimation", "idle_retracted", 0.1)
        end
    end

    if EasyConvars:GetBool("close_health_station_on_vial_removal") then
        newStation:AnimateClose()
    end

    return newStation
end

---
---Ejects the current health vial if one is attached.
---
---@param noForce? boolean # If true the vial will not have physics forces applied
---@return EntityHandle? # the new vial
function base:EjectVial(noForce)
    local vial = self:GetAttachedVial()
    if not vial then
        return nil
    end

    local crush = vial:GetGraphParameter("bCrush") == true
    local health = 1-vial:GetGraphParameter("flHealCycle")

    -- vial:ClearParent()
    local keys = {
        class = vial:GetClassname(),
        targetname = vial:GetName(),
        origin = vial:GetOrigin(),
        angles = vial:GetAngles(),
	    vial_level = health
    }

    vial:ClearParent()

    local newStation = self:ResetStation()
    if newStation then
        local lerp = newStation:GetChild("trigger_lerp_object")
        if lerp then
            lerp:Disable()
            lerp:Delay(function() lerp:Enable() end, 1)
        end

        vial:Kill()

        local newVial = SpawnEntityFromTableSynchronous(keys.class, keys)

        if crush then
            -- Uses custom AnimGraph setup
            newVial:SetGraphParameterBool("bInstantCrush", true)
            newVial:SetGraphParameterFloat("flHealCycle", 1-health)
        end

        if not noForce then
            local speedScale = RandomFloat(0.8, 1.2)
            local baseRotY = 900
            local baseRotZ = RandomFloat(-400, 400)
            newVial:ApplyAbsVelocityImpulse( (newVial:GetForwardVector() * 70 + newVial:GetUpVector() * 50) * speedScale )
            newVial:ApplyLocalAngularVelocityImpulse(Vector(0,baseRotY,baseRotZ) * speedScale)
        end

        return newVial
    end

end

---
---Internal method for powering up the station when a partially used vial in inserted.
---
---@param params IOParams
function base:HandleVialCrushSignal(params)
    local vial = self:GetAttachedVial() or params.activator
    if not vial or vial:GetClassname() ~= "item_hlvr_health_station_vial" then
        return
    end

    -- AnimGraph crush signal needs to be sent so the station will power up
    if vial:GetGraphParameter("bInstantCrush") then
        vial:SetGraphParameterBool("bFireCrushSignal", true)
    end
end

---
---Sets how much the station is open by.
---
---@param amount number # Value [0-1]
function base:SetOpenAmount(amount)
    local charger = self:GetChild("item_health_station_charger")
    if not charger then
        return warn("Could not find charger!")
    end

    charger:EntFire("SetCompletionValue", amount)
end

---
---Internally called when the health vial is removed from the station.
---
---@param params? IOParams
function base:HealthVialRemoved(params)
    -- Kill the invisible proxy vial so we can grab the real vial
    if type(params) == "table" and params.caller then
        params.caller:Kill()
    end

    -- Force the player to grab the new ejected vial
    -- to create a seamless grab transition
    local newVial = self:EjectVial(true)
    if newVial then
        newVial:Grab(Player.LastGrabHand)
    end
end

---
---Internally called when a health vial is inserted into the station.
---
---@param params? IOParams
function base:HealthVialInserted(params)
    -- Delay required because vial isn't parented at this point
    -- Could be avoided by parenting to reservoir directly but this works fine
    self:Delay(function()
        local vial = self:GetAttachedVial() or (type(params) == "table" and params.activator)
        if not vial then
            return
        end

        local charger = self:GetChild("item_health_station_charger")
        if charger and charger:GetCycle() > 0.5 then
            charger:EntFire("SetReturnToCompletionAmount", 1)

            -- Remind the station that it's open
            charger:FireOutput("OnCompletionA_Forward", Player, nil, nil, 0)

            -- Partially used vials don't get re-crushed
            -- Tell the station it's crushed
            self:HandleVialCrushSignal(params)
        end

        -- Grab proxy is needed so the player has something to pickup
        -- Real vial does not trigger any grab outputs
        local proxy = SpawnEntityFromTableSynchronous(vial:GetClassname(), {
            origin = vial:GetOrigin(),
            angles = vial:GetAngles(),
            -- model = vial:GetModelName(),
            targetname = self:GetName() .. "_vial_proxy"
        })
        -- We don't parent to the vial because the player won't
        -- be able to grab it
        proxy:SetParent(vial:GetMoveParent(), "")

        -- Make proxy slightly larger so it's more likely the grab target
        proxy:SetAbsScale(1.01)

        proxy:EntFire("DisablePhyscannonPickup")
        proxy:SetRenderingEnabled(false)
        proxy:RedirectOutput("OnPlayerUse", "HealthVialRemoved", self)
    end, 0)
end

--Used for classes not attached directly to entities
return base