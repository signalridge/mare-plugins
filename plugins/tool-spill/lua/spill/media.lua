-- Base64 image decoding, magic header validation, and multimodal transcript serialization.
local M = {}

local PNG_MAGIC = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
local JPEG_MAGIC = string.char(0xFF, 0xD8, 0xFF)

local function non_empty_string(value)
	return type(value) == "string" and value ~= "" and value or nil
end

function M.decode_base64(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil, "empty base64 image data"
	end
	local data_mime
	local b64 = raw
	local prefix_mime, payload = raw:match("^data:([^;]+);base64,(.+)$")
	if payload then
		data_mime = prefix_mime:lower()
		b64 = payload
	end
	local ok, decoded = pcall(mare.crypto.base64_decode, b64)
	if not ok or type(decoded) ~= "string" or decoded == "" then
		return nil, "invalid base64 image data"
	end
	return decoded, nil, data_mime
end

function M.validate_image_bytes(bytes, mime)
	if type(bytes) ~= "string" or bytes == "" then
		return false, "empty image payload"
	end
	local lower = type(mime) == "string" and mime:lower() or ""
	if lower == "image/png" then
		if bytes:sub(1, 8) ~= PNG_MAGIC then
			return false, "image/png payload failed magic header validation"
		end
	elseif lower == "image/jpeg" or lower == "image/jpg" then
		if bytes:sub(1, 3) ~= JPEG_MAGIC then
			return false, "image/jpeg payload failed magic header validation"
		end
	elseif lower == "image/gif" then
		local h = bytes:sub(1, 6)
		if h ~= "GIF87a" and h ~= "GIF89a" then
			return false, "image/gif payload failed magic header validation"
		end
	elseif lower == "image/webp" then
		if #bytes < 12 or bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WEBP" then
			return false, "image/webp payload failed magic header validation"
		end
	end
	return true
end

--- Decodes and saves binary images, returning `(transcript, image_refs)` or `nil, err`.
function M.build_transcript(content, session_id, storage, save_opts, suggested_base, saved_handles)
	local transcript = {}
	local image_refs = {}
	local img_idx = 0
	for _, block in ipairs(content) do
		if block.type == "text" then
			transcript[#transcript + 1] = block.text
		elseif block.type == "image" then
			img_idx = img_idx + 1
			local raw_mime = non_empty_string(block.mime_type or block.mimeType or block.media_type or block.mime)
			if storage.save_bytes and type(block.data) == "string" and block.data ~= "" then
				local decoded_bytes, dec_err, data_mime = M.decode_base64(block.data)
				if not decoded_bytes then
					return nil, dec_err
				end
				if raw_mime and data_mime and raw_mime:lower() ~= data_mime then
					return nil, "image data URL MIME mismatch"
				end
				local mime = raw_mime or data_mime or "image/unknown"
				local ok_hdr, hdr_err = M.validate_image_bytes(decoded_bytes, mime)
				if not ok_hdr then
					return nil, hdr_err
				end
				local img_opts = {}
				for k, v in pairs(save_opts) do
					img_opts[k] = v
				end
				img_opts.suggested_name = ("%s-image-%d.txt"):format(suggested_base, img_idx)
				local ok, img_ref = pcall(storage.save_bytes, session_id, decoded_bytes, img_opts)
				if not ok then
					return nil, img_ref
				end
				saved_handles[#saved_handles + 1] = img_ref.spill_id
				local byte_len = img_ref.size or #decoded_bytes
				image_refs[#image_refs + 1] = {
					index = img_idx,
					mime = mime,
					handle = img_ref.spill_id,
					path = img_ref.path,
					size = byte_len,
				}
				transcript[#transcript + 1] = ("\n[Image #%d: mime=%s, spill_id=%s%s, bytes=%d]\n"):format(
					img_idx,
					mime,
					img_ref.spill_id,
					img_ref.path and (", path=" .. img_ref.path) or "",
					byte_len
				)
			else
				local mime = raw_mime or "image/unknown"
				transcript[#transcript + 1] = ("\n[Image #%d: mime=%s]\n"):format(img_idx, mime)
			end
		end
	end
	return table.concat(transcript), image_refs
end

return M
