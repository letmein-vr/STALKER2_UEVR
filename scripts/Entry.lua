-- Vector3f.new = function(self, x, y, z)
--     return {x=x, y=y, z=z}
-- end
package.loaded["Config.CONFIG"] = nil -- Force reload config to pick up file changes
Config = require("Config.CONFIG")
print("[UEVR] Reloaded Config. Conversation Threshold: " .. tostring(Config.conversationFOVThreshold))
print("[UEVR] Reloaded Config. Conversation Threshold: " .. tostring(Config.conversationFOVThreshold))
-- OpenXR / VR Params
local vr = uevr.params.vr
local thumbrestLeftHandle = vr.get_action_handle("/actions/default/in/ThumbrestTouchLeft")

local motionControllerActors = require("gestures.motioncontrolleractors")
package.loaded["stalker2.gamestate"] = nil -- Force reload gamestate
local gameState = require("stalker2.gamestate") -- Ensure gameState is available for context
local gestureSetRH = require("presets.presetRH")
local gestureSetLH = require("presets.presetLH")
local gamepadState = require("stalker2.gamepad")
local haptics = require("stalker2.haptics")
require("Base.basic")
local scopeController = require("Base.scope") -- Require the scope controller
local uevrUtils = require("libs/uevr_utils") -- REQUIRED for attachment logic
local hands = require("libs/hands")
local pawnModule = require("libs/pawn")
local inputModule = require("libs/input")
local inputModule = require("libs/input")
local uevrUtils = require("libs/uevr_utils")
require("MontageWildcard") -- Wildcard logic for AnimMontage visibility defaults

gameState:Init()
gamepadState:Reset()

-- Explicit mapping from Weapon Profile Name -> Left Hand Pose Key
-- Keys are normalized to lowercase to ensure case-insensitive matching
local weaponPoseMapping = {
    ["sk_ak74"] = "left_grip_weapon_ak74",
    ["sk_toz34"] = "left_grip_weapon_toz34_shotgun",
    ["sk_aku"] = "left_grip_weapon_aku",
    ["sk_apb"] = "left_grip_weapon_apb_pistol",
    ["sk_bucket0"] = "left_grip_weapon_bucket",
    ["sk_d1200"] = "left_grip_weapon_d12",
    ["sk_dnipro"] = "left_grip_weapon_dnipro",
    ["sk_fora0"] = "left_grip_weapon_fora",
    ["sk_gp37"] = "left_grip_weapon_gp37",
    ["sk_grim0"] = "left_grip_weapon_grim",
    ["sk_gvi"] = "left_grip_weapon_gvintar",
    ["sk_integ"] = "left_grip_weapon_integral",
    ["sk_kharod000"] = "left_grip_weapon_kharod",
    ["sk_lav"] = "left_grip_weapon_lavina",
    ["sk_m1000"] = "left_grip_weapon_m10",
    ["sk_m160"] = "left_grip_weapon_m16",
    ["sk_m701"] = "left_grip_weapon_m701",
    ["sk_m86000"] = "left_grip_weapon_m860",
    ["sk_mar"] = "left_grip_weapon_mark",
    ["sk_obrez"] = "left_grip_weapon_topaz_sawnoff_shotgun",
    ["sk_pkp00000"] = "left_grip_weapon_pkp_lmg",
    ["sk_pm"] = "left_grip_weapon_pm_pistol",
    ["sk_ram2"] = "left_grip_weapon_ram2",
    ["sk_rhino00000"] = "left_grip_weapon_rhino",
    ["sk_spsa00"] = "left_grip_weapon_spsa_shotgun",
    ["sk_svm"] = "left_grip_weapon_svdm",
    ["sk_svu"] = "left_grip_weapon_svu",
    ["sk_udp"] = "left_grip_weapon_udp_pistol",
    ["sk_vip"] = "left_grip_weapon_viper",
    ["sk_zubr0"] = "left_grip_weapon_zubr",
    
    -- Explicitly NIL for standard grip weapons
    ["sk_f1"] = "nil",
    ["sk_rgd5"] = "nil",
    ["sk_bolt"] = "nil",
    ["sk_gauss"] = "nil",
    ["sk_knife"] = "nil",
    ["sk_rpg7"] = "nil",
}

-- Load specific hand poses from JSON
local specificHandPoses = require("data.hand_poses")
if specificHandPoses then
    print("[HandPose] Loaded specific hand poses from explicit Lua module.")
    
    -- Inject missing index finger poses as per user request (Fixes finger sticking out)
    local indexFingerOverrides = {
        ["jnt_l_hand_index_01"] = {-10.1251, 28.18, 7.5277},
        ["jnt_l_hand_index_02"] = {0.0002, 7.6146, 0.0002},
        ["jnt_l_hand_index_03"] = {-0.0007, 72.8081, 0.0001}
    }
    
    for key, weaponData in pairs(specificHandPoses) do
        -- Skip detector poses from this override, they have their own specific finger data
        if not string.find(key, "sk_detector") and weaponData["off"] then
             for boneName, rotation in pairs(indexFingerOverrides) do
                 -- Overwrite or add to ensure the finger curves correctly
                 weaponData["off"][boneName] = rotation
             end
        end
    end
else
    print("[HandPose] ERROR: Failed to require data.hand_poses!")
end

-- Helper to find specific hand pose for a weapon
local function getSpecificHandPose(weaponName, debug)
    if not specificHandPoses or not weaponName then return nil end
    local cleanName = string.lower(weaponName)
    
    if debug then
        print("[HandPose] Attempting to match normalized weapon: '" .. cleanName .. "'")
    end

    -- 1. Try Explicit Mapping First
    local mappedKey = weaponPoseMapping[cleanName]
    if mappedKey then
        if mappedKey == "nil" then
            if debug then print("[HandPose] Explicit mapping says NIL for this weapon.") end
            return nil
        end
        
        if specificHandPoses[mappedKey] then
             if debug then print("[HandPose] FOUND EXPLICIT MAPPED KEY: " .. mappedKey) end
             return specificHandPoses[mappedKey]["off"]
        else
             if debug then print("[HandPose] ERROR: Key found in mapping ("..mappedKey..") but NOT in existing JSON poses!") end
        end
    end

    -- 2. Fallback: Intelligent Matching (Substrings)
    -- Strip common prefixes/suffixes to get core name

    -- 2. Fallback: Iterate and find substring match
    for key, data in pairs(specificHandPoses) do
        local matchName = key:gsub("left_grip_weapon_", "")
        
        -- Check 1: Does weapon name contain key part? (e.g. Weapon 'Item_AK74' contains 'ak74')
        local forwardMatch = (matchName ~= "" and string.find(cleanName, matchName, 1, true))
        
        -- Check 2: Does key part contain weapon name? (e.g. Key 'toz34_shotgun' contains Weapon 'toz34')
        local reverseMatch = (matchName ~= "" and string.find(matchName, cleanName, 1, true))

        if forwardMatch or reverseMatch then
            if debug then
                local method = forwardMatch and "FORWARD" or "REVERSE"
                print("[HandPose] FOUND " .. method .. " MATCH! Key: " .. key .. " matches '" .. matchName .. "' vs '" .. cleanName .. "'")
            end
            return data["off"] -- Return the 'off' pose
        end
    end
    
    if debug then
        print("[HandPose] NO MATCH FOUND for: '" .. cleanName .. "'")
    end
    return nil
end

-- Right Hand Pose Logic
local rightWeaponPoseMapping = {
    ["sk_knife"] = "right_grip_knife",
    ["sk_bolt"] = "right_grip_bolt",
    ["sk_f1"] = "right_grip_grenade",
    ["sk_rgd5"] = "right_grip_grenade",
    ["sk_grenade"] = "right_grip_grenade", -- Generic guess
    ["none"] = "right_open_hand"
}

local function getSpecificRightHandPose(weaponName)
    if not specificHandPoses then return nil end
    
    -- Case 1: Bare Hands (nil weapon)
    if not weaponName then
        return specificHandPoses["right_open_hand"]["off"]
    end
    
    local cleanName = string.lower(weaponName)
    local mappedKey = rightWeaponPoseMapping[cleanName]
    
    -- Check for explicit substring matches if not mapped
    if not mappedKey then
        if string.find(cleanName, "grenade") then mappedKey = "right_grip_grenade" end
        if string.find(cleanName, "knife") then mappedKey = "right_grip_knife" end
        if string.find(cleanName, "bolt") then mappedKey = "right_grip_bolt" end
    end

    if mappedKey and specificHandPoses[mappedKey] then
         -- print("[HandPose] Right Hand Override: " .. cleanName .. " -> " .. mappedKey)
         return specificHandPoses[mappedKey]["off"]
    else
         -- print("[HandPose] No Right Hand Override for: " .. cleanName)
    end
    
    return nil
end

local lastConversationState = false
local lastRightHandOverride = false
local cachedRHPose = getSpecificRightHandPose(nil)
local currentPreset = gestureSetRH.StandModeSetRH

local function updateConfig(config)
    haptics.updateHapticFeedback(Config.hapticFeedback)
    if Config.dominantHand == 1 then
        currentPreset = Config.sittingExperience and gestureSetRH.SitmodeSetRH or gestureSetRH.StandModeSetRH
    else
        currentPreset = Config.sittingExperience and gestureSetLH.SitModeSetLH or gestureSetLH.StandModeSetLH
    end
    -- Update scope brightness
    if scopeController then
        scopeController:SetScopeBrightness(config.scopeBrightnessAmplifier)
        scopeController:SetScopePlaneScale(config.cylinderDepth)
        scopeController:UpdateIndoorMode(config.indoor)
    end
end


local lastWeaponMesh = nil
local currentWeaponName = nil
local weaponCheckTimer = 0
local lastSupportHandState = false
local lastTwoHandingState = false
local lastReloadState = false
local lastDetectorState = false
local lastMontageState = false
local lastPlayedMontageName = "None"
local isXButtonHeld = false
local isReloadMontageActive = false  -- Track if reload montage is playing
local isMagazineMontageActive = false  -- Track if magazine attach/detach montage is playing
local lastMenuState = false  -- Track menu state changes
local simulateReloadHandPosition = false  -- Track reload hand simulation toggle
local simulateTwoHandMode = false -- Track two-handed simulation toggle
local savedAimMethod = nil  -- Store aim method before climbing
local lastClimbingState = false  -- Track climbing state changes
local brightnessDirty = false -- Track if brightness needs saving


