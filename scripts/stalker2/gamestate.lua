local utils = require("common.utils")
local uevrUtils = require("libs/uevr_utils")

local GameStateManager = {
    -- State tracking
    inMenu = false,
    isInventoryPDA = false,
    lastWorldTime = 0,
    worldTimeTick = 0,
    initialized = false,
    last_level = nil,
    StaticMeshC = nil,
    isReloading = false,
    isTwoHanding = false,
    isDetectorEquipped = false,
    isMontageAttached = false,
    isClimbing = false,
    isConversation = false,
    isWeaponModMontageActive = false,
    -- Cache for conversation camera optimization
    lastPawnAddress = nil,
    cachedConversationCamera = nil,
    -- Tick counters for throttling
    climbingTick = 0,
    inventoryTick = 0,
    -- API reference
    api = nil
}

-- Initialize the GameStateManager
function GameStateManager:Init()
    self.api = uevr.api
    self.inMenu = false
    self.isInventoryPDA = false
    self.lastWorldTime = 0
    self.worldTimeTick = 0
    self.last_level = nil
    self.isDetectorEquipped = false
    self.isMontageAttached = false
    self.isClimbing = false
    self.isConversation = false
    self.lastPawnAddress = nil
    self.cachedConversationCamera = nil
    self.climbingTick = 0
    self.inventoryTick = 0
    self.weaponCache = {} -- Cache for weapon details (Name, Scope)
    self.initialized = true
    self.StaticMeshC = utils.find_required_object("Class /Script/Engine.StaticMeshComponent")
    print("GameStateManager initialized")
end

-- Get Cached Weapon Info (Name, Scope)
function GameStateManager:GetWeaponCache(weaponMesh)
    if not weaponMesh then return nil end
    local address = weaponMesh:get_address()
    
    -- Return cached if exists
    if self.weaponCache[address] then
        -- Validate scope is still valid (optional but safe)
        if self.weaponCache[address].scope and not uevrUtils.isValid(self.weaponCache[address].scope) then
             self.weaponCache[address].scope = self:get_scope_mesh(weaponMesh)
        end
        return self.weaponCache[address]
    end

    -- Compute and Cache
    local info = {}
    
    -- 1. Get Name
    if weaponMesh.SkeletalMesh then
         info.name = uevrUtils.getShortName(weaponMesh.SkeletalMesh)
    else
        local owner = weaponMesh:GetOwner()
        if owner then
            info.name = uevrUtils.getShortName(owner)
        end
    end
    
    -- 2. Get Scope
    info.scope = self:get_scope_mesh(weaponMesh)
    
    self.weaponCache[address] = info
    -- print("[Cache] Created entry for " .. tostring(info.name))
    return info
end

-- Reset the GameStateManager state
function GameStateManager:Reset()
    self:Init()
    print("GameStateManager reset")
end

-- Update function to be called on engine tick
function GameStateManager:Update()
    self:CheckMenuState()
    self:CheckInventoryPDAState()
    self:CheckClimbingState()
    self:CheckConversationState()
end

-- Check if the player is in a menu
function GameStateManager:CheckMenuState()
    local worldTime = self:GetWorldTime()

    if worldTime == self.lastWorldTime then
        self.worldTimeTick = self.worldTimeTick + 1
        if self.worldTimeTick >= 50 then
            self.inMenu = true
        end
    else
        self.inMenu = false
        self.worldTimeTick = 0
    end

    self.lastWorldTime = worldTime
end

-- Check if player is in inventory or PDA
-- Optimized: Runs every 10 ticks to reduce overhead
function GameStateManager:CheckInventoryPDAState()
    self.inventoryTick = self.inventoryTick + 1
    if self.inventoryTick % 10 ~= 0 then
        return -- Skip check, maintain previous state
    end

    local pawn = self:GetLocalPawn()
    if pawn and pawn.Mesh and pawn.Mesh.AnimScriptInstance and
       pawn.Mesh.AnimScriptInstance.HandItemData then
        local check1 = pawn.Mesh.AnimScriptInstance.HandItemData.bHasItemInHands
        local check2 = pawn.Mesh.AnimScriptInstance.HandItemData.bIsUsesLeftHand
        local check3 = pawn.Mesh.AnimScriptInstance.HandItemData.bIsUsesRightHand
        if check1 and check2 and check3 then
            self.isInventoryPDA = true
        else
            self.isInventoryPDA = false
        end
    end
end
 
