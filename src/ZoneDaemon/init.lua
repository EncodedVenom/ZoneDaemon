local Signal = require(script.Signal)
local EnumList = require(script.EnumList)
local Trove = require(script.Trove)
local Timer = require(script.Timer)
local TableUtil = require(script.TableUtil)

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local IS_SERVER = RunService:IsServer()
local MAX_PART_SIZE = 2048
local RNG = Random.new()
local EPSILON = 0.001

local Characters = {}

local ZoneDaemon = {}
ZoneDaemon.__index = ZoneDaemon

ZoneDaemon.Elements = {} :: {string}

ZoneDaemon._currentElements = {} :: {[Player]: {[string]: any}}

ZoneDaemon._elementQueryListeners = {} :: {[Player]: {[string]: Signal<any>}}

ZoneDaemon.ObjectType = EnumList.new("ObjectType", {"Part", "Player", "Unknown"})
ZoneDaemon.Accuracy = EnumList.new("Accuracy", {"Precise", "High", "Medium", "Low", "UltraLow"})

ZoneDaemon.OverlapParams = OverlapParams.new()
ZoneDaemon.OverlapParams.FilterDescendantsInstances = Characters
ZoneDaemon.OverlapParams.FilterType = Enum.RaycastFilterType.Whitelist

type Signal<T> = typeof(Signal.new()) & {
	Connect: ((T) -> ());
}

export type ZoneDaemon = typeof(ZoneDaemon) & {

	OnPartEntered: Signal<BasePart>;
	OnPlayerEntered: Signal<BasePart>;
	OnPartLeft: Signal<BasePart>;
	OnPlayerLeft: Signal<Player>;
	OnTableFirstWrite: Signal<nil>;
	OnTableClear: Signal<nil>;
}

local function convertAccuracyToNumber(input: typeof(ZoneDaemon.Accuracy) | number)
	if input == ZoneDaemon.Accuracy.High then
		return 0.1
	elseif input == ZoneDaemon.Accuracy.Medium then
		return 0.5
	elseif input == ZoneDaemon.Accuracy.Low then
		return 1
	elseif input == ZoneDaemon.Accuracy.UltraLow then
		return 3
	else
		return EPSILON
	end
end
local function createCube(cubeCFrame: CFrame, cubeSize: Vector3, container: BasePart | Model)
	if cubeSize.X > MAX_PART_SIZE or cubeSize.Y > MAX_PART_SIZE or cubeSize.Z > MAX_PART_SIZE then
		local quarterSize = cubeSize * 0.25
		local halfSize = cubeSize * 0.5

		createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize, container)
	else
		local part = Instance.new("Part")
		part.CFrame = cubeCFrame
		part.Size = cubeSize

		part.Anchored = true
		part.Parent = container
	end
