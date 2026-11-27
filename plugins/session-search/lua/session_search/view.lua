local M = {}
local function safe(s)
	return tostring(s or ""):gsub("[%z\1-\8\11\12\14-\31\127]", " ")
end
local function format_time(ts)
	if type(ts) == "number" and ts >= 0 then
		return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ts / 1000))
	end
	return safe(ts)
end
local function append_neighbors(lines, neighbors)
	for _, n in ipairs(neighbors or {}) do
		local ev_id = n.event_id and (" · " .. safe(n.event_id)) or ""
		lines[#lines + 1] = ("Neighbor seq %s%s | %s\n%s"):format(safe(n.seq), ev_id, safe(n.type), safe(n.summary))
	end
end
local function format_hits(value)
	if #value.data == 0 then
		local message = value.incomplete and "No matches in the inspected history; some sources could not be searched."
			or "No matching history."
		return message
			.. (
				value.coverage
					and value.coverage.live == false
					and "\nSource coverage: persisted sessions only; live observations are unavailable."
				or ""
			)
	end
	local lines = {}
	for i, hit in ipairs(value.data) do
		local avail = hit.availability and (" [" .. safe(hit.availability) .. "]") or ""
		local arch = hit.archived == true and " [archived]" or ""
		lines[#lines + 1] = ("%d. Session %s — %s%s%s"):format(
			i,
			safe(hit.session_id),
			safe(hit.title ~= "" and hit.title or "Untitled"),
			avail,
			arch
		)
		local meta = {}
		if hit.surface then
			meta[#meta + 1] = safe(hit.surface)
		end
		if hit.type then
			meta[#meta + 1] = safe(hit.type)
		end
		if hit.updated_at_ms then
			meta[#meta + 1] = "updated " .. format_time(hit.updated_at_ms)
		elseif hit.matched_at_ms then
			meta[#meta + 1] = "at " .. format_time(hit.matched_at_ms)
		elseif hit.session_created_at_ms then
			meta[#meta + 1] = "created " .. format_time(hit.session_created_at_ms)
		end
		lines[#lines + 1] = "   Event: "
			.. safe(hit.event_id)
			.. " · seq "
			.. safe(hit.position and hit.position.seq)
			.. (#meta > 0 and (" · " .. table.concat(meta, " · ")) or "")
		lines[#lines + 1] = "   " .. safe(hit.snippet)
	end
	if value.capped then
		lines[#lines + 1] = "Result limit reached. Narrow the query or add filters."
	end
	if value.incomplete then
		lines[#lines + 1] = "Some history sources were not inspected; these results are incomplete."
	end
	if value.coverage and value.coverage.live == false then
		lines[#lines + 1] = "Source coverage: persisted sessions only; live observations are unavailable."
	end
	return table.concat(lines, "\n")
end

local function format_lineage(value)
	local created = value.target.created_at_ms and (" (created " .. format_time(value.target.created_at_ms) .. ")")
		or ""
	local lines = { "Session " .. safe(value.target.session_id) .. created, "Ancestors (nearest first):" }
	for _, ancestor in ipairs(value.ancestors) do
		local a_created = ancestor.created_at_ms and (" (created " .. format_time(ancestor.created_at_ms) .. ")") or ""
		lines[#lines + 1] = "- " .. safe(ancestor.session_id) .. a_created
	end
	if value.parent_boundary then
		lines[#lines + 1] = "- [outside the authorized corpus]"
	elseif #value.ancestors == 0 then
		lines[#lines + 1] = "- none (target is a root session)"
	end
	lines[#lines + 1] = "Descendants:"
	local function visit(nodes, depth)
		for _, node in ipairs(nodes) do
			local d_created = node.session.created_at_ms
					and (" (created " .. format_time(node.session.created_at_ms) .. ")")
				or ""
			lines[#lines + 1] = string.rep("  ", depth) .. "- " .. safe(node.session.session_id) .. d_created
			visit(node.descendants or {}, depth + 1)
		end
	end
	if #value.descendants == 0 then
		lines[#lines + 1] = "- none"
	else
		visit(value.descendants, 0)
	end
	if value.incomplete then
		lines[#lines + 1] = "Some metadata sources were unavailable."
	end
	lines[#lines + 1] = value.coverage
			and value.coverage.live
			and "Source coverage: authorized persisted and live session headers; titles are unavailable."
		or "Source coverage: authorized persisted headers; live observations and titles are unavailable."
	return table.concat(lines, "\n")
end

local function seq_list(items)
	local out = {}
	for _, v in ipairs(items or {}) do
		out[#out + 1] = safe(v)
	end
	return #out > 0 and table.concat(out, ", ") or "none"
end

local function format_trace(value)
	local lines = {
		("Session %s · event %s (%s, surface: %s)"):format(
			safe(value.session_id),
			safe(value.seq),
			safe(value.type),
			safe(value.surface)
		),
	}
	if value.event_id and value.event_id ~= "" then
		lines[#lines + 1] = "Event ID: " .. safe(value.event_id)
	end
	if value.availability and value.availability ~= "" then
		lines[#lines + 1] = "Availability: " .. safe(value.availability)
	end
	if value.created_at_ms then
		lines[#lines + 1] = "Timestamp: " .. format_time(value.created_at_ms)
	end
	lines[#lines + 1] = "Replaced by: " .. (value.replaced_by and safe(value.replaced_by) or "none")
	lines[#lines + 1] = "Replacement chain: " .. seq_list(value.replacement_chain)
	lines[#lines + 1] = "Source events: " .. seq_list(value.source_event_seqs)
	lines[#lines + 1] = "Derived events: " .. seq_list(value.derived_event_seqs)
	if value.replaced_event_seqs and #value.replaced_event_seqs > 0 then
		lines[#lines + 1] = "Replaced events: " .. seq_list(value.replaced_event_seqs)
	end
	if value.summary and value.summary ~= "" then
		lines[#lines + 1] = "Summary: " .. safe(value.summary)
	end
	if value.incomplete then
		lines[#lines + 1] = "Some lineage sources could not be inspected; trace results may be incomplete."
	end
	return table.concat(lines, "\n")
end

function M.format(value)
	if value.data then
		return format_hits(value)
	end
	if value.target and value.ancestors and value.descendants then
		return format_lineage(value)
	end
	if value.seq and value.surface and value.source_event_seqs then
		return format_trace(value)
	end
	if value.spilled and value.handle then
		local hint = value.retrieval_hint and value.retrieval_hint ~= "" and (" " .. safe(value.retrieval_hint))
			or " Use read_spill with this handle to inspect it."
		local backend = value.backend and value.backend ~= "" and (", backend: " .. safe(value.backend)) or ""
		local lines = {
			("Session %s · event %s spilled to handle %s (%s bytes, complete%s).%s"):format(
				safe(value.session_id),
				safe(value.seq),
				safe(value.handle),
				safe(value.total_bytes),
				backend,
				hint
			),
		}
		append_neighbors(lines, value.neighbors)
		return table.concat(lines, "\n")
	end
	if value.event then
		local lines = {
			"Session " .. safe(value.session_id) .. " · event " .. safe(value.seq),
			"```json",
			mare.json.encode(value.event),
			"```",
		}
		append_neighbors(lines, value.neighbors)
		return table.concat(lines, "\n")
	end
	return mare.json.encode(value)
end
function M.render(args, result, expanded)
	if not result then
		return mare.ui.Paragraph("Searching session history…")
	end
	if result.is_error or result.cancelled then
		return mare.ui.Paragraph(mare.ui.Line({
			mare.ui.Span(result.cancelled and "History query cancelled" or "History query failed", "error"),
			" · " .. safe(result.content),
		}))
	end
	local value = result.details or {}
	if not expanded then
		if value.data then
			return mare.ui.Paragraph(
				("History · %d match(es)%s%s"):format(
					#value.data,
					value.capped and " · capped" or "",
					value.incomplete and " · incomplete" or ""
				)
			)
		elseif value.target and value.ancestors and value.descendants then
			return mare.ui.Paragraph(
				("Trace · %s · %d ancestor(s) · %d descendant root(s)%s"):format(
					safe(value.target.session_id),
					#value.ancestors,
					#value.descendants,
					value.incomplete and " · incomplete" or ""
				)
			)
		elseif value.seq and value.surface and value.source_event_seqs then
			return mare.ui.Paragraph(
				("Event trace · seq %s · %s%s"):format(
					safe(value.seq),
					safe(value.surface),
					value.incomplete and " · incomplete" or ""
				)
			)
		elseif value.spilled and value.handle then
			return mare.ui.Paragraph(
				("Event read · seq %s · spilled (%s bytes)"):format(safe(value.seq), safe(value.total_bytes))
			)
		elseif value.event then
			return mare.ui.Paragraph(
				("Event read · seq %s · %d neighbor(s)"):format(safe(value.seq), #(value.neighbors or {}))
			)
		end
	end
	return mare.ui.Paragraph(M.format(value))
end
return M
