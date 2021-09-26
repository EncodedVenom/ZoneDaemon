local Knit = require(game:GetService("ReplicatedStorage").Knit)
local EnumList = require(Knit.Util.EnumList)
local TableUtil = require(Knit.Util.TableUtil)

local HttpService = game:GetService("HttpService")

local ZoneDaemon = require(script.Parent)

local ZoneGroup = {}
ZoneGroup.__index = ZoneGroup

ZoneGroup.Interactions = EnumList.new("Interactions", {
    "Standard", -- Do nothing and allow zones in the same group to run at the same time
    "OneZoneOnly" -- Use the first group that recognized the touch event instead of parallel execution
})

local defaultSettings = {
    InteractionRules = ZoneGroup.Interactions.Standard,
}

function ZoneGroup.createGroup(groupName)
    groupName = groupName or HttpService:GenerateGUID(false)
    return setmetatable({
        Settings = TableUtil.Copy(defaultSettings),
        GroupName = groupName
    }, ZoneGroup)
end

function ZoneGroup:CreateZoneInGroup(Container, Accuracy)
    local Zone = ZoneDaemon.createZone(Container, Accuracy)
    self:AssignZoneToGroup(Zone)
    return Zone
end

function ZoneGroup:CanZonesTriggerOnIntersect(group)
    return self.Settings.InteractionRules == ZoneGroup.Interactions.Standard
end

function ZoneGroup:AssignZoneToGroup(zone)
    zone.Group = self
end

function ZoneGroup:ChangeSettings(newSettings)
    for k, v in pairs(newSettings) do
        self.Settings[k]=v
    end
end

return ZoneGroup