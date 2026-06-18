local Utils = {}

-- Clones a table and all its subtables
-- tbl: The table to clone
function Utils.deepCloneTable(tbl)
	local clone = {}
	for key, value in pairs(tbl) do
		if typeof(value) == "table" then
			clone[key] = Utils.deepCloneTable(value)
		else
			clone[key] = value
		end
	end
	return clone
end

-- Check if two tables have all the same values
-- a, b: Tables to compare
function Utils.tablesEqual(a, b)
	-- If the same table was passed twice
	if a == b then
		return true
	end
	-- If either is not a table
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end

	-- Loop through and check if every value is equal to each other
	for key, value in pairs(a) do
		if not Utils.tablesEqual(value, b[key]) then
			return false
		end
	end

	-- Make sure no values are missing
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end

	return true
end

return Utils
