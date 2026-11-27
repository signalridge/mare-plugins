local M = {}
local string_array = { type = "array", items = { type = "string" } }
local event = {
	seq_from = { type = "integer" },
	seq_to = { type = "integer" },
	from_ms = {
		type = "integer",
		description = "Inclusive lower bound as Unix epoch milliseconds.",
	},
	to_ms = { type = "integer", description = "Inclusive upper bound as Unix epoch milliseconds." },
	event_types = string_array,
	surfaces = { type = "array", items = { type = "string", enum = { "current", "shadowed", "log_only" } } },
}
local function schema(properties, required)
	return {
		type = "object",
		additionalProperties = false,
		properties = properties,
		required = #required > 0 and required or nil,
	}
end
local search = {
	query = { type = "string", description = "Literal search text (required unless title_query is set)." },
	title_query = { type = "string", description = "Optional case-insensitive session title substring filter." },
	sort_key = { type = "string", enum = { "relevance", "created_at_ms", "updated_at_ms" } },
	sort_direction = { type = "string", enum = { "desc", "asc" } },
	archived = { type = "boolean", description = "Search archived sessions when true; defaults to non-archived." },
	session_ids = string_array,
	created_from_ms = event.from_ms,
	created_to_ms = event.to_ms,
	parent_session_ids = string_array,
	include_root_sessions = { type = "boolean" },
	availability = { type = "array", items = { type = "string", enum = { "live", "persisted" } } },
	event_seq_from = event.seq_from,
	event_seq_to = event.seq_to,
	event_from_ms = event.from_ms,
	event_to_ms = event.to_ms,
	event_types = event.event_types,
	event_surfaces = event.surfaces,
}
M.session_search = schema(search, {})
local events = table.copy(event)
events.session_id =
	{ type = "string", description = "Omit for current session if source supports step-bound observations." }
events.query = { type = "string" }
M.session_event_search = schema(events, { "query" })
M.session_trace = schema({ session_id = { type = "string" } }, {})
M.session_event_trace = schema({ session_id = { type = "string" }, seq = { type = "integer" } }, { "seq" })
M.session_event_read = schema(
	{ event_id = { type = "string" }, before = { type = "integer" }, after = { type = "integer" } },
	{ "event_id" }
)
return M
