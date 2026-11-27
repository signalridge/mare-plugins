local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local plugin = support.load_plugin("schedule", {
	"schedule.policy",
	"schedule.scheduler",
	"schedule.value",
	"schedule.timing",
	"schedule.codec",
	"schedule.store",
	"schedule.engine",
	"schedule.interface",
	"schedule.domain",
	"schedule.delivery",
	"schedule.management",
})

local M = {
	plugin = plugin,
}

local function clone(v)
	if type(v) ~= "table" or v == mare.json.null then
		return v
	end
	local out = {}
	for k, item in pairs(v) do
		out[k] = clone(item)
	end
	if mare.json.is_array(v) then
		return mare.json.array(out)
	end
	return out
end

local function parse_iso(text)
	if type(text) ~= "string" then
		return nil
	end
	local y, m, d, H, min, sec, ms = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)Z$")
	if not y then
		return nil
	end
	local local_ts = os.time({
		year = tonumber(y),
		month = tonumber(m),
		day = tonumber(d),
		hour = tonumber(H),
		min = tonumber(min),
		sec = tonumber(sec),
		isdst = false,
	})
	local utc_t = os.date("!*t", local_ts)
	utc_t.isdst = false
	local base = local_ts + (local_ts - os.time(utc_t))
	return base * 1000 + tonumber((ms .. "000"):sub(1, 3))
end

local function fmt_iso(ms)
	return os.date("!%Y-%m-%dT%H:%M:%S", math.floor(ms / 1000))
end

local function fallback_time_query(q)
	if q.action == "instant" then
		local ms = parse_iso(q.value)
		if not ms then
			return nil, "Invalid instant"
		end
		return { instant_ms = ms }
	elseif q.action == "format" then
		return { text = fmt_iso(q.instant_ms) }
	elseif q.action == "normalize" then
		local p = clone(q.pattern)
		local next_ms
		if p.kind == "instant" then
			next_ms = p.at_ms > q.after_ms and p.at_ms or mare.json.null
		elseif p.kind == "interval" then
			next_ms = p.anchor_ms + p.every_ms
			while next_ms <= q.after_ms do
				next_ms = next_ms + p.every_ms
			end
		else
			next_ms = q.after_ms + 60000
		end
		return { pattern = p, next_ms = next_ms }
	elseif q.action == "next" then
		local p = q.pattern
		local next_ms
		if p.kind == "instant" then
			next_ms = p.at_ms > q.after_ms and p.at_ms or mare.json.null
		elseif p.kind == "interval" then
			local k = math.floor((q.after_ms - p.anchor_ms) / p.every_ms) + 1
			if k < 1 then
				k = 1
			end
			next_ms = p.anchor_ms + k * p.every_ms
		else
			next_ms = q.after_ms + 60000
		end
		return { next_ms = next_ms }
	elseif q.action == "resolve" then
		if q.pattern.kind == "interval" and q.accepted_ms > q.scheduled_ms then
			local k = math.floor((q.accepted_ms - q.scheduled_ms) / q.pattern.every_ms)
			return { occurrence_ms = q.scheduled_ms + k * q.pattern.every_ms }
		end
		return { occurrence_ms = q.scheduled_ms }
	end
	return nil, "unsupported query"
end

function M.clear_state()
	if mare and mare.state and type(mare.state.snapshot) == "function" then
		local snap = mare.state.snapshot({ namespace = "schedule.tasks" })
		if snap and snap.snapshot and snap.snapshot.exists then
			mare.state.compare_exchange({
				namespace = "schedule.tasks",
				expected_revision = snap.snapshot.revision,
				value = { version = 1, tasks = mare.json.array({}) },
			})
		end
	end
end

