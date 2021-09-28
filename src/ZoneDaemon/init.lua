--[[
    local ZoneDaemon = require(path.To.ZoneDaemon)

    function ZoneDaemon.new(Container: Variant<Model, BasePart, table>, Janitor: Janitor, Accuracy: Variant<number, Enum<Accuracy>>): Zone
    function ZoneDaemon.fromRegion(cframe: CFrame, size: Vector3): Zone
    function ZoneDaemon.fromTag(tagName: string, janitor: Janitor, accuracy: Variant<number, Enum<Accuracy>>)

    function Zone:AdjustAccuracy(input: Variant<number, Enum<Accuracy>>)
    function Zone:GetPlayers(): Array<Players>
    function Zone:GetRandomPoint(): Vector3
    function Zone:HaltChecks(): void
    function Zone:Hide(): void
    function Zone:IsInGroup(): boolean
    function Zone:FilterPlayers(callback: (plr: Player) -> boolean): Array<Players>
    function Zone:FindLocalPlayer(): boolean
    function Zone:FindPlayer(Player: Player): boolean
    function Zone:StartChecks(): void -- Called automatically. Only call if Zone:HaltChecks() is called.

    ZoneDaemon.ZoneGroupTools: ZoneGroupTools

    ZoneGroupTools.Settings = {
        Interactions: Enum<Interactions>
            -- ZoneGroupTools.Interactions.Standard, -- Do nothing and allow zones in the same group to run at the same time
            -- ZoneGroupTools.Interactions.OneZoneOnly -- Use the first group that recognized the touch event instead of parallel execution
    }
    function ZoneGroupTools.createGroup(groupName: string): ZoneGroup
    function ZoneGroup:CreateZoneInGroup(Container: Variant<Model, BasePart, table>, Janitor: Janitor, Accuracy: Variant<number, Enum<Accuracy>>): Zone
    function ZoneGroup:CanZonesTriggerOnIntersect(): boolean
    function ZoneGroup:AssignZoneToGroup(zone: Zone): void
    function ZoneGroup:ChangeSettings(newSettings: GroupSettings): void
]]
local Knit = require(game:GetService("ReplicatedStorage").Knit)

local Signal = require(Knit.Util.Signal)
local EnumList = require(Knit.Util.EnumList)
local Janitor = require(Knit.Util.Janitor)
local Timer = require(Knit.Util.Timer)
local TableUtil = require(Knit.Util.TableUtil)

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local IS_SERVER = RunService:IsServer()
local EPSILON = 0.001

local ZoneDaemon = {}
ZoneDaemon.__index = ZoneDaemon

for _, scriptObject in pairs(script:GetChildren()) do
    ZoneDaemon[scriptObject.Name] = scriptObject
end

ZoneDaemon.ObjectType = EnumList.new("ObjectType", {"Part", "Player", "Unknown"})
ZoneDaemon.Accuracy = EnumList.new("Accuracy", {"Precise", "High", "Medium", "Low", "UltraLow"})

local function convertAccuracyToNumber(input) -- Do not call before asserting that input is an enum.
    if input == ZoneDaemon.Accuracy.High then
        return 0.1
    elseif input == ZoneDaemon.Accuracy.Medium then
        return 0.5
    elseif input == ZoneDaemon.Accuracy.Low then
        return 1
    elseif input == ZoneDaemon.Accuracy.UltraLow then
        return 3
    else
        return EPSILON -- ZoneDaemon.Accuracy.Precise
    end
end

