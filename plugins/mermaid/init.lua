-- Generic fenced-code presentations and actual guarded renderer execution stay separate.
-- Independent implementation; installed mmdc is an external MIT-licensed dependency.
return {
	name = "mermaid",
	tags = {},
	inject = { "tools", "ui", "session", "bus" },
	config_schema = {
		command = { type = "string", default = "mmdc", desc = "Mermaid CLI command.", apply = "next_op" },
		node = { type = "string", default = "node", desc = "Node.js executable.", apply = "next_op" },
		renderer_script = {
			type = "string",
			default = "",
			desc = "Optional path to a custom Mermaid renderer script.",
			apply = "next_op",
		},
		backend = {
			type = "string",
			default = "",
			desc = "Optional renderer backend identifier.",
			apply = "next_op",
		},
		timeout_ms = {
			type = "integer",
			default = 15000,
			min = 100,
			max = 110000,
			unit = "ms",
			desc = "Renderer timeout in milliseconds.",
			apply = "next_op",
		},
		automatic = {
			type = "boolean",
			default = true,
			desc = "Automatically render fenced mermaid blocks.",
			apply = "live",
		},
		streaming_preview = {
			type = "boolean",
			default = true,
			desc = "Render live previews for open streaming mermaid blocks.",
			apply = "live",
		},
		preview_debounce_ms = {
			type = "integer",
			default = 150,
			min = 0,
			max = 2000,
			unit = "ms",
			desc = "Debounce interval in milliseconds for streaming previews.",
			apply = "live",
		},
		max_rows = {
			type = "integer",
			default = 20,
			min = 1,
			max = 200,
			unit = "rows",
			desc = "Maximum terminal rows for compact diagram previews.",
			apply = "live",
		},
		expanded_max_rows = {
			type = "integer",
			default = 200,
			min = 1,
			max = 296,
			unit = "rows",
			desc = "Maximum terminal rows for expanded diagram views.",
			apply = "live",
		},
		max_cols = {
			type = "integer",
			default = 120,
			min = 4,
			max = 512,
			unit = "cols",
			desc = "Maximum terminal columns for diagram previews.",
			apply = "live",
		},
		max_pixels = {
			type = "integer",
			default = 2048,
			min = 64,
			max = 2048,
			unit = "px",
			desc = "Maximum rendered image dimension in pixels.",
			apply = "next_op",
		},
		scale = {
			type = "enum",
			choices = { 1, 2 },
			default = 1,
			desc = "Render scale factor (1 or 2).",
			apply = "next_op",
		},
		preferred_aspect_ratio = {
			type = "number",
			default = 0,
			min = 0,
			max = 10.0,
			desc = "Preferred aspect ratio (0 for auto, or 0.1..10.0).",
			apply = "live",
		},
		node_spacing = {
			type = "integer",
			default = 80,
			min = 10,
			max = 400,
			unit = "px",
			desc = "Horizontal spacing between nodes.",
			apply = "next_op",
		},
		rank_spacing = {
			type = "integer",
			default = 80,
			min = 10,
			max = 400,
			unit = "px",
			desc = "Vertical spacing between ranks.",
			apply = "next_op",
		},
		node_padding_x = {
			type = "integer",
			default = 40,
			min = 4,
			max = 200,
			unit = "px",
			desc = "Horizontal node padding.",
			apply = "next_op",
		},
		node_padding_y = {
			type = "integer",
			default = 20,
			min = 4,
			max = 200,
			unit = "px",
			desc = "Vertical node padding.",
			apply = "next_op",
		},
		max_nodes = {
			type = "integer",
			default = 100,
			min = 1,
			max = 10000,
			desc = "Maximum node count allowed before skipping render.",
			apply = "next_op",
		},
		max_edges = {
			type = "integer",
			default = 200,
			min = 1,
			max = 20000,
			desc = "Maximum edge count allowed before skipping render.",
			apply = "next_op",
		},
		max_heap_mb = {
			type = "integer",
			default = 512,
			min = 128,
			max = 4096,
			unit = "MB",
			desc = "Node.js heap limit in megabytes for mermaid rendering.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		for _, key in ipairs({ "command", "node", "renderer_script", "backend" }) do
			assert(not cfg[key]:find("%z"), "invalid " .. key)
		end
		assert(cfg.command ~= "" and cfg.node ~= "", "renderer commands must be nonempty")
		assert(
			cfg.preferred_aspect_ratio == 0
				or (cfg.preferred_aspect_ratio >= 0.1 and cfg.preferred_aspect_ratio <= 10.0),
			"invalid preferred_aspect_ratio"
		)
		local mare_lib = require("mare_lib")
		local caps_ok, caps = false, nil
		if ctx.tools and mare_lib.callable(ctx.tools.capabilities) then
			caps_ok, caps = pcall(ctx.tools.capabilities, ctx.tools)
		end
		if not (caps_ok and type(caps) == "table" and caps.result_pipeline == 1) then
			local msg = "Mermaid disabled: core does not provide the public tools result pipeline"
			mare.log("warn", msg)
			if mare.ui and mare.ui.notify then
				pcall(mare.ui.notify, msg, "warning")
			end
			return
		end
		if not (ctx.ui and mare_lib.callable(ctx.ui.artifact_image)) then
			local msg = "Mermaid disabled: core does not provide public output-backed image resources"
			mare.log("warn", msg)
			if mare.ui and mare.ui.notify then
				pcall(mare.ui.notify, msg, "warning")
			end
			return
		end
		require("mermaid.runtime")(ctx, cfg)
	end,
}
