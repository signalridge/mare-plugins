local M = {}
local function text(value, limit)
	assert(
		type(value) == "string" and value:match("%S") and utf8.len(value) and utf8.len(value) <= limit,
		"invalid question text or length"
	)
end
local function assert_array(t, min_len, max_len, msg)
	assert(type(t) == "table", msg)
	local count, keys = 0, 0
	for _ in ipairs(t) do
		count = count + 1
	end
	for _ in pairs(t) do
		keys = keys + 1
	end
	assert(keys == count and count >= min_len and count <= max_len, msg)
end
function M.validate(qs)
	assert_array(qs, 1, 4, "expected 1–4 questions")
	local ids = {}
	for _, q in ipairs(qs) do
		assert(type(q) == "table", "question must be an object")
		text(q.id, 64)
		text(q.header, 12)
		text(q.question, 2000)
		assert(not ids[q.id], "duplicate question id")
		ids[q.id] = true
		assert(q.multi_select == nil or type(q.multi_select) == "boolean", "multi_select must be boolean")
		assert_array(q.options, 2, 4, "expected 2–4 options")
		local labels, recommendations = {}, 0
		for _, o in ipairs(q.options) do
			assert(type(o) == "table", "option must be an object")
			text(o.label, 120)
			local trimmed_label = o.label:match("^%s*(.-)%s*$")
			assert(trimmed_label:lower() ~= "other", "Other is supplied by the UI; use distinct option labels")
			text(o.description, 1000)
			assert(not labels[trimmed_label], "duplicate option label")
			labels[trimmed_label] = true
			if o.preview ~= nil then
				text(o.preview, 10000)
			end
			assert(o.recommended == nil or type(o.recommended) == "boolean", "recommended must be boolean")
			if o.recommended then
				recommendations = recommendations + 1
			end
		end
		assert(recommendations <= 1, "at most one recommended option")
	end
end
return M