-- Global flag to suppress item attachment during consumption montages
-- This allows items to follow pawn's animated hands instead of VR controllers
_G.SuppressItemAttachment = false

-- Helper to check if a montage should trigger attachment
local function shouldAttachForMontage(montageName)
    if not montageName or montageName == "" then return false end
    
    -- Check keyed table (new format)
    if Config.montageAttachmentList[montageName] then return true end
    
    -- Check array list (legacy format compatibility)
    for _, name in ipairs(Config.montageAttachmentList) do
        if name == montageName then return true end
    end
    
    return false
end


-- Consumption montages that need item detachment
local consumptionMontages = {
    ["MG_fp_bandage_use"] = true,
    ["MG_fp_beer_use"] = true,
    ["MG_fp_bh_stash"] = true,
    ["MG_fp_bread_use"] = true,
    ["MG_fp_canned_food_use"] = true,
    ["MG_fp_condensed_milk_use"] = true,
    ["MG_fp_energy_drink_use"] = true,
    ["MG_fp_medkit_common_use"] = true,
    ["MG_fp_pills_common_use"] = true,
    ["MG_fp_sausage_use"] = true,
    ["MG_fp_vodka_use"] = true,
    ["MG_fp_water_use"] = true
}

local function isConsumptionMontage(montageName)
    return montageName and consumptionMontages[montageName] == true
end

-- Helper to check if current weapon is a pistol
local function isPistolWeapon(weaponName)
    if not weaponName then return false end
    
    -- List of pistol weapon identifiers
    local pistols = {
        "SK_pm",
        "SK_apb",
        "SK_udp"
    }
    
    for _, pistolName in ipairs(pistols) do
        if weaponName == pistolName then
            return true
        end
    end
    
    return false
end


local activeWeaponModMontage = nil

-- Variables for Attachment Simulation
local lastCleanAttachmentName = nil
local isSimulatingAttachment = false
local simulatedAttachmentOriginalParent = nil
local simulatedAttachmentOriginalSocket = nil

-- Global variables for attachment simulation
local detectedAttachments = {} 
local selectedAttachmentValues = {} 
local selectedAttachmentIndex = 1
local selectedAttachmentValues = {} 
local selectedAttachmentIndex = 1
local currentSimulationPose = nil
local showAllAttachments = false

local function GetCleanAttachmentName(name)
    if not name then return nil end
    local clean = name
    
    -- Strip Standard UE instance numbers (_123 at end)
    local s_inst = clean:find("_%d+$")
    if s_inst then clean = clean:sub(1, s_inst-1) end
    
    -- Strip GEN_VARIABLE
    local s_gen = clean:find("_GEN_VARIABLE")
    if s_gen then clean = clean:sub(1, s_gen-1) end
    
    -- Strip 32-char Hex Hash (Stalker 2 Upgrades)
    if #clean > 32 then
         local suffix = clean:sub(-32)
         -- Check if suffix is all hex chars (0-9, a-f, A-F)
         if suffix:match("^%x+$") then
              clean = clean:sub(1, -33)
         end
    end
    
    return clean
end

local function scanWeaponAttachments()
    local weapon = gameState:GetEquippedWeapon()
    if not weapon then 
        detectedAttachments = {}
        selectedAttachmentValues = {}
        local selectedAttachmentIndex = 1
        return 
    end
    
    local found = {}
    local values = {}
    
    if weapon.AttachChildren then
        for _, child in ipairs(weapon.AttachChildren) do
            if child and UEVR_UObjectHook.exists(child) then
                local name = child:get_fname():to_string()
                local lowerName = string.lower(name)
                -- Broad filter for relevant attachments
                if showAllAttachments or lowerName:find("silencer") or lowerName:find("sight") or lowerName:find("scope") or lowerName:find("mag") or lowerName:find("suppressor") or lowerName:find("optic") or lowerName:find("b_w_") then
                     table.insert(found, {name=name, mesh=child})
                     table.insert(values, name)
                end
            end
        end
    end
    detectedAttachments = found
    selectedAttachmentValues = values
    
    if selectedAttachmentIndex > #detectedAttachments then selectedAttachmentIndex = 1 end
    if #detectedAttachments > 0 and selectedAttachmentIndex == 0 then selectedAttachmentIndex = 1 end
end

local function toggleAttachmentSimulation(enable)
    local pawn = gameState:GetLocalPawn()
    if not pawn then 
        isSimulatingAttachment = false
        return 
    end
    
    local leftHand = hands.getHandComponent(0)
    if not leftHand then 
        print("[Simulate] Could not find Left Hand Component")
        isSimulatingAttachment = false
        return 
    end
    
    if enable then
        -- Ensure we have up-to-date attachments
        if #detectedAttachments == 0 then scanWeaponAttachments() end
        
        if #detectedAttachments == 0 then
            print("[Simulate] No attachments found on weapon.")
            isSimulatingAttachment = false
            return
        end
        
        local targetData = detectedAttachments[selectedAttachmentIndex]
        if not targetData then
             print("[Simulate] Invalid attachment selection.")
             isSimulatingAttachment = false
             return
        end

        local targetMesh = targetData.mesh
        local targetName = targetData.name

        if targetMesh and UEVR_UObjectHook.exists(targetMesh) then
            simulatedAttachmentOriginalParent = targetMesh.AttachParent
            local socketName = targetMesh.AttachSocketName
            simulatedAttachmentOriginalSocket = socketName and socketName:to_string() or "None"
            
            print("[Simulate] Hijacking attachment: " .. targetName .. " from " .. simulatedAttachmentOriginalSocket)
            
            targetMesh:DetachFromParent(true, true)
            targetMesh:K2_AttachToComponent(leftHand, uevrUtils.fname_from_string("None"), 2, true) 
            
            attachedModMesh = targetMesh
            isSimulatingAttachment = true
            
            -- Setup Profile Name
            local cleanName = GetCleanAttachmentName(targetName)
            
            -- Store clean name for profile lookup
            lastCleanAttachmentName = cleanName
            currentAttachmentName = cleanName

            
            -- Determine and Set Hand Pose
            local weapon = gameState:GetEquippedWeapon()
            local weaponName = weapon and weapon:get_fname():to_string()
            currentSimulationPose = getSpecificHandPose(weaponName)
            
            if currentSimulationPose then
                hands.setHandPose(0, currentSimulationPose)
            else
                hands.setHoldingAttachment(0, true)
            end
        else
             print("[Simulate] Target mesh invalid.")
             isSimulatingAttachment = false
        end
    else
        -- Restore
        if attachedModMesh and simulatedAttachmentOriginalParent and UEVR_UObjectHook.exists(attachedModMesh) then
             print("[Simulate] Restoring attachment to: " .. simulatedAttachmentOriginalSocket)
             
             attachedModMesh:DetachFromParent(true, true)
             attachedModMesh:K2_AttachToComponent(simulatedAttachmentOriginalParent, uevrUtils.fname_from_string(simulatedAttachmentOriginalSocket), 2, true)
        end
        
        -- Always cleanup state
        attachedModMesh = nil
        currentAttachmentName = nil 
        isSimulatingAttachment = false
        simulatedAttachmentOriginalParent = nil
        simulatedAttachmentOriginalSocket = nil
        currentSimulationPose = nil
        
        -- Release Grip pose
        hands.setHoldingAttachment(0, false)
    end
end

-- Montage change callback
uevrUtils.registerMontageChangeCallback(function(montage, montageName)
    if montageName and montageName ~= "" then
        lastPlayedMontageName = montageName
    end

    -- Check if this is a reload montage
    if montageName and string.lower(montageName):find("reload") then
        isReloadMontageActive = true
        print("Reload montage detected: " .. montageName)
    else
        isReloadMontageActive = false
    end
    
    -- Check if this is a magazine attach/detach montage
    if montageName and montageName:find("_mag_") and (montageName:find("_attach") or montageName:find("_detach")) then
        isMagazineMontageActive = true
        print("Magazine montage detected: " .. montageName)
    else
        isMagazineMontageActive = false
    end

    -- Check for weapon modification montages (silencer, sight)
    if montageName and (string.lower(montageName):find("silencer") or string.lower(montageName):find("sight")) then
        isWeaponModMontageActive = true
        gameState.isWeaponModMontageActive = true
        activeWeaponModMontage = montage -- Capture montage object
        print("Weapon Mod montage detected: " .. montageName)
    else
        isWeaponModMontageActive = false
        gameState.isWeaponModMontageActive = false
        activeWeaponModMontage = nil
    end

    -- Handle consumption montages - suppress item attachment so items follow pawn animation
    if isConsumptionMontage(montageName) then
        if not _G.SuppressItemAttachment then
            print("[Consumption] Montage started: " .. montageName .. " - Suppressing item attachment")
            _G.SuppressItemAttachment = true
        end
    else
        -- Not a consumption montage - allow item attachment
        if _G.SuppressItemAttachment then
            print("[Consumption] Montage ended - Re-enabling item attachment")
            _G.SuppressItemAttachment = false
        end
    end

    if shouldAttachForMontage(montageName) then
        -- print("Montage attached: " .. montageName)
        gameState.isMontageAttached = true
    else
        -- Only clear if we were attached? Or just always clear if not a matching montage?
        -- Assuming any other montage (or stopping) means we should detach 
        -- UNLESS multiple layers are playing? For simplicity, if the MAIN montage changes to something else, we detach.
        -- We might need a more robust check if montages overlap, but for now:
        if gameState.isMontageAttached then
             -- print("Montage detached: " .. tostring(montageName))
             gameState.isMontageAttached = false
        end
    end
end)

-- Register callbacks to control hand/arm visibility during climbing
-- Hide VR hands when climbing
hands.registerIsHiddenCallback(function()
    if gameState.isClimbing then
        return true, 10  -- Hide hands, high priority
    end
    return nil, 0  -- Default behavior
end)

-- Show pawn arms when climbing
pawnModule.registerIsPawnArmsHiddenCallback(function()
    if gameState.isClimbing then
        return false, 10  -- Show pawn arms, high priority
    end
    return nil, 0  -- Default behavior
end)