-- Check if player is climbing a ladder
-- Optimized: Runs every 10 ticks (approx 100ms)
function GameStateManager:CheckClimbingState()
    self.climbingTick = self.climbingTick + 1
    if self.climbingTick % 10 ~= 0 then
        return -- Skip check, maintain previous state
    end

    self.isClimbing = false
    local pawn = self:GetLocalPawn()
    if pawn and pawn.Mesh and pawn.Mesh.AnimScriptInstance then
        local animInstance = pawn.Mesh.AnimScriptInstance
        
        -- Attempt to access ClimbingData via reflection
        local climbingData = animInstance["ClimbingData"]
        if climbingData then
            -- bAnimClimbStarted is a boolean property in this struct
            if climbingData["bAnimClimbStarted"] == true then
                self.isClimbing = true
            end
        end
    end
end

-- Check if player is in a conversation (zoomed FOV)
-- Optimized with caching to avoid per-frame component scanning
function GameStateManager:CheckConversationState()
    if not Config.enableConversationFix then 
        self.isConversation = false
        return 
    end

    local pawn = self:GetLocalPawn()
    if not pawn then
        self.isConversation = false
        self.cachedConversationCamera = nil
        self.lastPawnAddress = nil
        return
    end

    -- Check if pawn identity changed (respawn, load, etc.)
    local pawnAddress = pawn:get_address()
    if pawnAddress ~= self.lastPawnAddress then
        self.cachedConversationCamera = nil
        self.lastPawnAddress = pawnAddress
        -- print("[UEVR] Pawn changed, invalidated conversation camera cache")
    end

    -- 1. Try Cached Camera
    if self.cachedConversationCamera then
        local fov = self.cachedConversationCamera["FieldOfView"]
        if fov and type(fov) == "number" then
            local threshold = Config.conversationFOVThreshold or 80.0
            if fov < threshold then
                self.isConversation = true
            else
                self.isConversation = false
            end
            return -- Success, skip scan
        else
            -- Cache invalid (component destroyed?), force rescan
            self.cachedConversationCamera = nil
        end
    end

    -- 2. Scan for Camera (if cache empty or invalid)
    if pawn.Mesh then
        -- Helper to check a component and populate cache if found
        local function checkComp(comp)
            if not comp then return false end
            local name = comp:get_fname():to_string()
            
            if string.find(name, "Camera") then
                 local fov = comp["FieldOfView"]
                 if fov and type(fov) == "number" then
                     -- Found a valid camera, cache it!
                     self.cachedConversationCamera = comp
                     
                     local threshold = Config.conversationFOVThreshold or 80.0
                     -- print("Found Camera: " .. name .. " | FOV: " .. tostring(fov) .. " | Thresh: " .. tostring(threshold))
                     if fov < threshold then
                         return true
                     end
                 end
            end
            return false
        end

        local foundCamera = false

        -- Scan RootComponent Children
        if pawn.RootComponent and pawn.RootComponent.AttachChildren then
            for _, child in ipairs(pawn.RootComponent.AttachChildren) do
                if checkComp(child) then
                    self.isConversation = true
                    foundCamera = true
                    return
                end
            end
        end
        
        -- Scan Mesh Attach Children
        if not foundCamera and pawn.Mesh and pawn.Mesh.AttachChildren then
             for _, child in ipairs(pawn.Mesh.AttachChildren) do
                if checkComp(child) then
                    self.isConversation = true
                    foundCamera = true
                    return
                end
            end
        end
        
        -- Direct Reflection fallback
        if not foundCamera then
             local camComp = pawn["Camera"]
             if checkComp(camComp) then
                 self.isConversation = true
                 return
             end
        end
    end
    
    self.isConversation = false
end


function GameStateManager:is_scope_active(pawn)
    if not pawn then return false end
    local optical_scope = pawn.PlayerOpticScopeComponent
    if not optical_scope then return false end
    local scope_active = optical_scope:read_byte(0xA8, 1)
    if scope_active > 0 then
        return true
    end
    return false
end

function GameStateManager:get_scope_mesh(parent_mesh)
    if not parent_mesh then return nil end

    local child_components = parent_mesh.AttachChildren
    if not child_components then return nil end

    for _, component in ipairs(child_components) do
        if component:is_a(self.StaticMeshC) and string.find(component:get_fname():to_string(), "scope") then
            -- Check if this component has the required socket for attachment
            if component:DoesSocketExist("OpticCutoutSocket") then
                return component
            end
        end
    end
    
    -- Fallback: return first scope found if none have the socket (legacy behavior)
    for _, component in ipairs(child_components) do
        if component:is_a(self.StaticMeshC) and string.find(component:get_fname():to_string(), "scope") then
            return component
        end
    end

    return nil
