local uevrUtils = require("libs/uevr_utils")
local pawnModule = require("libs/pawn")
local hands = require("libs/hands")

local M = {}

-- State tracking
local isWildcardMontageActive = false
local wildcardPriority = 100 -- Higher priority to override libs/montage.lua and other defaults

-- List of specific montages to include in this logic
local specificMontages = {
    ["AM_fp_topaz_in"] = true,
    ["MG_fp_int_notebook"] = true,
    ["AM_fp_topaz_out"] = true,
    ["MG_fp_dead_body_pickup"] = true,
    ["MG_fp_BedOnBed"] = true
}

-- Helper to check if name contains "AnimMontage" or is in the specific list
local function checkWildcard(montageName)
    if not montageName then return false end
    
    -- Check specific list
    if specificMontages[montageName] then
        return true
    end

    -- Check wildcard pattern
    if string.find(montageName, "AnimMontage") or string.find(montageName, "radio") then
        return true
    end
    
    return false
end

local gameState = require("stalker2.gamestate")

-- 1. Track Montage Changes
uevrUtils.registerMontageChangeCallback(function(montage, montageName)
    local wasActive = isWildcardMontageActive
    isWildcardMontageActive = checkWildcard(montageName)

    if isWildcardMontageActive and not wasActive then
        print("[MontageWildcard] Start: Desired Aim Method -> Game (0)")
        uevr.params.vr.set_mod_value("VR_AimMethod", "0")
    elseif wasActive and not isWildcardMontageActive then
        print("[MontageWildcard] End: Desired Aim Method -> HMD (1)")
        -- Only restore if not in menu (similar to climbing logic)
        if not gameState.inMenu then
            uevr.params.vr.set_mod_value("VR_AimMethod", "1")
        else
            print("[MontageWildcard] Menu active, skipping AimMethod restore")
        end
    end
    
    if isWildcardMontageActive then
        print("[MontageWildcard] Activated for: " .. tostring(montageName))
    end
end)

-- 2. Register Visibility Callbacks with Low Priority

-- Hands: Hidden (true) when active
hands.registerIsHiddenCallback(function()
    if isWildcardMontageActive then
        return true, wildcardPriority
    end
    return nil
end)

-- Pawn Arms: Visible (false) when active
pawnModule.registerIsPawnArmsHiddenCallback(function()
    if isWildcardMontageActive then
        return false, wildcardPriority
    end
    return nil
end)

-- Pawn Arm Bones: Visible (false) when active
pawnModule.registerIsArmBonesHiddenCallback(function()
    if isWildcardMontageActive then
        return false, wildcardPriority
    end
    return nil
end)

return M