uevr.sdk.callbacks.on_pre_engine_tick(
    function(engine, delta)
        if gameState:IsLevelChanged(engine) then
            print("Level changed, resetting game state and motion controllers")
            currentPreset:Reset()
            motionControllerActors:Reset() -- Reset the motion controller actors
            gamepadState:Reset()
        else
            gameState:Update()
            motionControllerActors:Update(engine)
            
            -- Handle aim method switching for menus
            local currentMenuState = gameState.inMenu or gameState.isInventoryPDA
            if currentMenuState ~= lastMenuState then
                if currentMenuState then
                    -- Entering menu - switch to Game aim for fixed UI
                    uevr.params.vr.set_mod_value("VR_AimMethod", "0")  -- Game aim (fixed UI)
                    uevr.params.vr.set_mod_value("UI_FollowView", "false")  -- Game aim (fixed UI)
                    print("Menu opened - switched to Game aim method (0)")
                else
                    -- Exiting menu - restore to HMD aim for gameplay
                    uevr.params.vr.set_mod_value("VR_AimMethod", "1")  -- HMD aim
                    uevr.params.vr.set_mod_value("UI_FollowView", "true")  -- Game aim (fixed UI)
                    print("Menu closed - restored to HMD aim method (1)")
                end
                lastMenuState = currentMenuState
            end
            
            -- Handle climbing state - suppress item attachment during ladder climbing
            -- Track state changes for debugging
            -- Handle climbing state - suppress item attachment during ladder climbing
            local currentClimbingState = gameState.isClimbing
            
            -- 1. Handle State Transitions (Event Driven)
            if currentClimbingState ~= lastClimbingState then
                print("[Climbing] State changed: " .. tostring(lastClimbingState) .. " -> " .. tostring(currentClimbingState))
                
                if currentClimbingState then
                    -- Started Climbing
                    if not _G.SuppressItemAttachment then
                         print("[Climbing] Started - Suppressing item attachment")
                         _G.SuppressItemAttachment = true
                    end
                else
                    -- Stopped Climbing
                    print("[Climbing] Ended")
                    
                    -- Restore Item Attachment (unless consuming)
                    if not isConsumptionMontage(lastPlayedMontageName) then
                        print("[Climbing] Re-enabling item attachment")
                        _G.SuppressItemAttachment = false
                    end

                    -- Restore Aim Method (unless in Menu or Conversation)
                    if not currentMenuState and not gameState.isConversation then
                        uevr.params.vr.set_mod_value("VR_AimMethod", "1")  -- HMD aim
                        print("[Climbing] Restored HMD aim method (1)")
                    else
                        print("[Climbing] Skipping aim restore - Menu/Conversation active")
                    end
                end
                lastClimbingState = currentClimbingState
            end
            
            -- 2. Maintain State (Frame Driven)
            if gameState.isClimbing then
                -- Always enforce Game Aim while climbing to prevent overrides
                uevr.params.vr.set_mod_value("VR_AimMethod", "0")
            end

            -- Handle Conversation State (Game Aim for Zoomed FOV)
            local currentConversationState = gameState.isConversation
            if currentConversationState ~= lastConversationState then
                if currentConversationState then
                    print("Conversation/Zoom Detected (" .. tostring(Config.conversationFOVThreshold).." deg) - Switched to Game Aim")
                    uevr.params.vr.set_mod_value("VR_AimMethod", "0")
                else
                    print("Conversation/Zoom Ended - Restoring Aim Method")
                    if not gameState.isClimbing and not currentMenuState then
                        uevr.params.vr.set_mod_value("VR_AimMethod", "1")
                    end
                end
                lastConversationState = currentConversationState
            end
            
            if gameState.isConversation then
                 uevr.params.vr.set_mod_value("VR_AimMethod", "0")
            end
            
            -- Weapon Attachment Logic
            local currentWeaponMesh = gameState:GetEquippedWeapon()
            if currentWeaponMesh ~= lastWeaponMesh then
                -- print("Weapon changed from " .. tostring(lastWeaponMesh) .. " to " .. tostring(currentWeaponMesh)) -- Debug log
                if currentWeaponMesh ~= nil then
                    -- Weapon equipped
                    -- Use Cache to get Name and Scope
                     local wInfo = gameState:GetWeaponCache(currentWeaponMesh)
                     if wInfo then
                        currentWeaponName = wInfo.name
                        -- Pre-fetch scope from cache (optimization)
                        -- We will still check it below for profile loading logic specific to scopes
                     end
                    
                    if currentWeaponName then
                        -- print("Equipped Weapon Identified: " .. tostring(currentWeaponName))
                        
                        -- Load Profile if exists
                        if Config.weaponProfiles[currentWeaponName] then
                            print("Loading saved profile for " .. currentWeaponName)
                            local profile = Config.weaponProfiles[currentWeaponName]
                            if profile.socket then Config.weaponSocketName = profile.socket end
                            if profile.rotation then Config.weaponHandRotation = {profile.rotation[1], profile.rotation[2], profile.rotation[3]} end
                            if profile.location then Config.weaponHandLocation = {profile.location[1], profile.location[2], profile.location[3]} end
                            if profile.reloadSocket then Config.reloadSocketName = profile.reloadSocket end
                            if profile.disableReloadAttachment ~= nil then Config.disableReloadAttachment = profile.disableReloadAttachment else Config.disableReloadAttachment = false end
                            if profile.reloadRotation then Config.reloadHandRotation = {profile.reloadRotation[1], profile.reloadRotation[2], profile.reloadRotation[3]} end
                            if profile.reloadLocation then Config.reloadHandLocation = {profile.reloadLocation[1], profile.reloadLocation[2], profile.reloadLocation[3]} end
                            
                            -- Load Scope Settings
                            -- Priority: Specific Scope Profile -> Global Defaults
                            
                             -- Reset Scope Defaults first
                             Config.cylinderDepth = 0.045
                             Config.scopeDiameter = 0.024
                             Config.scopeMagnifier = 0.85

                            -- Attempt to find attached scope (From Cache)
                            local scopeMesh = wInfo.scope -- Retrieved from cache
                            if scopeMesh then
                                if scopeMesh.SkeletalMesh then
                                    currentScopeName = uevrUtils.getShortName(scopeMesh.SkeletalMesh)
                                elseif scopeMesh.StaticMesh then
                                    currentScopeName = uevrUtils.getShortName(scopeMesh.StaticMesh)
                                else
                                    currentScopeName = uevrUtils.getShortName(scopeMesh)
                                end
                                
                                -- Sanitize cleaning of generated suffixes (e.g. CEA96A1...)
                                if currentScopeName then
                                    -- Strip hex suffix if present (e.g. _CEA96A1C4...)
                                    -- Pattern: starts with underscore or letter, followed by long hex string
                                    local cleanName = currentScopeName:gsub("[_]*%x%x%x%x%x%x%x%x+$", "")
                                    -- If reasonably shorter, use it
                                    if cleanName ~= currentScopeName then
                                        print("Sanitized scope name: " .. currentScopeName .. " -> " .. cleanName)
                                        currentScopeName = cleanName
                                    end
                                end
                                
                                -- If we have a scope name, check for profile
                                if currentScopeName and Config.scopeProfiles[currentScopeName] then
                                    print("Loading Scope Profile for: " .. currentScopeName)
                                    local sProf = Config.scopeProfiles[currentScopeName]
                                    if sProf.scopeOffset then Config.cylinderDepth = sProf.scopeOffset end
                                    if sProf.scopeScale then Config.scopeDiameter = sProf.scopeScale end
                                    if sProf.scopeMagnifier then Config.scopeMagnifier = sProf.scopeMagnifier end
                                    if sProf.scopeBrightness then Config.scopeBrightnessAmplifier = sProf.scopeBrightness else Config.scopeBrightnessAmplifier = 1.0 end
                                else
                                    -- print("No profile for scope: " .. tostring(currentScopeName))
                                end
                            else
                                currentScopeName = nil
                            end

                            -- Force update scope controller immediately to prevent race condition
                            if scopeController then
                                scopeController:SetScopePlaneScale(Config.cylinderDepth)
                            end
                        else
                             print("No profile for " .. currentWeaponName .. ", resetting to defaults")
                             -- Reset to defaults to avoid carry-over from previous weapon
                             Config.weaponSocketName = "S_Hand_R"
                             Config.weaponHandRotation = {0, 0, 0}
                             Config.weaponHandLocation = {0, 0, 0}
                             Config.reloadHandRotation = {-1.5, 0.6, -180.2}
                             Config.reloadHandLocation = {0, 0, 0}
                             Config.reloadSocketName = "jnt_l_hand"
                             Config.disableReloadAttachment = false
                             
                             -- Reset Scope Defaults
                             Config.cylinderDepth = 0.045
                             Config.scopeDiameter = 0.024
                             Config.scopeMagnifier = 0.85
                             Config.scopeBrightnessAmplifier = 1.0
                             currentScopeName = nil
                             
                             -- Force update scope controller
                             if scopeController then
                                 scopeController:SetScopePlaneScale(Config.cylinderDepth)
                             end
                        end
                    else
                        print("Could not identify weapon name, using defaults")
                        currentWeaponName = nil
                        Config.weaponSocketName = "S_Hand_R"
                        Config.weaponHandRotation = {0, 0, 0}
                        Config.weaponHandLocation = {0, 0, 0}
                        Config.reloadHandRotation = {-1.5, 0.6, -180.2}
                        Config.reloadHandLocation = {0, 0, 0}
                        Config.reloadSocketName = "jnt_l_hand"
                        Config.disableReloadAttachment = false
                    end

                    hands.attachHandToMesh(Config.dominantHand, currentWeaponMesh, Config.weaponSocketName, Config.weaponHandRotation, Config.weaponHandLocation)
                else
                    -- Weapon unequipped, attach hand back to controller
                    hands.attachHandToController(Config.dominantHand)
                    currentWeaponName = nil
                end
                lastWeaponMesh = currentWeaponMesh
            end
            
            if not gameState.isInventoryPDA and not gameState.inMenu then
                currentPreset:Update({})
                
                -- X-Button to R-Key mapping
                if XINPUT_GAMEPAD_X then
                    local isXPressed = gamepadState:isButtonPressed(XINPUT_GAMEPAD_X)
                    if isXPressed and not isXButtonHeld then
                        isXButtonHeld = true
                        gameState:SendKeyDown('R')
                    elseif not isXPressed and isXButtonHeld then
                        isXButtonHeld = false
                        gameState:SendKeyUp('R')
                    end
                end

                -- Specialized logic for hand attachment and pose
                local currentMontageState = gameState.isMontageAttached

                -- Climbing Override
                if gameState.isClimbing then
                    currentMontageState = true
                    lastPlayedMontageName = "Ladder"
                end
                local currentDetectorState = gameState.isDetectorEquipped
                local currentSupportHandState = gameState.isReloading or gameState.isTwoHanding or isReloadMontageActive or isMagazineMontageActive or isWeaponModMontageActive
                local currentReloadState = gameState.isReloading or isReloadMontageActive or isMagazineMontageActive or isWeaponModMontageActive
                local currentTwoHandingState = gameState.isTwoHanding

                -- Montage Attachment (Highest Priority, affects BOTH hands)
                if currentMontageState ~= lastMontageState then
                    local pawn = gameState:GetLocalPawn()
                    if pawn and pawn.Mesh then
                        if currentMontageState then
                            -- invalidating last state ensures that when we exit the montage, 
                            -- the check (current ~= last) will typically be true if buttons are held,
                            -- forcing a re-attach to the weapon.
                            lastSupportHandState = false 
                            lastReloadState = false
                            lastTwoHandingState = false
                            lastDetectorState = false

                            -- Determine Offsets
                            local leftRot = {0,0,0}
                            local leftLoc = {0,0,0}
                            local rightRot = {0,0,0}
                            local rightLoc = {0,0,0}
                            
                            -- Load from Config if available
                            local montageConfig = Config.montageAttachmentList[lastPlayedMontageName]
                            local lSocket = "jnt_l_ik_hand"
                            local rSocket = "jnt_r_ik_hand"

                            -- Override for Weapon Mods (Silencer/Sight)
                            if isWeaponModMontageActive then
                                lSocket = "jnt_l_weapon"
                            end

                            if montageConfig then
                                -- Deep copy values to avoid reference issues
                                if montageConfig.left then
                                     if montageConfig.left.rot then leftRot = {table.unpack(montageConfig.left.rot)} end
                                     if montageConfig.left.pos then leftLoc = {table.unpack(montageConfig.left.pos)} end
                                     if montageConfig.left.socket then lSocket = montageConfig.left.socket end
                                end
                                if montageConfig.right then
                                     if montageConfig.right.rot then rightRot = {table.unpack(montageConfig.right.rot)} end
                                     if montageConfig.right.pos then rightLoc = {table.unpack(montageConfig.right.pos)} end
                                     if montageConfig.right.socket then rSocket = montageConfig.right.socket end
                                end
                            end

                            -- Attach BOTH hands to Pawn mesh
                            hands.attachHandToMesh(0, pawn.Mesh, lSocket, leftRot, leftLoc) -- Left Hand
                            hands.attachHandToMesh(1, pawn.Mesh, rSocket, rightRot, rightLoc) -- Right Hand
                            
                            -- Apply Hand Poses (Ladder Specific)
                            if lastPlayedMontageName == "Ladder" then
                                if Config.ladderHandPoseLeft then hands.setHandPose(0, Config.ladderHandPoseLeft) end
                                if Config.ladderHandPoseRight then hands.setHandPose(1, Config.ladderHandPoseRight) end
                            end
                        else
                            -- Detach hands
                            hands.setInitialTransform(0)
                            hands.setInitialTransform(1)
                            hasAttachedModMesh = false -- Reset state on montage exit

                            -- Re-attach Dominant Hand to Weapon if equipped
                            local currentWeaponMesh = gameState:GetEquippedWeapon()
                            if currentWeaponMesh then
                                hands.attachHandToMesh(Config.dominantHand, currentWeaponMesh, Config.weaponSocketName, Config.weaponHandRotation, Config.weaponHandLocation)
                                -- Force 'Holding' state and update animation to ensure grip pose is restored (fixes open hand after climbing)
                                hands.setHoldingAttachment(Config.dominantHand, true)
                                hands.updateAnimationState(Config.dominantHand)
                                
                                -- Non-dominant hand goes to controller (unless support logic catches it)
                                local offHand = 1 - Config.dominantHand
                                hands.attachHandToController(offHand)
                                
                                if isSimulatingAttachment and offHand == 0 then
                                     if currentSimulationPose then
                                         hands.setHandPose(0, currentSimulationPose)
                                     else
                                         hands.setHoldingAttachment(0, true)
                                         hands.updateAnimationState(0)
                                     end
                                end
                            else
                                -- No weapon, both to controllers
                                hands.attachHandToController(0)
                                if isSimulatingAttachment then
                                     if currentSimulationPose then
                                         hands.setHandPose(0, currentSimulationPose)
                                     else
                                         hands.setHoldingAttachment(0, true)
                                         hands.updateAnimationState(0)
                                     end
                                end
                                hands.attachHandToController(1)
                            end
                            
                            -- Right Hand Override Logic (Knife, Bolt, Grenade, Bare Hands)
                            -- Apply customized pose to dominant hand if applicable
                            local rhPose = getSpecificRightHandPose(currentWeaponName)
                            if rhPose then
                                hands.setHandPose(Config.dominantHand, rhPose)
                            end
                        end
                    end
                    lastMontageState = currentMontageState
                end

                -- Continuous Check for Weapon Mod Mesh Attachment
                -- Handles race condition where montage starts before specific mod flag is set
                if isWeaponModMontageActive then
                    if not hasAttachedModMesh then
                        local pawn = gameState:GetLocalPawn()
                        -- print("[Debug] Continuous Check: Searching for Mod Mesh...") 
                        local modMesh = gameState:get_weapon_attachment_mesh(pawn)
                        if modMesh then
                            local leftHandComp = hands.getHandComponent(0) -- 0 is Left Hand
                            if leftHandComp then
                                print("[Debug] Attaching Mod Mesh to Left VR Hand")
                                modMesh:DetachFromParent(true, true)
                                modMesh:K2_AttachToComponent(leftHandComp, uevrUtils.fname_from_string("None"), 2, true) -- SnapToTarget
                                
                                hasAttachedModMesh = true
                                attachedModMesh = modMesh -- Store reference for cleanup
                                
                                -- Load Profile
                                local rawName = modMesh:get_fname():to_string()
                                local cleanName = GetCleanAttachmentName(rawName)
                                
                                currentAttachmentName = cleanName
                                print("[Debug] Loading Profile for Attachment: " .. cleanName)
                                
                                if Config.attachmentProfiles[cleanName] then
                                    print("[Debug] Profile Found! Applying offsets.")
                                    local prof = Config.attachmentProfiles[cleanName]
                                    Config.weaponModMeshOffset = {X=prof.offset.X, Y=prof.offset.Y, Z=prof.offset.Z}
                                    Config.weaponModMeshRotation = {Pitch=prof.rotation.Pitch, Yaw=prof.rotation.Yaw, Roll=prof.rotation.Roll}
                                    if prof.cleanupDelay then
                                        Config.weaponModCleanupDelay = prof.cleanupDelay
                                    end
                                else
                                    print("[Debug] No Profile Found. Resetting offsets.")
                                    Config.weaponModMeshOffset = {X=0.0, Y=0.0, Z=0.0}
                                    Config.weaponModMeshRotation = {Pitch=0.0, Yaw=0.0, Roll=0.0}
                                    Config.weaponModCleanupDelay = 1.0
                                end

                                -- Apply User Configurable Offset/Rotation
                                uevrUtils.set_component_relative_transform(modMesh, Config.weaponModMeshOffset, Config.weaponModMeshRotation)
                            end
                        end
                    elseif attachedModMesh and not isSimulatingAttachment then
                         -- NEW ATTACHMENT DETECTION CLEANUP (with delay)
                         -- The game creates a NEW attachment mesh on the weapon, rather than re-parenting
                         -- We add a delay to let the VR hand animation play out first
                         if UEVR_UObjectHook.exists(attachedModMesh) then
                             local currentWeaponMesh = gameState:GetEquippedWeapon()
                             if currentWeaponMesh and currentWeaponMesh.AttachChildren then
                                 -- Get the clean name pattern we're looking for
                                 local cleanName = currentAttachmentName
                                 
                                 -- Search weapon's children for matching attachment
                                 for _, child in ipairs(currentWeaponMesh.AttachChildren) do
                                     if child and UEVR_UObjectHook.exists(child) then
                                         local childName = child:get_fname():to_string()
                                         -- Check if this child matches our attachment pattern
                                         if cleanName and string.find(childName, cleanName, 1, true) then
                                             -- Check if enough time has passed (0.5 seconds)
                                             if not attachedModMeshTime then
                                                 attachedModMeshTime = os.clock()
                                             end
                                             
                                             local elapsed = os.clock() - attachedModMeshTime
                                             if elapsed >= Config.weaponModCleanupDelay then
                                                 print("[Debug] Found new attachment on weapon: " .. childName)
                                                 print("[Debug] Cleaning up VR hand duplicate (after " .. string.format("%.2f", elapsed) .. "s)")
                                                 
                                                 -- Destroy the duplicate mesh attached to VR hand
                                                 if attachedModMesh.K2_DestroyComponent then
                                                     attachedModMesh:K2_DestroyComponent(attachedModMesh)
                                                 else
                                                     attachedModMesh:DetachFromParent(true, true)
                                                     attachedModMesh:SetHiddenInGame(true, true)
                                                 end
                                                 
                                                 -- Save the name for simulation before clearing
                                                 lastCleanAttachmentName = currentAttachmentName
                                                 
                                                 attachedModMesh = nil
                                                 hasAttachedModMesh = false
                                                 currentAttachmentName = nil
                                                 attachedModMeshTime = nil
                                             end
                                             break
                                         end
                                     end
                                 end
                             end
                         else
                             -- Mesh no longer exists, clean up reference
                             attachedModMesh = nil
                             hasAttachedModMesh = false
                             currentAttachmentName = nil
                             attachedModMeshTime = nil
                         end
                    end
                elseif hasAttachedModMesh then
                     -- Cleanup: Montage ended, but flag is still true. Destroy the mesh!
                     -- print("[Debug] Weapon Mod Montage Ended - Cleaning up Mod Mesh")
                     if attachedModMesh then
                         if UEVR_UObjectHook.exists(attachedModMesh) then 
                             -- Attempt to destroy the component to remove the floating copy
                             -- If K2_DestroyComponent is available (standard UE function)
                             if attachedModMesh.K2_DestroyComponent then
                                 attachedModMesh:K2_DestroyComponent(attachedModMesh)
                             else
                                 -- Fallback: Detach and Hide
                                 attachedModMesh:DetachFromParent(true, true)
                                 attachedModMesh:SetHiddenInGame(true, true)
                             end
                         end
                         attachedModMesh = nil
                     end
                     hasAttachedModMesh = false
                end

                -- If Montage is active, skip other hand logic to prevent fighting
                if not currentMontageState then
                    if currentSupportHandState ~= lastSupportHandState or 
                       currentReloadState ~= lastReloadState or 
                       currentTwoHandingState ~= lastTwoHandingState or
                       currentDetectorState ~= lastDetectorState or
                       currentWeaponName ~= lastWeaponName or
                       lastMontageState then -- Re-evaluate if we just exited a montage

                        -- Cache the pose update when weapon changes (or state refreshes)
                        if currentWeaponName ~= lastWeaponName or lastMontageState then
                             cachedRHPose = getSpecificRightHandPose(currentWeaponName)
                        end

                        
                        local weaponMesh = gameState:GetEquippedWeapon()
                        local supportHand = 1 - Config.dominantHand
                        if currentWeaponName ~= lastWeaponName then
                            -- print("[HandPose] Weapon Name Changed: '" .. tostring(lastWeaponName) .. "' -> '" .. tostring(currentWeaponName) .. "'")
                        end

                        if currentSupportHandState or currentDetectorState then
                            -- Attachment logic (Weapon only)
                            if (currentSupportHandState and currentSupportHandState ~= lastSupportHandState) or (currentTwoHandingState and currentWeaponName ~= lastWeaponName) then
                                if weaponMesh then
                                    if not Config.disableReloadAttachment then
                                        hands.attachHandToMesh(supportHand, weaponMesh, Config.reloadSocketName or "jnt_l_hand", Config.reloadHandRotation, Config.reloadHandLocation)
                                    else
                                        -- If disabled, ensure we are on controller (detach from gun if needed)
                                        hands.attachHandToController(supportHand)
                                        -- hands.setInitialTransform(supportHand) -- Optional: Reset offsets if needed
                                    end
                                end

                                -- Debug Pose Matching on State Start
                                if currentTwoHandingState and currentWeaponName then
                                    -- getSpecificHandPose(currentWeaponName, true)
                                end
                            end
                            
                            -- Return to controller logic (If detector is just active without reload/two-handing)
                            if not currentSupportHandState and currentDetectorState then
                                 hands.attachHandToController(supportHand)
                            end
                        else
                            -- Detach handlers if we just stopped using support/detector
                            local supportHand = 1 - Config.dominantHand
                            hands.attachHandToController(supportHand)
                            hands.setInitialTransform(supportHand)
                        end
                        
                        lastSupportHandState = currentSupportHandState
                        lastReloadState = currentReloadState
                        lastTwoHandingState = currentTwoHandingState
                        lastDetectorState = currentDetectorState
                        lastWeaponName = currentWeaponName
                    end

                    -- FORCE RIGHT HAND POSE OVERRIDE
                    -- Run this every frame to ensure the correct grip is applied for specific items
                    -- Use cached value for performance (Updated in weapon change block above)
                    if cachedRHPose then
                        hands.setHandPose(Config.dominantHand, cachedRHPose)
                        lastRightHandOverride = true
                    elseif lastRightHandOverride then
                        -- Released Override (Switched back to gun) -> Force Refresh of Default Pose
                        if currentWeaponName then
                             -- Re-trigger standard attachment logic for the weapon to apply correct pose
                             hands.updateAnimationState(Config.dominantHand)
                        else
                             -- If no weapon, standard update should handle it, but we force it just in case
                             hands.updateAnimationState(Config.dominantHand)
                        end
                        lastRightHandOverride = false
                    end
                    
                    -- Pose Logic (Run every frame to ensure persistence)
                    if currentSupportHandState or currentDetectorState then
                         local supportHand = 1 - Config.dominantHand
                         
                         if currentDetectorState then
                             if not Config.disableDetectorPose then
                                 local detPose = nil
                                 if _G.DetectorSystem then
                                     local detName = _G.DetectorSystem.GetCurrentDetectorName()
                                     if detName and specificHandPoses[detName] then
                                         detPose = specificHandPoses[detName]["off"]
                                     end
                                 end
                                 
                                 if detPose then
                                     hands.setHandPose(supportHand, detPose)
                                 else
                                     hands.setHandPose(supportHand, Config.detectorHandPose)
                                 end
                             end
                         elseif currentReloadState then
                             hands.setHandPose(supportHand, Config.reloadHandPose)
                         elseif currentTwoHandingState then
                             -- Try to get weapon-specific pose
                             local specificPose = getSpecificHandPose(currentWeaponName)
                             if specificPose then
                                 hands.setHandPose(supportHand, specificPose)
                             else
                                 -- Fallback: Use rifle pose for non-pistols, pistol pose for pistols
                                 -- print("[HandPose] FALLBACK TRIGGERED for: " .. tostring(currentWeaponName))
                                 if isPistolWeapon(currentWeaponName) then
                                     hands.setHandPose(supportHand, Config.twoHandedHandPose)
                                 else
                                     hands.setHandPose(supportHand, Config.twoHandedRifleHandPose)
                                 end
                             end
                         else
                             hands.setInitialTransform(supportHand)
                         end
                    end
            end
        end
    end
end
)

