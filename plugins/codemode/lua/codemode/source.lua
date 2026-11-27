return function(input, args)
	assert(
		type(input) == "string" and input:match("%S") and #input <= 65536,
		"codemode requires 1..65536 bytes of Lua source"
	)
	local first, rest = input:match("^([^\n]*)\n?(.*)$")
	first = first:gsub("\r$", "")
	local pragma = first:match("^%s*%-%- @exec:%s*(.*)$")
	local options = {}
	if pragma then
		assert(pragma:match("%S"), "exec options must be an object")
		local err
		options, err = mare.json.decode_lossless(pragma)
		assert(
			type(options) == "table"
				and pragma:match("^%s*{")
				and (not mare.json.encode_strict or mare.json.encode_strict(options):sub(1, 1) == "{"),
			err or "exec options must be an object"
		)
		for key in pairs(options) do
			assert(key == "yield_time_ms" or key == "max_output_tokens", "unknown exec option: " .. tostring(key))
		end
		input = "\n" .. rest
		assert(rest:match("%S"), "exec options require source code")
	end
	assert(not input:match("\n%s*%-%- @exec:"), "exec options are only accepted on the first line")
	args = args or {}
	local limits = { yield_time_ms = 600000, max_output_tokens = 1000000 }
	for _, key in ipairs({ "yield_time_ms", "max_output_tokens" }) do
		if args[key] ~= nil then
			options[key] = args[key]
		end
		if options[key] ~= nil then
			assert(
				math.type(options[key]) == "integer" and options[key] >= 0 and options[key] <= limits[key],
				"invalid exec option: " .. key
			)
		end
	end
	if args.timeout_ms ~= nil and args.timeout_ms ~= false then
		assert(
			math.type(args.timeout_ms) == "integer" and args.timeout_ms >= 1 and args.timeout_ms <= 600000,
			"invalid exec option: timeout_ms"
		)
	end
	options.timeout_ms = args.timeout_ms
	return input, options
end
