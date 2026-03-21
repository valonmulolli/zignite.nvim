---@type table
local M = {}

---@param order string[]
---@param key string
---@return nil
function M.touch_cache_key(order, key)
	for index, existing in ipairs(order) do
		if existing == key then
			table.remove(order, index)
			break
		end
	end
	order[#order + 1] = key
end

---@param cache table<string, any>
---@param order string[]
---@param max_entries integer
---@param key string
---@param value any
---@return nil
function M.set_bounded_cache_entry(cache, order, max_entries, key, value)
	if type(key) ~= "string" or key == "" then
		return
	end
	cache[key] = value
	M.touch_cache_key(order, key)
	while #order > max_entries do
		local oldest = table.remove(order, 1)
		if oldest ~= nil then
			cache[oldest] = nil
		end
	end
end

---@param cache table<string, any>
---@param order string[]
---@param key string
---@return any
function M.get_bounded_cache_entry(cache, order, key)
	local value = cache[key]
	if value ~= nil and type(key) == "string" and key ~= "" then
		M.touch_cache_key(order, key)
	end
	return value
end

---@param tbl table<string, string>|nil
---@return table<string, string>
function M.copy_string_map(tbl)
	---@type table<string, string>
	local out = {}
	if type(tbl) ~= "table" then
		return out
	end
	for key, value in pairs(tbl) do
		if type(key) == "string" and type(value) == "string" then
			out[key] = value
		end
	end
	return out
end

return M