-- Helper to save current settings to profile
local function saveWeaponProfile()
    if currentWeaponName then
        if not Config.weaponProfiles[currentWeaponName] then Config.weaponProfiles[currentWeaponName] = {} end
        local profile = Config.weaponProfiles[currentWeaponName]
        profile.socket = Config.weaponSocketName
        profile.rotation = {Config.weaponHandRotation[1], Config.weaponHandRotation[2], Config.weaponHandRotation[3]}
        profile.location = {Config.weaponHandLocation[1], Config.weaponHandLocation[2], Config.weaponHandLocation[3]}
        profile.reloadSocket = Config.reloadSocketName
        profile.disableReloadAttachment = Config.disableReloadAttachment
        profile.reloadRotation = {Config.reloadHandRotation[1], Config.reloadHandRotation[2], Config.reloadHandRotation[3]}
        profile.reloadLocation = {Config.reloadHandLocation[1], Config.reloadHandLocation[2], Config.reloadHandLocation[3]}
        
        -- Save Scope Settings (Per Scope if available, otherwise just global config update - handled by Config:Save())
        if currentScopeName then
            print("Saving Scope Profile for: " .. currentScopeName)
            if not Config.scopeProfiles[currentScopeName] then Config.scopeProfiles[currentScopeName] = {} end
            local scopeProf = Config.scopeProfiles[currentScopeName]
            scopeProf.scopeOffset = Config.cylinderDepth
            scopeProf.scopeScale = Config.scopeDiameter
            scopeProf.scopeMagnifier = Config.scopeMagnifier
            scopeProf.scopeBrightness = Config.scopeBrightnessAmplifier
        end
        
        Config:save()
    end