local function setup(self)
    self._janitor:Add(self._timer.Tick:Connect(function()
        local newParts = {}
        local canZonesInGroupIntersect = true;
        if self.Group then
            canZonesInGroupIntersect = self.Group:CanZonesTriggerOnIntersect()
        end
        for _, part: Part in pairs(self.ContainerParts) do
            if part.Shape == Enum.PartType.Ball then -- I'm going to assume that this is a sphere. I don't know why it wouldn't.
                for _, newPart in pairs(workspace:GetPartBoundsInRadius(part.Position, part.Size.X)) do
                    if not canZonesInGroupIntersect then
                        if newPart:GetAttribute(self.Group.GroupName) then
                            continue
                        end
                    end
                    table.insert(newParts, newPart)
                end
            else -- If all else fails.
                for _, newPart in pairs(workspace:GetPartsInPart(part)) do
                    if not canZonesInGroupIntersect then
                        if newPart:GetAttribute(self.Group.GroupName) then
                            continue
                        end
                    end
                    table.insert(newParts, newPart)
                end
            end
        end

        for _, newPart in pairs(TableUtil.Filter(newParts, function(newPart) return not table.find(self._interactingPartsArray, newPart) end)) do
            self.OnPartEntered:Fire(newPart)
            if not canZonesInGroupIntersect then
                newPart:SetAttribute(self.Group.GroupName, true)
                newPart:SetAttribute("ZoneGUID", self.GUID)
            end
        end

        for _, oldPart: BasePart in pairs(TableUtil.Filter(self._interactingPartsArray, function(oldPart) return not table.find(newParts, oldPart) end)) do
            self.OnPartLeft:Fire(oldPart)
            task.spawn(function()
                if not canZonesInGroupIntersect then
                    oldPart:SetAttribute(self.Group.GroupName, nil)
                    oldPart:SetAttribute("ZoneGUID", nil)
                end
            end)
        end

        if #self._interactingPartsArray == 0 and #newParts > 0 then
            self.OnTableFirstWrite:Fire()
        elseif #newParts == 0 and #self._interactingPlayersArray > 0 then
            self.OnTableClear:Fire()
        end
        table.clear(self._interactingPartsArray)
        self._interactingPartsArray = newParts

        local currentPlayers = {}
        for _, part in pairs(self._interactingPartsArray) do
            local Player = Players:GetPlayerFromCharacter(part.Parent) or Players:GetPlayerFromCharacter(part.Parent.Parent)
            if not Player then continue end
            if not table.find(currentPlayers, Player) then
                if not canZonesInGroupIntersect then
                    if Player:GetAttribute(self.Group.GroupName) == true then
                        if Player:GetAttribute("ZoneGUID")~=self.GUID then
                            continue
                        end
                    end
                end
                table.insert(currentPlayers, Player)
            end
        end
        for _, removedPlayer in pairs(TableUtil.Filter(self._interactingPlayersArray, function(currentPlayer) return not table.find(currentPlayers, currentPlayer) end)) do
            self.OnPlayerLeft:Fire(removedPlayer)
            task.spawn(function()
                if not canZonesInGroupIntersect then
                    removedPlayer:SetAttribute(self.Group.GroupName, nil)
                    removedPlayer:SetAttribute("ZoneGUID", nil)
                end
            end)
        end
        for _, newPlayer in pairs(TableUtil.Filter(currentPlayers, function(currentPlayer) return not table.find(self._interactingPlayersArray, currentPlayer) end)) do
            self.OnPlayerEntered:Fire(newPlayer)
            if not canZonesInGroupIntersect then
                newPlayer:SetAttribute(self.Group.GroupName, true)
                newPlayer:SetAttribute("ZoneGUID", self.GUID)
            end
        end
        table.clear(self._interactingPlayersArray)
        self._interactingPlayersArray = currentPlayers
    end))
    self:StartChecks()
end