end

function GameStateManager:get_all_scope_meshes(parent_mesh)
    local scope_meshes = {}
    if not parent_mesh then return scope_meshes end

    local child_components = parent_mesh.AttachChildren
    if not child_components then return scope_meshes end

    for _, component in ipairs(child_components) do
        if component:is_a(self.StaticMeshC) and string.find(component:get_fname():to_string(), "scope") then
            table.insert(scope_meshes, component)
        end
    end

    return scope_meshes
end

function GameStateManager:get_weapon_attachment_mesh(pawn)
    if not pawn then return nil end
    
    local potential_components = {}
    
    -- Add RootComponent children
    if pawn.RootComponent and pawn.RootComponent.AttachChildren then
         for _, comp in ipairs(pawn.RootComponent.AttachChildren) do
             table.insert(potential_components, comp)
         end
    end
    
    -- Add Mesh children (likely where the silencer is)
    if pawn.Mesh and pawn.Mesh.AttachChildren then
         for _, comp in ipairs(pawn.Mesh.AttachChildren) do
             table.insert(potential_components, comp)
         end
    end
    
    -- Search all collected components
    for _, component in ipairs(potential_components) do
        local compName = component:get_fname():to_string()
        -- print("[Debug Scan] Checking Component: " .. compName)
        
        -- Check 1: Name based (Stronger for these transient meshes)
        if string.find(compName, "WeaponAttachment") and 
           (string.find(compName, "silen") or string.find(compName, "sight") or string.find(compName, "scope")) then
            print("[Debug] Found Attachment Mesh by Name: " .. compName)
            return component
        end

        -- Check 2: Socket based (Fallback)
        if component:is_a(self.StaticMeshC) and component.AttachSocketName then
             local socketName = component.AttachSocketName:to_string()
             -- print("[Debug Scan] .. Socket: " .. socketName) 
             if socketName == "jnt_l_weapon" then
                 print("[Debug] Found Attachment Mesh by Socket: " .. compName)
                 return component
             end
        end
    end
    -- print("[Debug] No matching attachment mesh found in " .. #potential_components .. " candidates.")
    return nil
end

-- Get current world time
function GameStateManager:GetWorldTime()
    local engine = self.api:get_engine()
    if engine and engine.GameViewport and engine.GameViewport.World and
       engine.GameViewport.World.GameState then
        return engine.GameViewport.World.GameState.ReplicatedWorldTimeSeconds
    end
    return 0
end

-- Get local player pawn
function GameStateManager:GetLocalPawn()
    return self.api:get_local_pawn(0)
end

function GameStateManager:IsLevelChanged(engine)
    local viewport = engine.GameViewport
    if viewport then
        local world = viewport.World
        if world then
            local level = world.PersistentLevel
            if self.last_level ~= level then
                self.last_level = level
                return true
            end
        end
    end
    return false
end

-- Send a key press (down or up)
function GameStateManager:SendKeyPress(key_value, key_up)
    local key_up_string = "down"
    if key_up == true then
        key_up_string = "up"
    end

    -- Specialized handling for Reload: Pulse the key once to the game, but keep state for hand attachment
    if key_value == 'R' then
        if not key_up then
            -- Trigger once (Pulse)
            self.api:dispatch_custom_event(key_value, "down")
            self.api:dispatch_custom_event(key_value, "up")
            self.isReloading = true
        else
            -- Release internal state only
            self.isReloading = false
        end
        return -- Handled
    end

    self.api:dispatch_custom_event(key_value, key_up_string)
end

-- Send key down
function GameStateManager:SendKeyDown(key_value)
    self:SendKeyPress(key_value, false)
end

-- Send key up
function GameStateManager:SendKeyUp(key_value)
    self:SendKeyPress(key_value, true)
end

-- Get current equipped weapon
function GameStateManager:GetEquippedWeapon()
    local pawn = self:GetLocalPawn()
    if not pawn then return nil end
    local sk_mesh = pawn.Mesh
    if not sk_mesh then return nil end
    local anim_instance = sk_mesh.AnimScriptInstance
    if not anim_instance then return nil end
    local weapon_mesh = anim_instance.WeaponData.WeaponMesh
    return weapon_mesh
end

-- Get game engine
function GameStateManager:GetEngine()
    return self.api:get_engine()
end

-- Create a new instance
function GameStateManager:new()
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance:Init()
    return instance
end

return GameStateManager