end

uevr.sdk.callbacks.on_xinput_get_state(
    function(retval, user_index, state)
        if not gameState.isInventoryPDA and not gameState.inMenu then
            -- Scope Brightness Control
            -- Require Left Controller Thumb Rest Touch
            -- Using OpenXR action handle
            local isModifierPressed = false
            if vr.is_using_controllers() and vr.is_openxr() then
                 local leftControllerSource = vr.get_left_joystick_source()
                 if vr.is_action_active(thumbrestLeftHandle, leftControllerSource) then
                     isModifierPressed = true
                 end
            end
            
            if gameState:is_scope_active(gameState:GetLocalPawn()) and isModifierPressed then
                local ry = state.Gamepad.sThumbRY
                if math.abs(ry) > 4000 then
                     -- Adjust Brightness
                     local delta = (ry / 32768.0) * 0.02  -- Reduced from 0.05 for less sensitivity
                     Config.scopeBrightnessAmplifier = math.max(0.0, math.min(3.0, Config.scopeBrightnessAmplifier + delta))
                     
                     -- Apply immediately
                     if scopeController then
                         scopeController:SetScopeBrightness(Config.scopeBrightnessAmplifier)
                     end
                     
                     -- Consume Input (Prevent looking up/down)
                     state.Gamepad.sThumbRY = 0
                     
                     -- Note: ThumbRest is an OpenXR action, not a button bit, so we don't need to mask it out from wButtons.
                     -- However, checking it might be redundant if the user mapped it to something else, but typically it is independent.
                     
                     brightnessDirty = true
                end
            elseif brightnessDirty then
                 -- Stick/Button released, save changes
                 saveWeaponProfile()
                 brightnessDirty = false
                 print("Scope Brightness Saved: " .. tostring(Config.scopeBrightnessAmplifier))
            end

            gamepadState:Update(state)
        end
    end
)

uevr.sdk.callbacks.on_script_reset(function()
    print("Resetting")
    currentPreset:Reset()
    gameState:Reset() -- Reset the game state to initial conditions
    motionControllerActors:Reset() -- Reset the motion controller actors
    gamepadState:Reset()
end)

-- Load config at script init
updateConfig(Config)

-- Helper to save current settings to profile


