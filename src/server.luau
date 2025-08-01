--!optimize 2
--!native

local jecs = require "../roblox_packages/jecs"
local utils = require "./utils"
local common = require "./common"
local masking_controller = require "./masking"

type Cursor = utils.Cursor

type World = jecs.World
type Entity<T = any> = jecs.Entity<T>

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type FunctionFilter = (player: Player) -> boolean

type TrackInfo = {
	entities: Map<Entity, boolean>,
	components: { [Entity]: { [Entity]: number } },
}

type EntityStorage = {
	tags: { [Entity]: boolean },
	values: { [Entity]: any },
	pairs: { [Entity]: Set<Entity> },
}

type Storage = { [Entity]: EntityStorage }

export type Server = {
	world: World,
	inited: boolean?,

	shared: common.Shared,

	components: common.Components,
	hooks: common.WorldHooks,
	alive_tracked: Set<Entity>,

	track_info: TrackInfo,
	additions: Set<Entity>,
	custom_ids: Map<Entity, Entity<any>>,
	global_ids: Map<Entity, number>,
	storage: Storage,
	hooked: Array<() -> ()>,
	masking: masking_controller.MaskingController,
	pending_cleanups: Set<Entity>,
	connections: Array<RBXScriptConnection>,
	function_filters: masking_controller.EntityComponentIndex<FunctionFilter>,

	init: (self: Server, world: World?) -> (),
	destroy: (self: Server) -> (),

	get_full: (self: Server, player: Player) -> (buffer, { { any } }),
	collect_updates: (self: Server) -> () -> (Player, buffer, { { any } }),
	collect_unreliable: (self: Server) -> () -> (Player, buffer, { { any } }),
	mark_player_ready: (self: Server, player: Player) -> (),
	is_player_ready: (self: Server, player: Player) -> boolean,
}

local cursor = utils.cursor

local NIL_COMPONENT_VALUE = newproxy()
local GLOBAL_ID_OFFSET = 10

local COMPONENT_TYPES = masking_controller.COMPONENT_TYPES
local TRACK_TYPES = {
	component = 1,
	tag = 2,
	pair = 3,
}
local PACKET_TYPES = {
	full = 1,
	unreliable = 2,
	reliable = 3,
}
local MAX_PACKET_SIZE = 900
local ENTITY_ID_TYPES = {
	entity = 1,
	custom = 2,
	shared = 3,
	global = 4,
}
local ECS_COMPONENT = jecs.Component

local function IS_PAIR(id: Entity): boolean
	return jecs.IS_PAIR(id)
end
local function PAIR_SECOND(world: World, id: Entity): Entity
	return jecs.pair_second(world, id)
end

local function track_entity_lifetime(server: Server, entity: Entity)
	if server.alive_tracked[entity] then
		return
	end
	server.alive_tracked[entity] = true
	server.world:add(entity, server.components.__alive_tracking__)
end

local function get_or_set_entity_storage(server: Server, entity: Entity)
	local storage = server.storage[entity]

	if not storage then
		storage = {
			tags = {},
			values = {},
			pairs = {},
		}
		server.storage[entity] = storage
	end

	return storage
end

local function allocate_component_change(server: Server, entity: Entity, component: Entity, value: any)
	local storage = get_or_set_entity_storage(server, entity)

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value

	storage.values[component] = non_nil
	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_component_change(entity, component, non_nil)
	end
