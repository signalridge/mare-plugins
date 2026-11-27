local M = {}
M.max_bytes = 8 * 1024 * 1024
function M.validate(bytes)
	assert(type(bytes) == "string" and #bytes >= 33 and #bytes <= M.max_bytes, "invalid PNG byte length")
	assert(bytes:sub(1, 8) == "\137PNG\r\n\26\n" and bytes:sub(13, 16) == "IHDR", "invalid PNG header")
	local width, height = string.unpack(">I4I4", bytes, 17)
	assert(
		width > 0 and height > 0 and width <= 4096 and height <= 4096 and width * height <= 16777216,
		"PNG dimensions exceed limit"
	)
	return width, height
end
return M
