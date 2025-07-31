local RunService = game:GetService "RunService"
local jecs = require(script.Parent.roblox_packages.jecs)
local world = require(game.ReplicatedStorage.shared.std.world)
local common = require(script.common)

local client = require(script.client)
local server = require(script.server)

export type Server = server.Server
export type Client = client.Client

export type Replecs = {
	server: Server,
	client: Client,

	after_replication: (self: Replecs, callback: () -> ()) -> (),
}

type MemberFilter = {
	[Player]: boolean,
}

local function component()
    return world:component()
end

local tag = component

local replecs = {
	shared = tag(),
	networked = component() :: jecs.Entity<MemberFilter?>,
	reliable = component() :: jecs.Entity<MemberFilter?>,
	unreliable = component() :: jecs.Entity<MemberFilter?>,
	pair = tag(),

	serdes = component() :: jecs.Entity<common.Serdes>,
	bytespan = component() :: jecs.Entity<number>,
	custom_id = component() :: jecs.Entity<(any) -> jecs.Entity>,
	__alive_tracking__ = tag(),
}
replecs.__index = replecs
replecs.Serdes = replecs.serdes
replecs.Bytespan = replecs.bytespan
replecs.CustomId = replecs.custom_id
replecs.Networked = replecs.networked
replecs.Reliable = replecs.reliable
replecs.Unreliable = replecs.unreliable
replecs.Pair = replecs.pair
replecs.Shared = replecs.shared

world:set(replecs.serdes, jecs.Name, "replecs.serdes")
world:set(replecs.bytespan, jecs.Name, "replecs.bytespan")
world:set(replecs.custom_id, jecs.Name, "replecs.custom_id")
world:set(replecs.networked, jecs.Name, "replecs.networked")
world:set(replecs.reliable, jecs.Name, "replecs.reliable")
world:set(replecs.unreliable, jecs.Name, "replecs.unreliable")
world:set(replecs.pair, jecs.Name, "replecs.pair")
world:set(replecs.shared, jecs.Name, "replecs.shared")

function replecs.create_server(world: jecs.World?): Server
	return server.create(world, replecs)
end

function replecs.create_client(world: jecs.World?): Client
	return client.create(world, replecs)
end

function replecs.create(world: jecs.World?): Replecs
	local lib = {} :: Replecs

	if RunService:IsServer() then
		lib.server = server.create(world, replecs)
	end
	if RunService:IsClient() then
		lib.client = client.create(world, replecs)
	end

	return setmetatable(lib, replecs) :: any
end

function replecs.after_replication(lib: Replecs, callback: () -> ())
	local lib_client = lib.client
	if lib_client then
		lib_client:after_replication(callback)
	else
		callback()
	end
end

return replecs
