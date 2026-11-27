-- Shared spill-to-file helper for oversized hook outputs and disclosure contexts.
local M = {
	PREFIX = "hooks",
}

function M.new_path()
	local state_dir = mare.paths and mare.paths.state
	if type(state_dir) ~= "string" or state_dir == "" then
		return nil
	end
	local pid = type(mare.pid) == "number" and mare.pid or 0
	local stamp = type(mare.date) == "function" and mare.date("%Y%m%d-%H%M%S") or "0"
	local rand = mare.crypto and type(mare.crypto.random_hex) == "function" and mare.crypto.random_hex(3)
		or string.format("%06x", math.random(0, 0xffffff))
	return string.format("%s/spill/%s-%d-%s-%s.log", state_dir, M.PREFIX, pid, stamp, rand)
end

function M.write(text)
	if type(text) ~= "string" then
		return nil, "spill payload must be a string"
	end
	local path = M.new_path()
	if not path then
		return nil, "spill path unavailable (missing mare.paths.state)"
	end
	if not (mare.proc and type(mare.proc.spill_write) == "function") then
		return nil, "mare.proc.spill_write is unavailable"
	end
	local ok, err = pcall(mare.proc.spill_write, M.PREFIX, path, text)
	if not ok then
		return nil, tostring(err)
	end
	return path
end

function M.remove(path)
	if path and mare.proc and type(mare.proc.spill_remove) == "function" then
		pcall(mare.proc.spill_remove, M.PREFIX, path)
	end
end

function M.preview(text, path, max_bytes)
	max_bytes = max_bytes or 8192
	local trailer = string.format("\n\n[Full hook output (%d bytes) saved to %s]", #text, path)
	local sep = "\n\n... [truncated] ...\n\n"
	local budget = max_bytes - #trailer - #sep
	if budget < 64 then
		return mare.text.cut(trailer, max_bytes)
	end
	if #text <= budget then
		return text .. trailer
	end
	local half = math.floor(budget / 2)
	return mare.text.cut(text, half) .. sep .. mare.text.cut(text, budget - half, { keep = "tail" }) .. trailer
end

function M.cap_context(text, max_bytes)
	max_bytes = max_bytes or 65536
	if #text <= max_bytes then
		return text, nil
	end
	local path, err = M.write(text)
	if not path then
		return nil, err or "hook context exceeds disclosure limit"
	end
	return M.preview(text, path, math.min(max_bytes, 8192)), nil
end

return M
