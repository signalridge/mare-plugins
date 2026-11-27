-- Independent FIFO permit for goal-state serialization.
-- mare task channels retain the caller's execution context; no host worker is used.
return function(on_abandon)
	local held, waiting = false, {}
	local function release()
		while #waiting > 0 do
			local next = table.remove(waiting, 1)
			if not next.cancelled then
				next.granted = true
				if next.tx:send(true) then
					return
				end
				next.granted = false
			end
		end
		held = false
	end
	return function(fn, owner)
		local mine = { granted = false, cancelled = false, finished = false }
		local guard <close> = setmetatable({}, {
			__close = function()
				if mine.granted then
					mine.granted = false
					if not mine.finished and on_abandon then
						on_abandon(owner)
					end
					release()
				else
					mine.cancelled = true
				end
			end,
		})
		if held then
			local rx
			mine.tx, rx = mare.task.channel()
			waiting[#waiting + 1] = mine
			rx:recv()
		else
			held = true
			mine.granted = true
		end
		local result = table.pack(fn())
		mine.finished = true
		return table.unpack(result, 1, result.n)
	end
end
