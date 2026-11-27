-- Safe UTF-8 text only; PTY parsing and queue budgets belong to the public Rust primitive.
local M = {}

local function scan_newlines(text)
	local nl
	local pos = 1
	while true do
		local idx = text:find("\n", pos, true)
		if not idx then
			break
		end
		if not nl then
			nl = { idx }
		else
			nl[#nl + 1] = idx
		end
		pos = idx + 1
	end
	return nl
end

function M.new(max_bytes, max_lines)
	local chunks = {}
	local head, tail = 1, 0
	local head_offset, head_nl_idx = 0, 1
	local total_bytes, total_lines = 0, 0
	local coalesce_limit = math.min(1024, math.max(0, max_bytes))

	local b = { start = 0, finish = 0, dropped = false }
	setmetatable(b, {
		__index = function(_, key)
			if key == "text" then
				if head > tail then
					return ""
				end
				if head == tail then
					return chunks[head].text:sub(head_offset + 1)
				end
				local parts = { chunks[head].text:sub(head_offset + 1) }
				for i = head + 1, tail do
					parts[#parts + 1] = chunks[i].text
				end
				return table.concat(parts)
			end
		end,
	})

	local function reset_empty_if_needed()
		if head > tail then
			chunks = {}
			head, tail = 1, 0
			head_offset, head_nl_idx = 0, 1
		end
	end

	local function slice_chunk_prefix(c, offset, nl_idx)
		local rem_text = c.text:sub(offset + 1)
		local rem_nl
		if c.nl and nl_idx <= #c.nl then
			rem_nl = {}
			for i = nl_idx, #c.nl do
				rem_nl[#rem_nl + 1] = c.nl[i] - offset
			end
		end
		return { text = rem_text, nl = rem_nl }
	end

	local function compact_head_chunk()
		if head > tail or head_offset <= 0 then
			return
		end
		local c = chunks[head]
		local len = #c.text
		if head_offset * 2 < len and len <= max_bytes then
			return
		end
		chunks[head] = slice_chunk_prefix(c, head_offset, head_nl_idx)
		head_offset = 0
		head_nl_idx = 1
	end

	local function drop_bytes(self, n)
		local rem = n
		while rem > 0 and head <= tail do
			local c = chunks[head]
			local avail = #c.text - head_offset
			if rem >= avail then
				if c.nl then
					total_lines = total_lines - (#c.nl - head_nl_idx + 1)
				end
				total_bytes = total_bytes - avail
				self.start = self.start + avail
				rem = rem - avail
				chunks[head] = nil
				head = head + 1
				head_offset = 0
				head_nl_idx = 1
			else
				local new_offset = head_offset + rem
				if c.nl then
					local nl = c.nl
					local nl_count = #nl
					while head_nl_idx <= nl_count and nl[head_nl_idx] <= new_offset do
						total_lines = total_lines - 1
						head_nl_idx = head_nl_idx + 1
					end
				end
				head_offset = new_offset
				total_bytes = total_bytes - rem
				self.start = self.start + rem
				rem = 0
			end
		end
		reset_empty_if_needed()
		self.dropped = true
	end

	local function drop_newlines(self, count)
		local to_drop = count
		while to_drop > 0 and head <= tail do
			local c = chunks[head]
			local nl = c.nl
			local rem_nl = nl and (#nl - head_nl_idx + 1) or 0
			if rem_nl < to_drop then
				local avail = #c.text - head_offset
				total_lines = total_lines - rem_nl
				total_bytes = total_bytes - avail
				self.start = self.start + avail
				to_drop = to_drop - rem_nl
				chunks[head] = nil
				head = head + 1
				head_offset = 0
				head_nl_idx = 1
			else
				local target_idx = head_nl_idx + to_drop - 1
				local nl_pos = nl[target_idx]
				local drop_len = nl_pos - head_offset
				total_lines = total_lines - to_drop
				total_bytes = total_bytes - drop_len
				self.start = self.start + drop_len
				to_drop = 0
				if nl_pos >= #c.text then
					chunks[head] = nil
					head = head + 1
					head_offset = 0
					head_nl_idx = 1
				else
					head_offset = nl_pos
					head_nl_idx = target_idx + 1
				end
			end
		end
		reset_empty_if_needed()
		self.dropped = true
	end

	function b:append(text)
		if #text > 0 then
			self.finish = self.finish + #text
			local nl = scan_newlines(text)
			local coalesced = false
			if head <= tail and #text < coalesce_limit then
				local last = chunks[tail]
				local visible_len = head == tail and (#last.text - head_offset) or #last.text
				if visible_len + #text <= coalesce_limit then
					if head == tail and head_offset > 0 then
						last = slice_chunk_prefix(last, head_offset, head_nl_idx)
						chunks[head] = last
						head_offset = 0
						head_nl_idx = 1
					end
					local base_len = #last.text
					last.text = last.text .. text
					if nl then
						local dst = last.nl
						if not dst then
							dst = {}
							last.nl = dst
						end
						for i = 1, #nl do
							dst[#dst + 1] = base_len + nl[i]
						end
					end
					coalesced = true
				end
			end
			if not coalesced then
				tail = tail + 1
				chunks[tail] = { text = text, nl = nl }
			end
			total_bytes = total_bytes + #text
			if nl then
				total_lines = total_lines + #nl
			end
		end

		if total_bytes > max_bytes then
			drop_bytes(self, total_bytes - max_bytes)
		end

		if total_lines >= max_lines and total_lines > 0 then
			local to_drop = math.min(total_lines, total_lines - max_lines + 1)
			drop_newlines(self, to_drop)
		end

		while head <= tail do
			local c = chunks[head]
			local byte = c.text:byte(head_offset + 1)
			if byte < 128 or byte >= 192 then
				break
			end
			head_offset = head_offset + 1
			total_bytes = total_bytes - 1
			self.start = self.start + 1
			self.dropped = true
			if head_offset >= #c.text then
				chunks[head] = nil
				head = head + 1
				head_offset = 0
				head_nl_idx = 1
			end
		end
		reset_empty_if_needed()
		compact_head_chunk()
	end

	function b:delta(cursor, delta_max_bytes)
		local begin = math.max(cursor, self.start)
		local avail = self.finish - begin
		local truncated = cursor < self.start or avail > delta_max_bytes
		if avail <= 0 or delta_max_bytes <= 0 then
			return "", self.finish, truncated
		end
		local need = avail > delta_max_bytes and delta_max_bytes or avail
		local start_idx, start_pos
		local rem = need
		for i = tail, head, -1 do
			local c = chunks[i]
			local c_start = i == head and head_offset or 0
			local c_avail = #c.text - c_start
			if c_avail >= rem then
				start_idx = i
				start_pos = #c.text - rem + 1
				break
			end
			rem = rem - c_avail
		end
		if not start_idx then
			return "", self.finish, truncated
		end
		if avail > delta_max_bytes then
			while start_idx <= tail do
				local c = chunks[start_idx]
				local byte = c.text:byte(start_pos)
				if (byte & 192) ~= 128 then
					break
				end
				start_pos = start_pos + 1
				if start_pos > #c.text then
					start_idx = start_idx + 1
					start_pos = 1
				end
			end
		end
		if start_idx > tail then
			return "", self.finish, truncated
		end
		if start_idx == tail then
			return chunks[tail].text:sub(start_pos), self.finish, truncated
		end
		local parts = { chunks[start_idx].text:sub(start_pos) }
		for i = start_idx + 1, tail do
			parts[#parts + 1] = chunks[i].text
		end
		return table.concat(parts), self.finish, truncated
	end

	function b:read_at(offset, read_max_bytes)
		local req = math.max(0, math.floor(offset or 0))
		local dropped = math.max(0, self.start - req)
		local begin = math.max(req, self.start)
		local avail = self.finish - begin
		if avail <= 0 or read_max_bytes <= 0 then
			return "", begin, dropped
		end
		local need = avail > read_max_bytes and read_max_bytes or avail
		local skip = begin - self.start
		local idx = head
		local pos = head_offset + 1
		while idx <= tail and skip > 0 do
			local c = chunks[idx]
			local c_avail = #c.text - pos + 1
			if skip < c_avail then
				pos = pos + skip
				skip = 0
				break
			end
			skip = skip - c_avail
			idx = idx + 1
			pos = 1
		end
		if idx > tail then
			return "", self.finish, dropped
		end
		local parts = {}
		local rem = need
		while idx <= tail and rem > 0 do
			local c = chunks[idx]
			local c_avail = #c.text - pos + 1
			if c_avail <= rem then
				parts[#parts + 1] = c.text:sub(pos)
				rem = rem - c_avail
				idx = idx + 1
				pos = 1
			else
				parts[#parts + 1] = c.text:sub(pos, pos + rem - 1)
				rem = 0
			end
		end
		local text = table.concat(parts)
		if avail > read_max_bytes and #text > 0 then
			local len = #text
			local lead = len
			local min_lead = math.max(1, len - 3)
			while lead >= min_lead and (text:byte(lead) & 192) == 128 do
				lead = lead - 1
			end
			local b0 = text:byte(lead)
			if b0 >= 192 then
				local seq_len = b0 < 224 and 2 or (b0 < 240 and 3 or 4)
				if (len - lead + 1) < seq_len then
					text = text:sub(1, lead - 1)
				end
			end
		end
		return text, begin + #text, dropped
	end

	return b
end
return M