function ZoneDaemon.new(Container, JanitorObject, Accuracy)
    local isValidContainer = false;
    local listOfParts = {}
    if Container then
        if typeof(Container)=="table" then
            listOfParts = Container
            isValidContainer = true
        else
            local children = Container:GetChildren()
            if #children > 0 then
                local isContainerABasePart = Container:IsA("BasePart")
                local list = table.create(#children + (isContainerABasePart and 1 or 0))
                if isContainerABasePart then
                    table.insert(list, Container)
                end
                for _, object in pairs(children) do
                    if object:IsA("BasePart") then
                        table.insert(list, object)
                    else
                        warn("ZoneDaemon should only be used on instanes with children only containing BaseParts.")
                    end
                end
                isValidContainer = true;
                listOfParts = list
            end
            if not isValidContainer and Container:IsA("BasePart") then
                isValidContainer = true;
                listOfParts = {Container}
            end
        end
    end
    if not isValidContainer then error("Invalid Container Type!") end

    local self = setmetatable({}, ZoneDaemon)
    self._janitor = Janitor.new()
    self.ContainerParts = listOfParts
    self.GUID = HttpService:GenerateGUID(false)
    self._interactingPartsArray = {}
    self._interactingPlayersArray = {}

    self.OnPartEntered = Signal.new(self._janitor)
    self.OnPlayerEntered = Signal.new(self._janitor)
    self.OnPartLeft = Signal.new(self._janitor)
    self.OnPlayerLeft = Signal.new(self._janitor)
    self.OnTableFirstWrite = Signal.new(self._janitor) -- fires whenever table goes to a value from nothing
    self.OnTableClear = Signal.new(self._janitor) -- fires whenever table goes to nothing from a value

    if not IS_SERVER then
        self.OnLocalPlayerEntered = Signal.new(self._janitor)
        self._janitor:Add(self.OnPlayerEntered:Connect(function(Player)
            if Player == Players.LocalPlayer then
                self.OnLocalPlayerEntered:Fire()
            end
        end))
        self.OnLocalPlayerLeft = Signal.new(self._janitor)
        self._janitor:Add(self.OnPlayerLeft:Connect(function(Player)
            if Player == Players.LocalPlayer then
                self.OnLocalPlayerLeft:Fire()
            end
        end))
    end

    local numberAccuracy
    if typeof(Accuracy) == "number" then
        numberAccuracy = Accuracy
    elseif(not Accuracy) or (not ZoneDaemon.Accuracy.Is(Accuracy)) then
        Accuracy = ZoneDaemon.Accuracy.High
        numberAccuracy = convertAccuracyToNumber(Accuracy)
    end

    self._timer = Timer.new(numberAccuracy, self._janitor)
    setup(self)
    if JanitorObject then
        JanitorObject:Add(self)
    end
    return self
end

local MAX_PART_SIZE = 2024
local function createCube(cubeCFrame, cubeSize, container)
    if cubeSize.X > MAX_PART_SIZE or cubeSize.Y > MAX_PART_SIZE or cubeSize.Z > MAX_PART_SIZE then
        local quarterSize = cubeSize * 0.25
        local halfSize = cubeSize * 0.5
        createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize)
        createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize)
    else
        local part = Instance.new("Part")
        part.CFrame = cubeCFrame
        part.Size = cubeSize
        part.Anchored = true
        part.Parent = container
    end
end

function ZoneDaemon.fromRegion(cframe, size)
	local container = Instance.new("Model")
	createCube(cframe, size, container)
	return ZoneDaemon.new(container)
end

function ZoneDaemon.fromTag(tagName, janitor, accuracy)
    local zone = ZoneDaemon.new(CollectionService:GetTagged(tagName) or {}, janitor, accuracy)
    zone._janitor:Add(CollectionService:GetInstanceAddedSignal(tagName):Connect(function(instance)
        table.insert(zone.ContainerParts, instance)
    end))
    zone._janitor:Add(CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance)
        table.remove(zone.ContainerParts, table.find(zone.ContainerParts, instance))
    end))
    return zone
end

local random = Random.new()
function ZoneDaemon:GetRandomPoint()
    local selectedPart = self.ContainerParts[random:NextInteger(1, #self.ContainerParts)]
    return (selectedPart.CFrame * CFrame.new(random:NextNumber(-selectedPart.Size.X/2,selectedPart.Size.X/2), random:NextNumber(-selectedPart.Size.Y/2,selectedPart.Size.Y/2), random:NextNumber(-selectedPart.Size.Z/2,selectedPart.Size.Z/2))).Position
end

function ZoneDaemon:StartChecks()
    self._timer:StartNow()
end

function ZoneDaemon:HaltChecks()
    self._timer:Stop()
end
ZoneDaemon.StopChecks = ZoneDaemon.HaltChecks

function ZoneDaemon:IsInGroup()
    return self.Group ~= nil
end

function ZoneDaemon:Hide()
    for _, part in pairs(self.ContainerParts) do
        part.Transparency = 1
        part.Locked = true
    end
end

function ZoneDaemon:AdjustAccuracy(input)
    if self.Accuracy.Is(input) then
        self._timer.Interval = convertAccuracyToNumber(input)
    elseif type(input)=="number" then
        self._timer.Interval = input
    end
end

function ZoneDaemon:FilterPlayers(callback: (plr: Player) -> boolean)
    return TableUtil.Filter(self:GetPlayers(), callback)
end

function ZoneDaemon:FindPlayer(Player: Player)
    return table.find(self:GetPlayers(), Player) ~= nil
end

function ZoneDaemon:FindLocalPlayer()
    assert(not IS_SERVER, "This function can only be called on the client!")
    return self:FindPlayer(Players.LocalPlayer)
end

function ZoneDaemon:GetPlayers()
    return self._interactingPlayersArray
end

return ZoneDaemon