function M.fixture(opts)
	opts = opts or {}

	local env = {
		now = 1794630000000,
		sequence = 0,
		state_store = {},
		listeners = {},
		disposed = {},
		tools = {},
		cmds = {},
		queued = {},
		plan_active = false,
		enqueue_behavior = nil,
		notices = {},
		session = {
			session_id = "sess-1",
			session_epoch = "gen-1",
			ephemeral = false,
			readonly = false,
			unstable = false,
		},
		messages = {},
		session_entries = {},
		persist_err = nil,
		agent_notices = {},
		ui_notices = {},
		events = {},
		enqueued_payloads = {},
		clone = clone,
	}

	local orig_now = mare.task.now
	local orig_notify = mare.ui.notify
	local orig_agent_id = mare.agent_id
	local orig_time = mare.time
	local orig_time_query = mare.time and mare.time.query
	local orig_state = mare.state
	local orig_state_snapshot = mare.state and mare.state.snapshot
	local orig_state_cas = mare.state and mare.state.compare_exchange

	mare.task.now = function()
		return env.now
	end

	mare.ui.notify = function(msg, level)
		env.notices[#env.notices + 1] = { msg = msg, level = level }
		env.ui_notices[#env.ui_notices + 1] = { msg = msg, level = level }
	end

	if not mare.time or type(mare.time.query) ~= "function" then
		mare.time = mare.time or {}
		mare.time.query = fallback_time_query
	end

	local using_mock_state = false
	if not mare.state or type(mare.state.snapshot) ~= "function" or type(mare.state.compare_exchange) ~= "function" then
		using_mock_state = true
		mare.state = mare.state or {}
		mare.state.snapshot = function(req)
			local entry = env.state_store[req.namespace]
			if not entry then
				return { status = "ok", snapshot = { exists = false, revision = 0, value = mare.json.null } }
			end
			return {
				status = "ok",
				snapshot = { exists = true, revision = entry.revision, value = clone(entry.value) },
			}
		end
		mare.state.compare_exchange = function(req)
			local entry = env.state_store[req.namespace]
			local cur_rev = entry and entry.revision or 0
			if req.expected_revision ~= cur_rev then
				return { status = "conflict" }
			end
			local new_rev = cur_rev + 1
			env.state_store[req.namespace] = { revision = new_rev, value = clone(req.value) }
			return { status = "ok", snapshot = { revision = new_rev } }
		end
	else
		M.clear_state()
	end

	local dctx = {
		session = {
			info = function()
				return env.session
			end,
			switching = function()
				return false
			end,
			entries = function()
				return env.session_entries
			end,
		},
		agent = {
			get = function()
				return { busy = false }
			end,
			list_queue = function()
				return { data = mare.json.array(env.queued) }
			end,
			messages = function()
				return env.messages
			end,
			persist_error = function()
				return env.persist_err
			end,
			notify = function(_, text, nopts)
				env.agent_notices[#env.agent_notices + 1] = { text = text, wake = nopts and nopts.wake }
				return true
			end,
			enqueue = function(_, content, _, eopts)
				if env.enqueue_behavior then
					return env.enqueue_behavior(eopts)
				end
				env.sequence = env.sequence + 1
				local id = "in-" .. env.sequence
				local text = content and content[1] and content[1].text or ""
				env.queued[#env.queued + 1] = {
					input_id = id,
					lane = "follow_up",
					text = text,
					input_context = clone(eopts and eopts.input_context),
				}
				env.enqueued_payloads[#env.enqueued_payloads + 1] =
					{ id = id, text = text, input_context = clone(eopts and eopts.input_context) }
				return { status = "queued", durable = true, input_id = id, session_id = env.session.session_id }
			end,
			resume_input = function()
				if #env.queued > 0 then
					table.remove(env.queued, 1)
					return { status = "started", turn_id = "turn-d-" .. env.sequence }
				end
				return { status = "empty" }
			end,
		},
		plan_mode = {
			state = function()
				return { active = env.plan_active, pending = env.plan_active }
			end,
		},
		ui = {
			notify = function(_, msg, level)
				env.ui_notices[#env.ui_notices + 1] = { msg = msg, level = level }
			end,
		},
		tools = {
			register = function(_, name, def)
				env.tools[name] = def
			end,
		},
		commands = {
			register = function(_, name, def)
				env.cmds[name] = def
			end,
		},
		on = function(_, name, fn)
			env.listeners[name] = fn
		end,
		effect = function(_, setup)
			local fn = setup()
			env.disposed[#env.disposed + 1] = fn
		end,
		emit = function(_, name, payload)
			env.events[#env.events + 1] = { name = name, payload = payload }
		end,
		log = function() end,
	}

	local cfg = {
		delivery_history_days = opts.delivery_history_days or 2,
		delivery_history_records = opts.delivery_history_records or 3,
		new_session_interval_seconds = opts.new_session_interval_seconds or 60,
	}
	support.adapt_mock(dctx, true)
	local domain, engine = require("schedule.domain")(dctx, cfg)
	local drive, delivery = require("schedule.delivery")(dctx, domain, engine)
	require("schedule.management")(dctx, domain, engine)

	env.ctx = dctx
	env.domain = domain
	env.engine = engine
	env.drive = drive
	env.delivery = delivery

	function env.restore()
		for _, fn in ipairs(env.disposed) do
			fn()
		end
		if not using_mock_state then
			M.clear_state()
		end
		mare.task.now = orig_now
		mare.ui.notify = orig_notify
		mare.agent_id = orig_agent_id
		if orig_time == nil then
			mare.time = nil
		else
			mare.time = orig_time
			mare.time.query = orig_time_query
		end
		if orig_state == nil then
			mare.state = nil
		else
			mare.state = orig_state
			mare.state.snapshot = orig_state_snapshot
			mare.state.compare_exchange = orig_state_cas
		end
	end

	return env
end

return M
