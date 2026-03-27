---@param cmd_name string
---@return string|nil, string|nil
local function split_command_prefix(cmd_name)
	local name = tostring(cmd_name or "")
	local prefix, rest = name:match("^(%w+)%-(.+)$")
	if not prefix or not rest then
		return nil, nil
	end
	return prefix, rest
end

---@param command_map table<string, string>|nil
---@param cmd_name string
---@param cmd_string string
---@param is_c_family boolean
---@return boolean
local function is_redundant_system_alias(command_map, cmd_name, cmd_string, is_c_family)
	if not is_c_family then
		return false
	end
	local name = tostring(cmd_name or "")
	local base_name = name:match("^cmake%-(.+)$") or name:match("^meson%-(.+)$")
	if not base_name then
		return false
	end
	if not base_name or base_name:find("%-") then
		return false
	end
	local generic_command = command_map and command_map[base_name] or nil
	return type(generic_command) == "string" and generic_command == cmd_string
end

---@type table
local M = {}

---@param cmd table
---@param common_command_order table<string, integer>
---@param profile_command_order table<string, integer>
---@return string
function M.command_section(cmd, common_command_order, profile_command_order)
	local name = tostring(cmd.name or "")
	local prefix, rest = split_command_prefix(name)
	local semantic_name = rest or name

	if prefix and (prefix == "cmake" or prefix == "meson") then
		if rest and (rest:match("^build%-.+$") or rest:match("^run%-.+$")) then
			return "targets"
		end
		if common_command_order[rest] then
			return "common"
		end
		if profile_command_order[rest] then
			return "profiles"
		end
	end

	if common_command_order[semantic_name] then
		return "common"
	end
	if profile_command_order[semantic_name] then
		return "profiles"
	end
	return "other"
end

---@param cmd table
---@param last_selected_name string|nil
---@param common_command_order table<string, integer>
---@param profile_command_order table<string, integer>
---@param section_order table<string, integer>
---@return integer
local function command_sort_rank(cmd, last_selected_name, common_command_order, profile_command_order, section_order)
	local section = M.command_section(cmd, common_command_order, profile_command_order)
	local name = tostring(cmd.name or "")
	local _, rest = split_command_prefix(name)
	local semantic_name = rest or name
	if last_selected_name and name == last_selected_name then
		return -1000
	end
	local section_rank = section_order[section] or 99
	local name_rank = common_command_order[semantic_name]
		or profile_command_order[semantic_name]
		or 999
	return section_rank * 1000 + name_rank
end

---@param command_map table<string, string>|nil
---@param command_meta table<string, table>|nil
---@param is_c_family boolean
---@param last_selected_name string|nil
---@param common_command_order table<string, integer>
---@param profile_command_order table<string, integer>
---@param section_order table<string, integer>
---@return table[]
function M.build_command_list(
	command_map,
	command_meta,
	is_c_family,
	last_selected_name,
	common_command_order,
	profile_command_order,
	section_order
)
	---@type table[]
	local entries = {}
	for cmd_name, cmd_string in pairs(command_map or {}) do
		if not is_redundant_system_alias(command_map, cmd_name, cmd_string, is_c_family) then
			local meta = type(command_meta) == "table" and command_meta[cmd_name] or nil
			entries[#entries + 1] = {
				name = cmd_name,
				command = cmd_string,
				display_command = type(meta) == "table" and meta.display_command or cmd_string,
				requires_arguments = type(meta) == "table" and meta.requires_arguments == true or false,
				argument_prompt = type(meta) == "table" and meta.argument_prompt or nil,
				argument_help = type(meta) == "table" and meta.argument_help or nil,
			}
		end
	end

	table.sort(entries, function(a, b)
		local rank_a = command_sort_rank(
			a,
			last_selected_name,
			common_command_order,
			profile_command_order,
			section_order
		)
		local rank_b = command_sort_rank(
			b,
			last_selected_name,
			common_command_order,
			profile_command_order,
			section_order
		)
		if rank_a == rank_b then
			return a.name < b.name
		end
		return rank_a < rank_b
	end)

	if not is_c_family then
		return entries
	end

	---@type table<string, table>
	local by_name = {}
	for _, entry in ipairs(entries) do
		by_name[entry.name] = entry
	end

	---@type table[]
	local pruned = {}
	for _, entry in ipairs(entries) do
		local base_name = entry.name:match("^cmake%-(.+)$") or entry.name:match("^meson%-(.+)$")
		local generic_entry = base_name and by_name[base_name] or nil
		local is_target_specific = type(base_name) == "string" and base_name:find("%-") ~= nil
		if not (base_name and not is_target_specific and generic_entry and generic_entry.command == entry.command) then
			pruned[#pruned + 1] = entry
		end
	end
	return pruned
end

return M
