local function str(max)
	return { type = "string", description = "Nonempty text, maximum " .. max .. " characters." }
end
return {
	type = "object",
	additionalProperties = false,
	required = { "questions" },
	properties = {
		questions = {
			type = "array",
			items = {
				type = "object",
				additionalProperties = false,
				required = { "id", "header", "question", "options" },
				properties = {
					id = str(64),
					header = str(12),
					question = str(2000),
					multi_select = { type = "boolean" },
					options = {
						type = "array",
						items = {
							type = "object",
							additionalProperties = false,
							required = { "label", "description" },
							properties = {
								label = str(120),
								description = str(1000),
								recommended = { type = "boolean" },
								preview = str(10000),
							},
						},
					},
				},
			},
		},
	},
}