end
local function isValidContainer(container: BasePart | {BasePart}): BasePart | {BasePart}
	local listOfParts = {}

	if container then
		if typeof(container) == "table" then
			listOfParts = container
		else
			local children = container:GetChildren()

			if #children > 0 then
				local isContainerABasePart = container:IsA("BasePart")
				local list = table.create(#children + (if isContainerABasePart then 1 else 0))

				if isContainerABasePart then
					table.insert(list, container)
				end

				for _, object in pairs(children) do
					if object:IsA("BasePart") then
						table.insert(list, object)
					else
						warn("ZoneDaemon should only be used on instances with children only containing BaseParts.")
					end
				end

				listOfParts = list
				return listOfParts
			end

			if container:IsA("BasePart") then
				listOfParts = { container } :: {BasePart} -- Fix strict type issue
				return listOfParts
			end
		end
	end

	return (#listOfParts > 0) and listOfParts or nil
end
local function playerAdded(player: Player)
	local playerTrove = Trove.new()
	playerTrove:AttachToInstance(player)

	local function characterAdded(character: Model)
		local characterTrove = playerTrove:Extend()
		characterTrove:AttachToInstance(character)

		table.insert(Characters, character)

		characterTrove:Add(function()
			table.remove(Characters, table.find(Characters, character))
		end)
	end

	playerTrove:Connect(player.CharacterAdded, characterAdded)
end

Players.PlayerAdded:Connect(playerAdded)
for _, player: Player in ipairs(Players:GetPlayers()) do
	task.spawn(playerAdded, player)
end

function ZoneDaemon.new(container: {BasePart} | Instance, accuracy: typeof(ZoneDaemon.Accuracy) | number | nil): ZoneDaemon
	local listOfParts = isValidContainer(container)
	if not listOfParts then
		error("Invalid Container Type")
	end

	local self = setmetatable({}, ZoneDaemon)
	self._trove = Trove.new()
	self._guid = HttpService:GenerateGUID(false)
	self._overrideParams = nil
	self._containerParts = listOfParts
	self._interactingPartsArray = {}
	self._interactingPlayersArray = {}

	self._currentElements = {}
	self._elementQueryListeners = {}

	self.Elements = {}

	self.OnPartEntered = self._trove:Construct(Signal)
	self.OnPlayerEntered = self._trove:Construct(Signal)
	self.OnPartLeft = self._trove:Construct(Signal)
	self.OnPlayerLeft = self._trove:Construct(Signal)
	self.OnTableFirstWrite = self._trove:Construct(Signal)
	self.OnTableClear = self._trove:Construct(Signal)

	if not IS_SERVER then
		self.OnLocalPlayerEntered = self._trove:Construct(Signal)
		self.OnLocalPlayerLeft = self._trove:Construct(Signal)

		self._trove:Connect(self.OnPlayerEntered, function(Player)
			if Player == Players.LocalPlayer then
				self.OnLocalPlayerEntered:Fire()
			end
		end)

		self._trove:Connect(self.OnPlayerLeft, function(Player)
			if Player == Players.LocalPlayer then
				self.OnLocalPlayerLeft:Fire()
			end
		end)
	end

	local numberAccuracy: number
	if typeof(accuracy) == "number" then
		numberAccuracy = accuracy
	elseif (not accuracy) or (not ZoneDaemon.Accuracy.Is(accuracy)) then -- Nil case: default to High accuracy.
		accuracy = ZoneDaemon.Accuracy.High
		numberAccuracy = convertAccuracyToNumber(accuracy)
	end

	self._timer = self._trove:Construct(Timer.new, numberAccuracy)
	self._trove:Connect(self._timer.Tick, function()
		local newParts = {}
		local intersectionPart = {}
		local canZonesInGroupIntersect = true;
		if self.Group then
			canZonesInGroupIntersect = self.Group:CanZonesTriggerOnIntersect()
		end

		local overlapParams = if self._overrideParams then self._overrideParams else ZoneDaemon.OverlapParams
		if overlapParams == ZoneDaemon.OverlapParams then
			overlapParams.FilterDescendantsInstances = Characters
		end

		for _, part: Part in pairs(self._containerParts) do
			if part.Shape == Enum.PartType.Ball then
				for _, newPart in pairs(workspace:GetPartBoundsInRadius(part.Position, part.Size.X, overlapParams)) do
					if not canZonesInGroupIntersect then
						if newPart:GetAttribute(self.Group.GroupName) then
							continue
						end
					end
					table.insert(newParts, newPart)
					intersectionPart[newPart] = part
				end
			else
				for _, newPart in pairs(workspace:GetPartsInPart(part, overlapParams)) do
					if not canZonesInGroupIntersect then
						if newPart:GetAttribute(self.Group.GroupName) then
							continue
						end
					end
					table.insert(newParts, newPart)
					intersectionPart[newPart] = part
				end
			end
		end

		for _, newPart: BasePart in pairs(TableUtil.Filter(newParts, function(newPart) return not table.find(self._interactingPartsArray, newPart) end)) do
			self.OnPartEntered:Fire(newPart)
			if not canZonesInGroupIntersect then
				newPart:SetAttribute(self.Group.GroupName, true)
				newPart:SetAttribute("ZoneGUID", self._guid)
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
		local selectedElement: {[Player]: {dist: number, element: string | nil, elementValue: any}} = {}

		for _, part: BasePart in pairs(self._interactingPartsArray) do
			local Player = Players:GetPlayerFromCharacter(part.Parent) or Players:GetPlayerFromCharacter(part.Parent.Parent)
			if not Player then continue end

			local intersectedPart = intersectionPart[part]

			if not intersectedPart then continue end
			if not self._currentElements[Player] then self._currentElements[Player] = {} end

			for _, element in ipairs(self.Elements) do
				local Positions = {
					intersectedPart.Position + Vector3.new(0, intersectedPart.Size.Y, 0),
					intersectedPart.Position + Vector3.new(0, -intersectedPart.Size.Y, 0),
					intersectedPart.Position + Vector3.new(intersectedPart.Size.X, 0, 0),
					intersectedPart.Position + Vector3.new(-intersectedPart.Size.X, 0, 0),
					intersectedPart.Position + Vector3.new(0, 0, intersectedPart.Size.Z),
					intersectedPart.Position + Vector3.new(0, 0, -intersectedPart.Size.Z),
				}
				if not selectedElement[Player] then
					selectedElement[Player] = {
						dist = math.huge,
						element = nil,
						elementValue = nil
					}
				end
				local trueClosestPos = math.huge
				local HRP: Vector3 = Player.Character.HumanoidRootPart.Position

				for _, pos in ipairs(Positions) do
					trueClosestPos = math.min(trueClosestPos, (pos - HRP).Magnitude)
				end

				if trueClosestPos < selectedElement[Player].dist then
					selectedElement[Player] = {
						dist = trueClosestPos,
						element = element,
						elementValue = intersectedPart:GetAttribute(element)
					}
				end
			end

			if not table.find(currentPlayers, Player) then
				if not canZonesInGroupIntersect then
					if Player:GetAttribute(self.Group.GroupName) == true then
						if Player:GetAttribute("ZoneGUID") ~= self._guid then
							continue
						end
					end
				end
				table.insert(currentPlayers, Player)
			end
		end

		for player, dict in pairs(selectedElement) do
			if not self._currentElements[player] then
				self._currentElements[player] = {}
			end
			local last = self._currentElements[player][dict.element]
			self._currentElements[player][dict.element] = dict.elementValue

			if last ~= self._currentElements[player][dict.element] and self._elementQueryListeners[player] and self._elementQueryListeners[player][dict.element] then
				self._elementQueryListeners[player][dict.element]:Fire(dict.elementValue)
			end	
		end

		for _, removedPlayer: Player in pairs(TableUtil.Filter(self._interactingPlayersArray, function(currentPlayer: Player) return not table.find(currentPlayers, currentPlayer) end)) do
			self.OnPlayerLeft:Fire(removedPlayer)
			if self._elementQueryListeners[removedPlayer] then
				for _, element in ipairs(self.Elements) do
					self._elementQueryListeners[removedPlayer][element]:Fire(nil)
					self._currentElements[removedPlayer][element] = nil
				end
			end
			task.spawn(function()
				if not canZonesInGroupIntersect then
					removedPlayer:SetAttribute(self.Group.GroupName, nil)
					removedPlayer:SetAttribute("ZoneGUID", nil)
				end
			end)
		end

		for _, newPlayer: Player in pairs(TableUtil.Filter(currentPlayers, function(currentPlayer) return not table.find(self._interactingPlayersArray, currentPlayer) end)) do
			self.OnPlayerEntered:Fire(newPlayer)
			if not canZonesInGroupIntersect then
				newPlayer:SetAttribute(self.Group.GroupName, true)
				newPlayer:SetAttribute("ZoneGUID", self._guid)
			end
		end

		table.clear(self._interactingPlayersArray)
		self._interactingPlayersArray = currentPlayers
	end)

	self:StartChecks()
	return self :: ZoneDaemon
end

function ZoneDaemon.fromRegion(cframe: CFrame, size: Vector3, accuracy: typeof(ZoneDaemon.Accuracy) | number | nil): ZoneDaemon
	local container: Model = Instance.new("Model")
	createCube(cframe, size, container)
	return ZoneDaemon.new(container, accuracy)
end

function ZoneDaemon.fromTag(tagName: string, accuracy: typeof(ZoneDaemon.Accuracy) | number): ZoneDaemon
	local zone = ZoneDaemon.new(CollectionService:GetTagged(tagName) or {}, accuracy)

	zone._trove:Connect(CollectionService:GetInstanceAddedSignal(tagName), function(instance)
		table.insert(zone._containerParts, instance)
	end)

	zone._trove:Connect(CollectionService:GetInstanceRemovedSignal(tagName), function(instance)
		table.remove(zone._containerParts, table.find(zone._containerParts, instance))
	end)
	return zone
end

function ZoneDaemon:AddElement(elementName: string, defaultValue: any?)
	assert(not table.find(self.Elements, elementName), "Already defined element name!")
	for _, part: BasePart in ipairs(self._containerParts) do
		if not part:GetAttribute(elementName) and not defaultValue then
			error("Part "..part:GetFullName().." did not have an element attribute and a default was not provided!")
		elseif defaultValue and (not part:GetAttribute(elementName))then
			part:SetAttribute(elementName, defaultValue)
		end
	end
	table.insert(self.Elements, elementName)
end

function ZoneDaemon:QueryElementForPlayer(elementName: string, player: Player)
	if not (self:FindPlayer(player)) then
		return
	end
	return self._currentElements[player][elementName]
end

function ZoneDaemon:QueryElementForLocalPlayer(elementName: string)
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:QueryElementForPlayer(elementName, Players.LocalPlayer)
end

function ZoneDaemon:ListenToElementChangesForPlayer(elementName: string, player: Player)
	if not self._elementQueryListeners[player] then
		self._elementQueryListeners[player] = {}
	end
	if self._elementQueryListeners[player][elementName] then
		self._elementQueryListeners[player][elementName]:Destroy()
	end

	local signal = self._trove:Construct(Signal)
	self._elementQueryListeners[player][elementName] = signal

	return signal
end

function ZoneDaemon:ListenToElementChangesForLocalPlayer(elementName: string)
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:ListenToElementChangesForPlayer(elementName, Players.LocalPlayer)
end

function ZoneDaemon:GetRandomPoint(): Vector3
	local selectedPart = self._containerParts[RNG:NextInteger(1, #self._containerParts)]
	return (selectedPart.CFrame * CFrame.new(RNG:NextNumber(-selectedPart.Size.X / 2, selectedPart.Size.X / 2), RNG:NextNumber(-selectedPart.Size.Y / 2, selectedPart.Size.Y / 2), RNG:NextNumber(-selectedPart.Size.Z / 2, selectedPart.Size.Z / 2))).Position
end

function ZoneDaemon:StartChecks(): nil
	self._timer:StartNow()
end

function ZoneDaemon:HaltChecks(): nil
	self._timer:Stop()
end
ZoneDaemon.StopChecks = ZoneDaemon.HaltChecks

function ZoneDaemon:IsInGroup(): boolean
	return self.Group ~= nil
end

function ZoneDaemon:Hide(): nil
	for _, part in pairs(self._containerParts) do
		part.Transparency = 1
		part.Locked = true
	end
end

function ZoneDaemon:AdjustAccuracy(input: typeof(ZoneDaemon.Accuracy) | number): nil
	if self.Accuracy.Is(input) then
		self._timer.Interval = convertAccuracyToNumber(input)
	elseif type(input) == "number" then
		self._timer.Interval = input
	end
end

function ZoneDaemon:FilterPlayers(callback: (plr: Player) -> boolean): Array<Player>
	return TableUtil.Filter(self:GetPlayers(), callback)
end

function ZoneDaemon:FindPlayer(Player: Player): boolean
	return table.find(self:GetPlayers(), Player) ~= nil
end

function ZoneDaemon:FindLocalPlayer(): boolean
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:FindPlayer(Players.LocalPlayer)
end

function ZoneDaemon:GetPlayers(): Array<Player>
	return self._interactingPlayersArray
end

function ZoneDaemon:SetParams(overlapParams: OverlapParams | nil): nil
	self._overrideParams = overlapParams
end

return ZoneDaemon