-- Config UI as a collapsing header
uevr.sdk.callbacks.on_draw_ui(function()
    if not imgui.collapsing_header("VR Mod Config") then return end

    local changed = false

    -- Dominant Hand
    local handOptions = {"Left","Right"}
    local handIdx = Config.dominantHand + 1
    local handChanged, newHand = imgui.combo("Dominant Hand", handIdx, handOptions)
    if handChanged then
        Config.dominantHand = newHand - 1
        changed = true
    end
    
    if currentWeaponName then
        imgui.text("Current Weapon: " .. currentWeaponName)
    else
        imgui.text("Current Weapon: None")
    end

    if lastPlayedMontageName == "None" then
        imgui.text("Last Montage: None (Play an animation to see it here)")
    else
        imgui.text("Last Montage: " .. tostring(lastPlayedMontageName))
    end
    if imgui.button("Copy Montage Name") then
        imgui.set_clipboard_text(lastPlayedMontageName)
    end
    
    if imgui.button("Debug: Scan All Meshes for Montages") then
         local pawn = gameState:GetLocalPawn()
         if pawn then
             print("Scanning Pawn components for active montages...")
             
             if pawn.MovementComponent then
                local mode = pawn.MovementComponent.MovementMode
                print("Movement Mode: " .. tostring(mode))
             end

             local root = pawn.RootComponent
             
             local function scan(comp, depth)
                 if not comp then return end
                 -- Check if SkeletalMeshComponent (simple check via property existence or name)
                 -- Assuming IsA is not easily available, check for AnimScriptInstance
                 if comp.AnimScriptInstance then
                      local animInfo = "None"
                      local montage = comp.AnimScriptInstance:GetCurrentActiveMontage()
                      if montage then
                          animInfo = "Montage: " .. uevrUtils.getShortName(montage)
                          -- Copy to clipboard if it looks interesting
                          if animInfo ~= "None" then imgui.set_clipboard_text(uevrUtils.getShortName(montage)) end
                      else
                          animInfo = "No Active Montage"
                      end
                      
                      local compName = uevrUtils.getShortName(comp)
                      print(string.rep("  ", depth) .. compName .. " -> " .. animInfo)
                 else
                      local compName = uevrUtils.getShortName(comp)
                      if string.find(compName, "Ladder") then
                          print(string.rep("  ", depth) .. "POSSIBLE LADDER COMPONENT: " .. compName)
                      end
                 end

                 -- Debug Climbing Data
                 if comp.AnimScriptInstance then
                     local animInstance = comp.AnimScriptInstance
                     -- AnimInstancePlayer::get_ClimbingData is at 0xc80
                     -- Inside that, bAnimClimbStarted is at 0x0 (bit 0)
                     -- AnimClimbState is at 0x1
                     
                     -- We need to read raw memory. UEVR doesn't expose raw read easily on UObject without sdk property usually.
                     -- BUT, we can try to use Reflection if the property exists by name, OR use API.
                     -- Since we don't have the property mapping in lua usually, checking if we can access it via property name 'ClimbingData'.
                     
                     local climbingData = animInstance["ClimbingData"] -- Try reflection first
                     if climbingData then
                         print(string.rep("  ", depth) .. "  [!] Found ClimbingData via Reflection!")
                         local bClimb = climbingData["bAnimClimbStarted"]
                         local state = climbingData["AnimClimbState"]
                         print(string.rep("  ", depth) .. "  -> IsClimbing: " .. tostring(bClimb) .. " State: " .. tostring(state))
                     else
                        -- If reflection fails, we might need a trusted way to access it or just rely on the heuristic for now.
                        -- Actually, let's just print that we found the AnimInstance so the user knows.
                     end
                 end

                 if comp.AttachChildren then
                      for i, child in ipairs(comp.AttachChildren) do
                           scan(child, depth + 1)
                      end
                 end
             end
             
             if root then scan(root, 0) end
             -- Also check the main Mesh directly just in case it's disjoint
             if pawn.Mesh then
                 local meshName = uevrUtils.getShortName(pawn.Mesh)
                 print("Checking Main Mesh: " .. meshName)
                 scan(pawn.Mesh, 0) 
             end
         else
             print("Pawn not found")
         end
    end

    if lastPlayedMontageName ~= "None" then
        local montageData = Config.montageAttachmentList[lastPlayedMontageName]
        local shouldAttach = shouldAttachForMontage(lastPlayedMontageName)
        
        -- Debug check
        imgui.text("Debug: Attached? " .. tostring(shouldAttach) .. " Data? " .. tostring(montageData ~= nil))

        if montageData or shouldAttach then
            if imgui.tree_node("Edit Montage Offsets") then
                -- Ensure data structure exists if it was enabled via list
                if not montageData then
                    montageData = {}
                    Config.montageAttachmentList[lastPlayedMontageName] = montageData
                    -- Remove from array list if present
                    for i, name in ipairs(Config.montageAttachmentList) do
                         if name == lastPlayedMontageName then
                             table.remove(Config.montageAttachmentList, i)
                             break
                         end
                    end
                    changed = true
                end
                
                -- Ensure left/right subtables exist (fix for empty Ladder config)
                if not montageData.left then montageData.left = {pos={0,0,0}, rot={0,0,0}, socket="jnt_l_ik_hand"}; changed=true end
                if not montageData.right then montageData.right = {pos={0,0,0}, rot={0,0,0}, socket="jnt_r_ik_hand"}; changed=true end
                
                -- Helper for vector controls
                local function vec3Control(label, val)
                    local c = false
                    local v1c, v1 = imgui.drag_float(label.." X", val[1], 0.1)
                    if v1c then val[1] = v1; c = true end
                    local v2c, v2 = imgui.drag_float(label.." Y", val[2], 0.1)
                    if v2c then val[2] = v2; c = true end
                    local v3c, v3 = imgui.drag_float(label.." Z", val[3], 0.1)
                    if v3c then val[3] = v3; c = true end
                    return c
                end

                imgui.text("Left Hand Offsets")
                -- Socket input for Left
                local lsChanged, newLS = imgui.input_text("L Socket", montageData.left.socket or "jnt_l_ik_hand")
                if lsChanged and newLS ~= "" then montageData.left.socket = newLS; changed = true end
                
                if vec3Control("L Pos", montageData.left.pos) then changed = true end
                if vec3Control("L Rot", montageData.left.rot) then changed = true end
                
                imgui.separator()
                
                imgui.text("Right Hand Offsets")
                -- Socket input for Right
                local rsChanged, newRS = imgui.input_text("R Socket", montageData.right.socket or "jnt_r_ik_hand")
                if rsChanged and newRS ~= "" then montageData.right.socket = newRS; changed = true end
                
                if vec3Control("R Pos", montageData.right.pos) then changed = true end
                if vec3Control("R Rot", montageData.right.rot) then changed = true end
                
                if changed then
                    -- Force re-attach if currently playing to see changes
                    if gameState.isMontageAttached or gameState.isClimbing then
                         local pawn = gameState:GetLocalPawn()
                         if pawn and pawn.Mesh then
                             local lSock = montageData.left.socket or "jnt_l_ik_hand"
                             local rSock = montageData.right.socket or "jnt_r_ik_hand"
                             hands.attachHandToMesh(0, pawn.Mesh, lSock, montageData.left.rot, montageData.left.pos)
                             hands.attachHandToMesh(1, pawn.Mesh, rSock, montageData.right.rot, montageData.right.pos)
                         end
                    end
                end
                
                imgui.tree_pop()
            end
        else
            if imgui.button("Enable Hand Attachment for this Montage") then
                Config.montageAttachmentList[lastPlayedMontageName] = {
                    left = {pos={0,0,0}, rot={0,0,0}, socket="jnt_l_ik_hand"},
                    right = {pos={0,0,0}, rot={0,0,0}, socket="jnt_r_ik_hand"}
                }
                changed = true
            end
        end
    end

    -- Weapon Socket Name
    local socketChanged, newSocket = imgui.input_text("Weapon Attach Socket", Config.weaponSocketName)
    if socketChanged then
        Config.weaponSocketName = newSocket
        changed = true
        saveWeaponProfile()
        -- Force re-attach if weapon is currently held
        local currentWeaponMesh = gameState:GetEquippedWeapon()
        if currentWeaponMesh ~= nil then
             hands.attachHandToMesh(Config.dominantHand, currentWeaponMesh, Config.weaponSocketName, Config.weaponHandRotation)
        end
    end

    -- Weapon Hand Rotation
    local rotChanged = false
    local rPitchChanged, newRPitch = imgui.drag_float("Hand Pitch", Config.weaponHandRotation[1], 0.1)
    if rPitchChanged then Config.weaponHandRotation[1] = newRPitch; rotChanged = true end
    
    local rYawChanged, newRYaw = imgui.drag_float("Hand Yaw", Config.weaponHandRotation[2], 0.1)
    if rYawChanged then Config.weaponHandRotation[2] = newRYaw; rotChanged = true end
    
    local rRollChanged, newRRoll = imgui.drag_float("Hand Roll", Config.weaponHandRotation[3], 0.1)
    if rRollChanged then Config.weaponHandRotation[3] = newRRoll; rotChanged = true end
    
    if rotChanged then
        changed = true
        saveWeaponProfile()
        local currentWeaponMesh = gameState:GetEquippedWeapon()
        if currentWeaponMesh ~= nil then
             hands.attachHandToMesh(Config.dominantHand, currentWeaponMesh, Config.weaponSocketName, Config.weaponHandRotation, Config.weaponHandLocation)
        end
    end
    
    -- Weapon Hand Location
    local locChanged = false
    local lXChanged, newLX = imgui.drag_float("Hand Loc X", Config.weaponHandLocation[1], 0.1)
    if lXChanged then Config.weaponHandLocation[1] = newLX; locChanged = true end
    
    local lYChanged, newLY = imgui.drag_float("Hand Loc Y", Config.weaponHandLocation[2], 0.1)
    if lYChanged then Config.weaponHandLocation[2] = newLY; locChanged = true end
    
    local lZChanged, newLZ = imgui.drag_float("Hand Loc Z", Config.weaponHandLocation[3], 0.1)
    if lZChanged then Config.weaponHandLocation[3] = newLZ; locChanged = true end
    
    if locChanged then
        changed = true
        saveWeaponProfile()
        local currentWeaponMesh = gameState:GetEquippedWeapon()
        if currentWeaponMesh ~= nil then
             hands.attachHandToMesh(Config.dominantHand, currentWeaponMesh, Config.weaponSocketName, Config.weaponHandRotation, Config.weaponHandLocation)
        end
    end

    imgui.separator()
    imgui.text("Reload Hand Offsets (Non-Dominant)")

    -- Reload Socket Name
    local relSocketChanged, newRelSocket = imgui.input_text("Reload Attach Socket", Config.reloadSocketName or "jnt_l_hand")
    if relSocketChanged then
        Config.reloadSocketName = newRelSocket
        changed = true
        saveWeaponProfile()
    end

    -- Disable Reload Attachment Toggle
    local disableRelChanged, newDisableRel = imgui.checkbox("Disable Left Hand Attachment", Config.disableReloadAttachment)
    if disableRelChanged then
        Config.disableReloadAttachment = newDisableRel
        changed = true
        saveWeaponProfile()
    end
    
    -- Reload Hand Rotation
    local reloadRotChanged = false
    local relPitchChanged, newRelPitch = imgui.drag_float("Reload Pitch", Config.reloadHandRotation[1], 0.1)
    if relPitchChanged then Config.reloadHandRotation[1] = newRelPitch; reloadRotChanged = true end
    
    local relYawChanged, newRelYaw = imgui.drag_float("Reload Yaw", Config.reloadHandRotation[2], 0.1)
    if relYawChanged then Config.reloadHandRotation[2] = newRelYaw; reloadRotChanged = true end
    
    local relRollChanged, newRelRoll = imgui.drag_float("Reload Roll", Config.reloadHandRotation[3], 0.1)
    if relRollChanged then Config.reloadHandRotation[3] = newRelRoll; reloadRotChanged = true end
    
    if reloadRotChanged then
        changed = true
        saveWeaponProfile()
        -- Note: We don't force attach here because reloads are gesture-triggered
    end

    -- Reload Hand Location
    local reloadLocChanged = false
    local relXChanged, newRelX = imgui.drag_float("Reload Loc X", Config.reloadHandLocation[1], 0.1)
    if relXChanged then Config.reloadHandLocation[1] = newRelX; reloadLocChanged = true end
    
    local relYChanged, newRelY = imgui.drag_float("Reload Loc Y", Config.reloadHandLocation[2], 0.1)
    if relYChanged then Config.reloadHandLocation[2] = newRelY; reloadLocChanged = true end
    
    local relZChanged, newRelZ = imgui.drag_float("Reload Loc Z", Config.reloadHandLocation[3], 0.1)
    if relZChanged then Config.reloadHandLocation[3] = newRelZ; reloadLocChanged = true end
    
    if reloadLocChanged then
        changed = true
        saveWeaponProfile()
    end

    -- Weapon Mod Mesh Alignment UI (Silencer/Sight)
    imgui.separator()
    imgui.text("Weapon Mod Alignment (Silencer/Sight)")
    if currentAttachmentName then
         imgui.text("Editing Profile: " .. currentAttachmentName)
    else
         imgui.text("No Attachment Detected")
    end
    
    -- Attachment Scanner UI
    if imgui.button("Scan for Attachments") then
        scanWeaponAttachments()
    end
    imgui.same_line()
    local showAllChanged, newShowAll = imgui.checkbox("Show All", showAllAttachments)
    if showAllChanged then 
        showAllAttachments = newShowAll 
        scanWeaponAttachments() 
    end
    
    if #detectedAttachments > 0 then
        local changed, newIndex = imgui.combo("Select Attachment", selectedAttachmentIndex, selectedAttachmentValues)
        if changed then selectedAttachmentIndex = newIndex end
        
        local currentMeshName = selectedAttachmentValues[selectedAttachmentIndex]
        
        local simChanged, newSim = imgui.checkbox("Simulate Attachment Position", isSimulatingAttachment)
        if simChanged then
            toggleAttachmentSimulation(newSim)
        end
        if isSimulatingAttachment then
             imgui.same_line()
             imgui.text_colored(0, 1, 0, 1, "(ACTIVE: " .. tostring(currentMeshName) .. ")")
        end
    else
        imgui.text_colored(1, 1, 0, 1, "No Attachments Detected (Click Scan)")
        if isSimulatingAttachment and imgui.button("Force Disable Simulation") then
             toggleAttachmentSimulation(false)
        end
    end
    
    local modOffsetChanged = false
    local modRotChanged = false
    
    -- Mod Offset
    local modXChanged, newModX = imgui.drag_float("Mod Offset X", Config.weaponModMeshOffset.X, 0.1)
    if modXChanged then Config.weaponModMeshOffset.X = newModX; modOffsetChanged = true end
    
    local modYChanged, newModY = imgui.drag_float("Mod Offset Y", Config.weaponModMeshOffset.Y, 0.1)
    if modYChanged then Config.weaponModMeshOffset.Y = newModY; modOffsetChanged = true end
    
    local modZChanged, newModZ = imgui.drag_float("Mod Offset Z", Config.weaponModMeshOffset.Z, 0.1)
    if modZChanged then Config.weaponModMeshOffset.Z = newModZ; modOffsetChanged = true end
    
    -- Mod Rotation
    local modPitchChanged, newModPitch = imgui.drag_float("Mod Pitch", Config.weaponModMeshRotation.Pitch, 0.1)
    if modPitchChanged then Config.weaponModMeshRotation.Pitch = newModPitch; modRotChanged = true end
    
    local modYawChanged, newModYaw = imgui.drag_float("Mod Yaw", Config.weaponModMeshRotation.Yaw, 0.1)
    if modYawChanged then Config.weaponModMeshRotation.Yaw = newModYaw; modRotChanged = true end
    
    local modRollChanged, newModRoll = imgui.drag_float("Mod Roll", Config.weaponModMeshRotation.Roll, 0.1)
    if modRollChanged then Config.weaponModMeshRotation.Roll = newModRoll; modRotChanged = true end
    
    -- Cleanup Delay
    local modDelayChanged, newModDelay = imgui.slider_float("Cleanup Delay (s)", Config.weaponModCleanupDelay, 1.0, 10.0)
    if modDelayChanged then Config.weaponModCleanupDelay = newModDelay; changed = true end
    
    if modOffsetChanged or modRotChanged then
        changed = true
        
        -- Update active mesh immediately if attached
        if attachedModMesh and UEVR_UObjectHook.exists(attachedModMesh) then
             uevrUtils.set_component_relative_transform(attachedModMesh, Config.weaponModMeshOffset, Config.weaponModMeshRotation)
        end
        
        -- Save to Profile (Auto-Save)
        if currentAttachmentName then
            if not Config.attachmentProfiles[currentAttachmentName] then Config.attachmentProfiles[currentAttachmentName] = {} end
            local prof = Config.attachmentProfiles[currentAttachmentName]
            prof.offset = {X = Config.weaponModMeshOffset.X, Y = Config.weaponModMeshOffset.Y, Z = Config.weaponModMeshOffset.Z}
            prof.rotation = {Pitch = Config.weaponModMeshRotation.Pitch, Yaw = Config.weaponModMeshRotation.Yaw, Roll = Config.weaponModMeshRotation.Roll}
            prof.cleanupDelay = Config.weaponModCleanupDelay
            
            Config:save()
            -- print("[Debug] Auto-saved profile for: " .. currentAttachmentName)
        else
            -- If we are adjusting without a tracked attachment (unlikely but possible), maybe just save globally?
            -- For now, we only save if we know WHAT we are saving for.
        end
    end
    
    -- Also save cleanup delay changes to profile
    if modDelayChanged and currentAttachmentName then
        if not Config.attachmentProfiles[currentAttachmentName] then Config.attachmentProfiles[currentAttachmentName] = {} end
        Config.attachmentProfiles[currentAttachmentName].cleanupDelay = Config.weaponModCleanupDelay
        Config:save()
    end
    
    -- Simulate Reload Hand Position Toggle
    local simChanged, newSim = imgui.checkbox("Simulate Reload Hand Position", simulateReloadHandPosition)
    if simChanged then
        simulateReloadHandPosition = newSim
        local supportHand = 1 - Config.dominantHand
        
        if simulateReloadHandPosition then
            -- Enable simulation - attach hand to weapon with reload offsets
            local currentWeaponMesh = gameState:GetEquippedWeapon()
            if currentWeaponMesh ~= nil then
                hands.attachHandToMesh(supportHand, currentWeaponMesh, Config.reloadSocketName or "jnt_l_hand", Config.reloadHandRotation, Config.reloadHandLocation)
                hands.setHandPose(supportHand, Config.reloadHandPose)
            end
        else
            -- Disable simulation - return hand to controller
            hands.attachHandToController(supportHand)
            hands.setInitialTransform(supportHand)
        end
    end

    -- Simulate 2-Handed Mode Toggle
    local sim2HChanged, newSim2H = imgui.checkbox("Simulate 2-Handed Mode", simulateTwoHandMode)
    if sim2HChanged then
        simulateTwoHandMode = newSim2H
        local supportHand = 1 - Config.dominantHand
        
        if simulateTwoHandMode then
             -- Disable Reload Simulation if active to avoid conflict
             if simulateReloadHandPosition then
                 simulateReloadHandPosition = false
             end
             
             -- Enable simulation - attach hand to weapon with reload offsets (standard for 2-hand)
             local currentWeaponMesh = gameState:GetEquippedWeapon()
             if currentWeaponMesh ~= nil then
                 hands.attachHandToMesh(supportHand, currentWeaponMesh, Config.reloadSocketName or "jnt_l_hand", Config.reloadHandRotation, Config.reloadHandLocation)
                 
                 -- Apply Specific Hand Pose
                 local specificPose = getSpecificHandPose(currentWeaponName)
                 if specificPose then
                     hands.setHandPose(supportHand, specificPose)
                 else
                     -- Fallback
                     if isPistolWeapon(currentWeaponName) then
                         hands.setHandPose(supportHand, Config.twoHandedHandPose)
                     else
                         hands.setHandPose(supportHand, Config.twoHandedRifleHandPose)
                     end
                 end
             end
        else
            -- Disable simulation - return hand to controller
            hands.attachHandToController(supportHand)
            hands.setInitialTransform(supportHand)
        end
    end
    
    -- Update simulation if active and values changed
    if (simulateReloadHandPosition or simulateTwoHandMode) and (reloadRotChanged or reloadLocChanged or relSocketChanged) then
        local supportHand = 1 - Config.dominantHand
        local currentWeaponMesh = gameState:GetEquippedWeapon()
        if currentWeaponMesh ~= nil then
             if not Config.disableReloadAttachment then
                 hands.attachHandToMesh(supportHand, currentWeaponMesh, Config.reloadSocketName or "jnt_l_hand", Config.reloadHandRotation, Config.reloadHandLocation)
             else
                 hands.attachHandToController(supportHand)
             end
        end
    end

    -- Sitting Experience
    local sitChanged, newSit = imgui.checkbox("Sitting Experience", Config.sittingExperience)
    if sitChanged then
        Config.sittingExperience = newSit
        changed = true
    end

    -- Haptic Feedback
    local hapticChanged, newHaptic = imgui.checkbox("Haptic Feedback", Config.hapticFeedback)
    if hapticChanged then
        Config.hapticFeedback = newHaptic
        changed = true
    end

    -- Recoil
    local recoilChanged, newRecoil = imgui.checkbox("Recoil", Config.recoil)
    if recoilChanged then
        Config.recoil = newRecoil
        changed = true
    end

    -- Two-Handed Aiming
    local twoHandedChanged, newTwoHanded = imgui.checkbox("Two-Handed Aiming", Config.twoHandedAiming)
    if twoHandedChanged then
        Config.twoHandedAiming = newTwoHanded
        changed = true
    end

    -- Scope Brightness Amplifier
    local brightnessChanged, newBrightness = imgui.slider_float("Scope Brightness", Config.scopeBrightnessAmplifier, 0.0, 3.0)
    if brightnessChanged then
        Config.scopeBrightnessAmplifier = newBrightness
        changed = true
    end

    -- Scope Activation Distance
    local distChanged, newDist = imgui.slider_float("Scope Activation Distance (cm)", Config.scopeActivationDistance, 5.0, 30.0)
    if distChanged then
        Config.scopeActivationDistance = newDist
        changed = true
    end

    -- Virtual Gunstock
    local gunstockChanged, newGunstock = imgui.checkbox("Virtual Gunstock (Debug Not working)", Config.virtualGunstock)
    if gunstockChanged then
        Config.virtualGunstock = newGunstock
        changed = true
    end


    -- Detector Settings
    imgui.separator()
    if _G.DetectorSystem then
        local currentDetName = _G.DetectorSystem.GetCurrentDetectorName()
        if currentDetName then
            imgui.text("Detector Settings (Editing: " .. currentDetName .. ")")
        else
            imgui.text("Detector Settings (No Detector Found)")
        end
        
        local detChanged = false
        
        -- Position
        local detPosXChanged, newDetPosX = imgui.drag_float("Detector Pos X", Config.detectorOffset.X, 0.1)
        if detPosXChanged then Config.detectorOffset.X = newDetPosX; detChanged = true end
        
        local detPosYChanged, newDetPosY = imgui.drag_float("Detector Pos Y", Config.detectorOffset.Y, 0.1)
        if detPosYChanged then Config.detectorOffset.Y = newDetPosY; detChanged = true end
        
        local detPosZChanged, newDetPosZ = imgui.drag_float("Detector Pos Z", Config.detectorOffset.Z, 0.1)
        if detPosZChanged then Config.detectorOffset.Z = newDetPosZ; detChanged = true end
        
        -- Rotation
        local detPitchChanged, newDetPitch = imgui.drag_float("Detector Pitch", Config.detectorRotation.Pitch, 0.5)
        if detPitchChanged then Config.detectorRotation.Pitch = newDetPitch; detChanged = true end
        
        local detYawChanged, newDetYaw = imgui.drag_float("Detector Yaw", Config.detectorRotation.Yaw, 0.5)
        if detYawChanged then Config.detectorRotation.Yaw = newDetYaw; detChanged = true end
        
        local detRollChanged, newDetRoll = imgui.drag_float("Detector Roll", Config.detectorRotation.Roll, 0.5)
        if detRollChanged then Config.detectorRotation.Roll = newDetRoll; detChanged = true end
        
        -- Disable Hand Pose
        local detPoseChanged, newDetPose = imgui.checkbox("Disable Hand Pose Override", Config.disableDetectorPose)
        if detPoseChanged then
             Config.disableDetectorPose = newDetPose
             changed = true
        end
        

        
        if detChanged then
            changed = true
            _G.DetectorSystem.RefreshTransform()
            
            -- Auto-save to profile
            if currentDetName then
                if not Config.detectorProfiles[currentDetName] then Config.detectorProfiles[currentDetName] = {} end
                local prof = Config.detectorProfiles[currentDetName]
                prof.offset = {X = Config.detectorOffset.X, Y = Config.detectorOffset.Y, Z = Config.detectorOffset.Z}
                prof.rotation = {Pitch = Config.detectorRotation.Pitch, Yaw = Config.detectorRotation.Yaw, Roll = Config.detectorRotation.Roll}
                Config:save()
            end
        end
    end

    -- Scope Settings (Per Weapon/Scope)
    imgui.separator()
    if currentScopeName then
        imgui.text("Scope Settings (Editing: " .. currentScopeName .. ")")
    else
        imgui.text("Scope Settings (Default / No Scope Found)")
    end
    
    if currentWeaponName then
        imgui.text("Weapon: " .. currentWeaponName)
    end

    -- Scope Offset (Cylinder Depth)
    local depthChanged, newDepth = imgui.drag_float("Scope Offset (X)", Config.cylinderDepth, 0.001, 0.0, 0.5, "%.3f")
    if depthChanged then
        Config.cylinderDepth = newDepth
        changed = true
        saveWeaponProfile()
        if scopeController then
             scopeController:SetScopePlaneScale(Config.cylinderDepth)
        end
    end

    -- Scope Scale (Diameter)
    local diameterChanged, newDiameter = imgui.drag_float("Scope Scale", Config.scopeDiameter, 0.001, 0.001, 0.1, "%.3f")
    if diameterChanged then
        Config.scopeDiameter = newDiameter
        changed = true
        saveWeaponProfile()
        if scopeController then
             scopeController:SetScopePlaneScale(Config.cylinderDepth) -- This updates both scale and location internally
        end
    end

    -- Scope Magnifier
    local magnifierChanged, newMagnifier = imgui.drag_float("Scope Magnifier", Config.scopeMagnifier, 0.001, 0.0, 2.0, "%.3f")
    if magnifierChanged then
        Config.scopeMagnifier = newMagnifier
        changed = true
        saveWeaponProfile()
        -- Magnifier is updated in update loop automatically via Recalculate_FOV
    end

    -- Gesture Settings
    if imgui.collapsing_header("Gesture Settings") then
        -- Flashlight
        local flashlightChanged, newFlashlight = imgui.checkbox("Flashlight Gesture", Config.gestures.flashlight)
        if flashlightChanged then
            Config.gestures.flashlight = newFlashlight
            changed = true
        end

        -- Primary Weapon
        local primaryWeaponChanged, newPrimaryWeapon = imgui.checkbox("Primary Weapon Gesture", Config.gestures.primaryWeapon)
        if primaryWeaponChanged then
            Config.gestures.primaryWeapon = newPrimaryWeapon
            changed = true
        end

        -- Secondary Weapon
        local secondaryWeaponChanged, newSecondaryWeapon = imgui.checkbox("Secondary Weapon Gesture", Config.gestures.secondaryWeapon)
        if secondaryWeaponChanged then
            Config.gestures.secondaryWeapon = newSecondaryWeapon
            changed = true
        end

        -- Sidearm Weapon
        local sidearmWeaponChanged, newSidearmWeapon = imgui.checkbox("Sidearm Weapon Gesture", Config.gestures.sidearmWeapon)
        if sidearmWeaponChanged then
            Config.gestures.sidearmWeapon = newSidearmWeapon
            changed = true
        end

        -- Melee Weapon
        local meleeWeaponChanged, newMeleeWeapon = imgui.checkbox("Melee Weapon Gesture", Config.gestures.meleeWeapon)
        if meleeWeaponChanged then
            Config.gestures.meleeWeapon = newMeleeWeapon
            changed = true
        end

        -- Bolt Action
        local boltActionChanged, newBoltAction = imgui.checkbox("Bolt Action Gesture", Config.gestures.boltAction)
        if boltActionChanged then
            Config.gestures.boltAction = newBoltAction
            changed = true
        end

        -- Grenade
        local grenadeChanged, newGrenade = imgui.checkbox("Grenade Gesture", Config.gestures.grenade)
        if grenadeChanged then
            Config.gestures.grenade = newGrenade
            changed = true
        end

        -- Inventory
        local inventoryChanged, newInventory = imgui.checkbox("Inventory Gesture", Config.gestures.inventory)
        if inventoryChanged then
            Config.gestures.inventory = newInventory
            changed = true
        end

        -- Scanner
        local scannerChanged, newScanner = imgui.checkbox("Scanner Gesture", Config.gestures.scanner)
        if scannerChanged then
            Config.gestures.scanner = newScanner
            changed = true
        end

        -- PDA
        local pdaChanged, newPda = imgui.checkbox("PDA Gesture", Config.gestures.pda)
        if pdaChanged then
            Config.gestures.pda = newPda
            changed = true
        end

        -- Reload
        local reloadChanged, newReload = imgui.checkbox("Reload Gesture", Config.gestures.reload)
        if reloadChanged then
            Config.gestures.reload = newReload
            changed = true
        end

        -- Mode Switch
        local modeSwitchChanged, newModeSwitch = imgui.checkbox("Mode Switch Gesture", Config.gestures.modeSwitch)
        if modeSwitchChanged then
            Config.gestures.modeSwitch = newModeSwitch
            changed = true
        end
    end

    -- local projection_matrix = UEVR_Matrix4x4f.new()
    -- uevr.params.vr.get_ue_projection_matrix(0, projection_matrix)
    -- imgui.text("Projection Matrix:")
    -- imgui.text(string.format("[%.2f,%.2f,%.2f,%.2f]", projection_matrix[0][1], projection_matrix[1][1], projection_matrix[2][1], projection_matrix[3][1]))
    -- imgui.text(string.format("[%.2f,%.2f,%.2f,%.2f]", projection_matrix[0][2], projection_matrix[1][2], projection_matrix[2][2], projection_matrix[3][2]))
    -- imgui.text(string.format("[%.2f,%.2f,%.2f,%.2f]", projection_matrix[0][3], projection_matrix[1][3], projection_matrix[2][3], projection_matrix[3][3]))
    -- imgui.text(string.format("[%.2f,%.2f,%.2f,%.2f]", projection_matrix[0][4], projection_matrix[1][4], projection_matrix[2][4], projection_matrix[3][4]))

    -- local pawn = uevr.api:get_local_pawn(0)

    -- if pawn and scopeController.scope_actor and uevr.params.vr.is_hmd_active() then
    --     local size_ratio = scopeController:CalcActorScreenSizeSq(scopeController.scope_actor, 0)
    --     local GetViewDistance = scopeController:GetViewDistance(0)
    --     local view_pos = scopeController.left_view_location;
    --     imgui.text("View Location: " .. string.format("X: %.2f, Y: %.2f, Z: %.2f", view_pos.x, view_pos.y, view_pos.z))
    --     imgui.text("Scope Size Ratio: " .. size_ratio .. "distance: " .. GetViewDistance)
    -- end


    if changed then
        updateConfig(Config)
        Config:save()
    end
end)