end
local function allocate_tag_addition(server: Server, entity: Entity, tag: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = true

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_tag_addition(entity, tag)
	end
end
local function allocate_pair_addition(server: Server, entity: Entity, relation: Entity, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets == nil then
		targets = {}
		storage.pairs[relation] = targets
	end
	targets[target] = true

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_pair_addition(entity, relation, target)
	end
end

local function allocate_component_removal(server: Server, entity: Entity, component: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.values[component] = nil

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_component_removal(entity, component)
	end
end
local function allocate_tag_removal(server: Server, entity: Entity, tag: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = nil

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_tag_removal(entity, tag)
	end
end
local function allocate_pair_removal(server: Server, entity: Entity, relation: Entity, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets then
		targets[target] = nil
	end

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_pair_removal(entity, relation, target)
	end
end

local function cleanup_entity(server: Server, entity: Entity)
	server.alive_tracked[entity] = nil
	server.storage[entity] = nil
	server.additions[entity] = nil
	server.masking:cleanup_entity(entity)
end

local function track_component(server: Server, component: Entity<any>)
	local world = server.world
	local hooks = server.hooks

	local info = {}
	server.track_info.components[component] = info

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, component, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_change(server, entity, component, value)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_addition(server, entity, component)
		else
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_addition(server, entity, component, PAIR_SECOND(world, id))
		end
	end))
	hook(hooks.changed(world, component, function(entity, _id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end
		-- no check here because only components can trigger changed (I think?)
		allocate_component_change(server, entity, component, value)
	end))
	hook(hooks.removed(world, component, function(entity, id)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_removal(server, entity, component)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_removal(server, entity, component)
		else
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_removal(server, entity, component, PAIR_SECOND(world, id))
		end
	end))

	return info
end

local function track_entity_component(server: Server, entity: Entity, component: Entity<any>)
	local world = server.world

	local info = server.track_info.components[component]
	if not info then
		info = track_component(server, component)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if world:has(component, ECS_COMPONENT) then
		-- component
		if world:has(entity, component) then
			local value = world:get(entity, component)

			if value == nil then
				entity_storage.values[component] = NIL_COMPONENT_VALUE
			else
				entity_storage.values[component] = value
			end
		end

		info[entity] = TRACK_TYPES.component

		return COMPONENT_TYPES.component
	else
		-- tag
		if world:has(entity, component) then
			entity_storage.tags[component] = true
		end
		info[entity] = TRACK_TYPES.tag

		return COMPONENT_TYPES.tag
	end
end

local function track_entity_pair(server: Server, entity: Entity, relation: Entity)
	local world = server.world
	local info = server.track_info.components[relation]
	if not info then
		info = track_component(server, relation)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)
	local targets = {}
	local index = 0

	while true do
		local target = world:target(entity, relation, index)
		if not target then
			break
		end
		index += 1
		targets[target] = true
	end
	entity_storage.pairs[relation] = targets

	info[entity] = TRACK_TYPES.pair
end

local function untrack_entity_component(server: Server, entity: Entity, component: Entity<any>): number?
	local info = server.track_info.components[component]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.values[component] = nil
		storage.tags[component] = nil
	end

	return listen_type
end

local function untrack_entity_pair(server: Server, entity: Entity, relation: Entity)
	local info = server.track_info.components[relation]
	if not info then
		return
	end
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.pairs[relation] = nil
	end
end

local function write_component_id(server: Server, c: Cursor, component: Entity)
	local encoded = server.shared.ids[component]
	if not encoded then
		utils.logerror(`attempted to replicate a non-shared component `, utils.logcomponent(server.world, component))
		return
	end
	cursor.writeu8(c, encoded)
end

local function write_component_value(server: Server, c: Cursor, component: Entity, value: any, variants: { any })
	local serdes = server.shared.serdes[component]
	if serdes then
		local output = serdes.serialize(if value == NIL_COMPONENT_VALUE then nil else value)

		local bytespan = server.shared.bytespan[component]
		cursor.write_buffer(c, output)
		if bytespan then
			if bytespan ~= buffer.len(output) then
				utils.logerror(
					`bytespan: {bytespan} mismatch for buffer lenght: {buffer.len(output)} in component`,
					utils.logcomponent(server.world, component)
				)
			end
		else
			local len = buffer.len(output)
			cursor.write_vlq(c, len)
		end
	else
		if value == NIL_COMPONENT_VALUE then
			-- 128 is zero for vlq
			cursor.writeu8(c, 128)
		else
			table.insert(variants, value :: any)
			cursor.write_vlq(c, #variants)
		end
	end

	write_component_id(server, c, component)
end

local function write_entity_id(server: Server, c: Cursor, entity: Entity, variants: { any }, multiply: number?)
	local custom = server.custom_ids[entity]
	local global_id = server.global_ids[entity]

	if global_id then
		if multiply then
			cursor.writei8(c, ENTITY_ID_TYPES.global * multiply)
			cursor.writeu8(c, global_id + GLOBAL_ID_OFFSET)
		else
			cursor.writei8(c, global_id + GLOBAL_ID_OFFSET)
		end
	elseif custom then
		local value = server.world:get(entity, custom)
		write_component_value(server, c, custom, value, variants)
		cursor.writei8(c, ENTITY_ID_TYPES.custom * (multiply or 1))
	else
		local shared_id = server.shared.ids[entity]
		if shared_id then
			cursor.writeu8(c, shared_id)
			cursor.writei8(c, ENTITY_ID_TYPES.shared * (multiply or 1))
		else
			cursor.writeu40(c, entity :: any)
			cursor.writei8(c, ENTITY_ID_TYPES.entity * (multiply or 1), entity)
		end
	end
end

local function write_entity_relations(
	server: Server,
	storage: EntityStorage,
	c: Cursor,
	relation: Entity,
	variants: { any }
)
	local targets = storage.pairs[relation]
	local total_targets = 0

	for target in targets do
		write_entity_id(server, c, target, variants)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	write_component_id(server, c, relation)
end

local function write_entity(
	server: Server,
	c: Cursor,
	entity: Entity,
	active: masking_controller.ActiveEntity,
	variants: { any }
)
	local storage = server.storage[entity]

	local all_pairs = 0
	for relation in active.components[COMPONENT_TYPES.pair] do
		write_entity_relations(server, storage, c, relation, variants)
		all_pairs += 1
	end
	cursor.write_vlq(c, all_pairs)

	local components = 0
	for component in active.components[COMPONENT_TYPES.component] do
		local value = storage.values[component]
		if value == nil then
			continue
		end

		write_component_value(server, c, component, value, variants)
		components += 1
	end
	cursor.write_vlq(c, components)

	local tags = 0
	for tag in active.components[COMPONENT_TYPES.tag] do
		local has_tag = storage.tags[tag]
		if has_tag then
			write_component_id(server, c, tag)
			tags += 1
		end
	end
	cursor.write_vlq(c, tags)
	write_entity_id(server, c, entity, variants)
end

type Packet = {
	buffer: buffer,
	variants: { { any } },
}
type MemberPackets = {
	packets: Array<Packet>,
	variants: { { any } },
	total_size: number,
}

local function append_packet(
	packets: { [Player]: MemberPackets },
	members: { any },
	output: buffer,
	variants: { { any } }
)
	local len = buffer.len(output)
	for _, member in members do
		local member_packets = packets[member]

		if member_packets then
			table.insert(member_packets.packets, {
				buffer = output,
				variants = variants,
			})
			member_packets.total_size += len
		else
			member_packets = {
				packets = {
					{
						buffer = output,
						variants = variants,
					},
				},
				total_size = len,
			}
			packets[member] = member_packets :: MemberPackets
		end
	end
end

local function combine_packet_outputs(outputs: Array<Packet>, total_size: number, id: number): (buffer, { { any } })
	local combined = buffer.create(total_size + utils.vlq_span(#outputs) + 1)
	local offset = 0
	local variants = table.create(#outputs) :: { { any } }

	for _, output in outputs do
		buffer.copy(combined, offset, output.buffer)
		offset += buffer.len(output.buffer)
		table.insert(variants, output.variants)
	end
	cursor.write_vlq({
		offset = offset,
		buffer = combined,
	}, #outputs)
	buffer.writeu8(combined, buffer.len(combined) - 1, id)

	return combined, variants
end

type PacketIterator = () -> (Player, buffer, { { any } })

local function create_packet_iterator(packets: { [Player]: MemberPackets }, id: number)
	local iterated: Player? = nil
	local function iterator()
		local player, data = next(packets, iterated)
		if not player then
			return nil :: any
		end
		iterated = player

		local combined, variants = combine_packet_outputs(data.packets, data.total_size, id)
		return player, combined, variants
	end
	return iterator :: PacketIterator
end

local function create_unreliable_packet_iterator(packets: { [Player]: MemberPackets })
	return coroutine.wrap(function()
		for player, data in packets do
			table.sort(data.packets, function(a, b)
				return buffer.len(a.buffer) < buffer.len(b.buffer)
			end)
			local total_packets = #data.packets

			local current_packet_index = 1
			while current_packet_index <= total_packets do
				local sending = {} :: { Packet }
				local total_size = 0

				while current_packet_index <= total_packets do
					local packet = data.packets[current_packet_index]
					local buffer_size = buffer.len(packet.buffer)

					if total_size + buffer_size > MAX_PACKET_SIZE and #sending > 0 then
						break
					end

					table.insert(sending, packet)
					total_size += buffer_size
					current_packet_index += 1

					if total_size >= MAX_PACKET_SIZE then
						break
					end
				end

				if #sending > 0 then
					coroutine.yield(player, combine_packet_outputs(sending, total_size, PACKET_TYPES.unreliable))
				end
			end
		end
	end) :: PacketIterator
end

local function get_full(server: Server, member: Player): (buffer, { { any } })
	local index = server.masking.member_indexes[member]
	if index == nil then
		utils.logerror "attempted to replicate for a non registered member"
	end
	local packets: Array<Packet> = {}
	local total_size = 0

	-- maybe edges to quickly find all relevant storages improves performance?
	for _, storage in server.masking.storages do
		if not storage.mask.bitmask:get(index) then
			continue
		end
		local c = cursor.new()
		local variants = {}

		local total_entities = 0
		for entity, active in storage.active do
			write_entity(server, c, entity, active, variants)
			total_entities += 1
		end
		cursor.write_vlq(c, total_entities)

		local output = cursor.close(c)
		table.insert(packets, {
			buffer = output,
			variants = variants,
		})
		total_size += buffer.len(output)
	end

	return combine_packet_outputs(packets, total_size, PACKET_TYPES.full)
end

local function write_vlq_bitmask(c: Cursor, value: number, mask: number, bit: number): number
	if value > 0 then
		cursor.write_vlq(c, value)
		return utils.setbit(mask, bit)
	else
		return mask
	end
end

local function collect_updates(server: Server)
	local packets: { [Player]: MemberPackets } = {}

	for _, storage in server.masking.storages do
		local c = cursor.new()

		local variants = {}
		local storage_mask = 0

		local total_deleted = 0
		local entity_deletions = storage.deletions.entities
		for entity in entity_deletions do
			write_entity_id(server, c, entity, variants)
			total_deleted += 1
		end
		table.clear(entity_deletions)
		storage_mask = write_vlq_bitmask(c, total_deleted, storage_mask, 4)

		local total_component_deleted = 0
		local component_deletions = storage.deletions.components
		for entity, deleted in component_deletions do
			local deleted_mask = 0

			local total_pairs = 0
			for relation in deleted[COMPONENT_TYPES.pair] do
				write_component_id(server, c, relation)
				total_pairs += 1
			end
			deleted_mask = write_vlq_bitmask(c, total_pairs, deleted_mask, 2)

			local total_components = 0
			for component in deleted[COMPONENT_TYPES.component] do
				write_component_id(server, c, component)
				total_components += 1
			end
			deleted_mask = write_vlq_bitmask(c, total_components, deleted_mask, 1)

			local total_tags = 0
			for tag in deleted[COMPONENT_TYPES.tag] do
				write_component_id(server, c, tag)
				total_tags += 1
			end
			deleted_mask = write_vlq_bitmask(c, total_tags, deleted_mask, 0)

			cursor.writeu8(c, deleted_mask)
			write_entity_id(server, c, entity, variants)
			total_component_deleted += 1
		end
		table.clear(component_deletions)
		storage_mask = write_vlq_bitmask(c, total_component_deleted, storage_mask, 3)

		local storage_changes = storage.changes
		local changed = 0
		for entity, changes in storage_changes.changed do
			local changed_mask = 0

			local total_removed = 0
			for component in changes.removed do
				write_component_id(server, c, component)
				total_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_removed, changed_mask, 3)

			local total_pairs = 0
			for relation, targets in changes.pairs do
				local total_targets = 0

				for target, added in targets do
					if added then
						write_entity_id(server, c, target, variants, 1)
					else
						write_entity_id(server, c, target, variants, -1)
					end
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				write_component_id(server, c, relation)
				total_pairs += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs, changed_mask, 2)

			local total_components = 0
			for component, value in changes.component do
				write_component_value(server, c, component, value, variants)
				total_components += 1
			end
			changed_mask = write_vlq_bitmask(c, total_components, changed_mask, 1)

			local total_tagged = 0
			for tag in changes.tagged do
				write_component_id(server, c, tag)
				total_tagged += 1
			end
			changed_mask = write_vlq_bitmask(c, total_tagged, changed_mask, 0)

			cursor.writeu8(c, changed_mask)
			write_entity_id(server, c, entity, variants)
			changed += 1
		end
		table.clear(storage_changes.changed)
		storage_mask = write_vlq_bitmask(c, changed, storage_mask, 2)

		local total_components_added = 0
		for entity, components in storage_changes.added_components do
			local entity_storage = server.storage[entity]
			local added_mask = 0

			local total_pairs = 0
			for relation in components[COMPONENT_TYPES.pair] do
				write_entity_relations(server, entity_storage, c, relation, variants)
				total_pairs += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs, added_mask, 2)

			local total_components = 0
			for component in components[COMPONENT_TYPES.component] do
				local value = entity_storage.values[component]
				if value == nil then
					continue
				end
				write_component_value(server, c, component, value, variants)
				total_components += 1
			end
			added_mask = write_vlq_bitmask(c, total_components, added_mask, 1)

			local total_tags = 0
			for component in components[COMPONENT_TYPES.tag] do
				local has_tag = entity_storage.tags[component]
				if has_tag then
					write_component_id(server, c, component)
					total_tags += 1
				end
			end
			added_mask = write_vlq_bitmask(c, total_tags, added_mask, 0)

			cursor.writeu8(c, added_mask)
			write_entity_id(server, c, entity, variants)
			total_components_added += 1
		end
		table.clear(storage_changes.added_components)
		storage_mask = write_vlq_bitmask(c, total_components_added, storage_mask, 1)

		local total_added = 0
		for entity in storage_changes.added do
			local active = storage.active[entity]
			if not active then
				continue
			end

			write_entity(server, c, entity, active, variants)
			total_added += 1
		end
		table.clear(storage_changes.added)
		storage_mask = write_vlq_bitmask(c, total_added, storage_mask, 0)

		cursor.writeu8(c, storage_mask)
		local output = cursor.close(c)
		append_packet(packets, storage.mask.members, output, variants)
	end
	table.clear(server.additions)
	return create_packet_iterator(packets, PACKET_TYPES.reliable)
end

local function collect_unreliable(server: Server)
	local world = server.world
	local packets: { [Player]: MemberPackets } = {}

	for _, mask_storage in server.masking.storages do
		local active = mask_storage.active

		local c = cursor.new()
		local variants = {} :: { { any } }
		local total_entities = 0

		local checkpoint_offset = 0
		local checkpoint_variants_count = 0
		local checkpoint_total_entities = 0

		local function create_checkpoint()
			checkpoint_offset = c.offset
			checkpoint_variants_count = #variants
			checkpoint_total_entities = total_entities
		end

		local function rollback_checkpoint()
			local new_cursor = cursor.new()
			cursor.write_buffer(new_cursor, c.buffer, checkpoint_offset, c.offset - checkpoint_offset)
			c.offset = checkpoint_offset
			c = new_cursor

			local new_variants = {} :: { { any } }
			for _ = #variants, checkpoint_variants_count + 1, -1 do
				table.insert(new_variants, 1, table.remove(variants))
			end
			variants = new_variants
			total_entities = total_entities - checkpoint_total_entities
		end

		local function commit_checkpoint(commit_c, commit_variants, commit_total_entities)
			if commit_total_entities <= 0 then
				return
			end

			cursor.write_vlq(commit_c, commit_total_entities)
			local output = cursor.close(commit_c)
			append_packet(packets, mask_storage.mask.members, output, commit_variants)
		end

		for entity, actives in active do
			create_checkpoint()

			local total_unreliable = 0
			for component in actives.components[COMPONENT_TYPES.unreliable] do
				local value = world:get(entity, component)
				if value == nil then
					continue
				end

				write_component_value(server, c, component, value, variants)
				total_unreliable += 1
			end

			if total_unreliable <= 0 then
				continue
			end
			total_entities += 1
			cursor.write_vlq(c, total_unreliable)
			write_entity_id(server, c, entity, variants)

			if c.offset > MAX_PACKET_SIZE then
				local commit_cursor = c
				local commit_variants = variants
				rollback_checkpoint()
				commit_checkpoint(commit_cursor, commit_variants, checkpoint_total_entities)
			end
		end
		commit_checkpoint(c, variants, total_entities)
	end

	return create_unreliable_packet_iterator(packets)
end

local function check_created(server: Server)
	if server.inited == true then
		warn "attempted to init a server twice"
		return false
	end
	if server.inited == nil then
		warn "attempted to create a server twice"
		return false
	end
	return true
end

function init(server: Server, _world: World?)
	if not check_created(server) then
		return
	end
	server.inited = true :: any

	local world = _world or server.world
	server.world = world

	if not world then
		error "Providing a world is required to start replecs"
	end

	local hooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	server.hooks = hooks

	local components = server.components
	local masking = server.masking

	server.shared = utils.create_shared_lookup(world, components)

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, components.networked, function(entity, _id, filter)
		masking:unregister_stop_entity(entity)
		masking:start_entity(entity, filter)
		masking:propagate_entity_addition(entity)

		server.additions[entity] = true
		server.track_info.entities[entity] = true
		track_entity_lifetime(server, entity)
	end))
	hook(hooks.changed(world, components.networked, function(entity, _id, filter)
		masking:set_entity(entity, filter)
	end))
	hook(hooks.removed(world, components.networked, function(entity)
		masking:register_stop_entity(entity)
		masking:stop_entity(entity)

		server.additions[entity] = nil
		server.track_info.entities[entity] = nil
		if server.pending_cleanups[entity] then
			server.pending_cleanups[entity] = nil
			cleanup_entity(server, entity)
		end
	end))

	hook(hooks.added(world, components.reliable, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "reliable should be used with a pair relationship"
		end
		local component = PAIR_SECOND(world, id)

		local component_type = track_entity_component(server :: Server, entity, component)
		masking:unregister_stop_component(entity, component, component_type)
		masking:start_component(entity, component, component_type, filter)
		if server.additions[entity] then
			masking:allocate_entity_addition(entity, component, component_type)
		elseif server.track_info.entities[entity] then
			masking:register_component_addition(entity, component, component_type)
		end
	end))
	hook(hooks.changed(world, components.reliable, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "reliable should be used with a pair relationship"
		end
		local component = PAIR_SECOND(world, id)

		if world:has(component, ECS_COMPONENT) then
			masking:set_component(entity, component, COMPONENT_TYPES.component, filter)
		else
			masking:set_component(entity, component, COMPONENT_TYPES.tag, filter)
		end
	end))
	hook(hooks.removed(world, components.reliable, function(entity, id)
		if not IS_PAIR(id) then
			utils.logerror "reliable should be used with a pair relationship"
		end
		if not server.track_info.entities[entity] then
			return
		end

		local component = PAIR_SECOND(world, id)
		local component_type = untrack_entity_component(server, entity, component)
		if not component_type then
			return
		end
		masking:unregister_component_addition(entity, component, component_type)
		masking:register_stop_component(entity, component, component_type)
		masking:stop_component(entity, component, component_type)
	end))

	hook(hooks.added(world, components.pair, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "pair should be used with a relationship"
		end
		local relation = PAIR_SECOND(world, id)
		track_entity_pair(server, entity, relation)
		masking:unregister_stop_component(entity, relation, COMPONENT_TYPES.pair)
		masking:start_component(entity, relation, COMPONENT_TYPES.pair, filter)
		if server.additions[entity] then
			masking:allocate_entity_addition(entity, relation, COMPONENT_TYPES.pair)
		elseif server.track_info.entities[entity] then
			masking:register_component_addition(entity, relation, COMPONENT_TYPES.pair)
		end
	end))
	hook(hooks.changed(world, components.pair, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "reliable should be used with a pair relationship"
		end
		local relation = PAIR_SECOND(world, id)
		masking:set_component(entity, relation, COMPONENT_TYPES.pair, filter)
	end))
	hook(hooks.removed(world, components.pair, function(entity, id)
		if not IS_PAIR(id) then
			utils.logerror "reliable should be used with a pair relationship"
		end
		if not server.track_info.entities[entity] then
			return
		end

		local relation = PAIR_SECOND(world, id)
		untrack_entity_pair(server, entity, relation)
		masking:unregister_component_addition(entity, relation, COMPONENT_TYPES.pair)
		masking:register_stop_component(entity, relation, COMPONENT_TYPES.pair)
		masking:stop_component(entity, relation, COMPONENT_TYPES.pair)
	end))

	hook(hooks.added(world, components.unreliable, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "unreliable should be used with a pair relationship"
		end
		local component = PAIR_SECOND(world, id)
		masking:unregister_stop_component(entity, component, COMPONENT_TYPES.unreliable)
		masking:start_component(entity, component, COMPONENT_TYPES.unreliable, filter)
		if server.additions[entity] then
			masking:allocate_entity_addition(entity, component, COMPONENT_TYPES.unreliable)
		end
	end))
	hook(hooks.changed(world, components.unreliable, function(entity, id, filter)
		if not IS_PAIR(id) then
			utils.logerror "unreliable should be used with a pair relationship"
		end
		local component = PAIR_SECOND(world, id)
		masking:set_component(entity, component, COMPONENT_TYPES.unreliable, filter)
	end))
	hook(hooks.removed(world, components.unreliable, function(entity, id)
		if not IS_PAIR(id) then
			utils.logerror "unreliable should be used with a pair relationship"
		end
		if not server.track_info.entities[entity] then
			return
		end

		local component = PAIR_SECOND(world, id)
		untrack_entity_component(server, entity, component)
		masking:register_stop_component(entity, component, COMPONENT_TYPES.unreliable)
		masking:stop_component(entity, component, COMPONENT_TYPES.unreliable)
	end))

	hook(hooks.added(world, components.custom_id, function(entity, id)
		if not IS_PAIR(id) then
			utils.logerror "custom_id should be used with a relationship in the server"
		end
		local target = PAIR_SECOND(world, id)
		if server.custom_ids[entity] then
			utils.logwarn("attempted to register a custom_id twice for the same entity", debug.traceback())
			return
		end

		server.custom_ids[entity] = target
	end))
	hook(hooks.removed(world, components.custom_id, function(entity)
		server.custom_ids[entity] = nil
	end))
	hook(hooks.added(world, components.global_id, function(entity, _, value)
		if value > 245 then
			utils.logerror "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))

	hook(hooks.changed(world, components.global_id, function(entity, _, value)
		if value > 245 then
			utils.logerror "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))
	hook(hooks.removed(world, components.global_id, function(entity)
		server.global_ids[entity] = nil
	end))

	hook(hooks.removed(world, components.__alive_tracking__, function(entity)
		if server.track_info.entities[entity] then
			-- This is in case alive tracking removal is called before networked removal
			server.pending_cleanups[entity] = true
		else
			cleanup_entity(server, entity)
		end
	end))

	if game and game:GetService("RunService"):IsServer() then
		local added = game:GetService("Players").PlayerAdded:Connect(function(player)
			server.masking:register_member(player)
		end)
		local removed = game:GetService("Players").PlayerRemoving:Connect(function(player)
			server.masking:unregister_member(player)
		end)

		table.insert(server.connections, added)
		table.insert(server.connections, removed)
	end
end

local function mark_player_ready(server: Server, player: Player)
	server.masking:activate_member(player)
end

local function is_player_ready(server: Server, player: Player): boolean
	return server.masking:member_is_active(player)
end

local function destroy(server: Server)
	if server.inited == nil then
		return warn "attempted to destroy a server twice"
	end
	server.inited = nil :: any

	for _, unhook in server.hooked do
		unhook()
	end
	for _, connection in server.connections do
		connection:Disconnect()
	end
end

local server = {}
server.__index = server
server.init = init
server.destroy = destroy
server.get_full = get_full
server.collect_updates = collect_updates
server.collect_unreliable = collect_unreliable
server.mark_player_ready = mark_player_ready
server.is_player_ready = is_player_ready

local function create(world: World?, components: common.Components): Server
	local self = {} :: Server

	self.components = components

	self.shared = {} :: common.Shared
	self.world = world :: any
	self.additions = {}
	self.storage = {}
	self.hooked = {}
	self.global_ids = {}
	self.pending_cleanups = {}
	self.track_info = {
		entities = {},
		components = {},
	}
	self.connections = {}
	self.inited = false
	self.masking = masking_controller.create()
	self.alive_tracked = {}
	self.custom_ids = {}

	return setmetatable(self, server) :: any
end

server.create = create

return server :: { create: typeof(create) }
