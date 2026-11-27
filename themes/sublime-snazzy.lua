-- Reference background: #282a36
-- Upstream: https://github.com/greggb/sublime-snazzy (MIT License, Copyright (c) 2024 greggb); see THIRD_PARTY_NOTICES.md.
return {
	syntax = [====[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>name</key>
	<string>Sublime Snazzy</string>
	<key>settings</key>
	<array>
		<dict>
			<key>settings</key>
			<dict>
				<key>background</key>
				<string>#282A36</string>
				<key>caret</key>
				<string>#97979B</string>
				<key>foreground</key>
				<string>#F8F8F2</string>
				<key>invisibles</key>
				<string>#686868</string>
				<key>lineHighlight</key>
				<string>#000000</string>
				<key>selection</key>
				<string>#57C7FF</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Comment</string>
			<key>scope</key>
			<string>comment</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#686868</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>String</string>
			<key>scope</key>
			<string>string</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#F3F99D</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Number</string>
			<key>scope</key>
			<string>constant.numeric</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#F1F1F0</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Built-in constant</string>
			<key>scope</key>
			<string>constant.language</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#5AF78E</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>User-defined constant</string>
			<key>scope</key>
			<string>constant.character, constant.other</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#5AF78E</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Variable</string>
			<key>scope</key>
			<string>variable</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Keyword</string>
			<key>scope</key>
			<string>keyword</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#FF5C57</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Storage</string>
			<key>scope</key>
			<string>storage</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#FF5C57</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Storage type</string>
			<key>scope</key>
			<string>storage.type</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string>italic</string>
				<key>foreground</key>
				<string>#9AEDFE</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Class name</string>
			<key>scope</key>
			<string>entity.name.class</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string>underline</string>
				<key>foreground</key>
				<string>#9AEDFE</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Inherited class</string>
			<key>scope</key>
			<string>entity.other.inherited-class</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string>italic underline</string>
				<key>foreground</key>
				<string>#9AEDFE</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Function name</string>
			<key>scope</key>
			<string>entity.name.function</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#9AEDFE</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Function argument</string>
			<key>scope</key>
			<string>variable.parameter</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string>italic</string>
				<key>foreground</key>
				<string>#FF6AC1</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Tag name</string>
			<key>scope</key>
			<string>entity.name.tag</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#5AF78E</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Tag attribute</string>
			<key>scope</key>
			<string>entity.other.attribute-name</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#9AEDFE</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Library function</string>
			<key>scope</key>
			<string>support.function</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#F3F99D</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Library constant</string>
			<key>scope</key>
			<string>support.constant</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#F3F99D</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Library class&#x2f;type</string>
			<key>scope</key>
			<string>support.type, support.class</string>
			<key>settings</key>
			<dict>
				<key>foreground</key>
				<string>#F3F99D</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Library variable</string>
			<key>scope</key>
			<string>support.other.variable</string>
			<key>settings</key>
			<dict>
				<key>fontStyle</key>
				<string></string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Invalid</string>
			<key>scope</key>
			<string>invalid</string>
			<key>settings</key>
			<dict>
				<key>background</key>
				<string>#FF5C57</string>
				<key>fontStyle</key>
				<string></string>
				<key>foreground</key>
				<string>#F1F1F0</string>
			</dict>
		</dict>
		<dict>
			<key>name</key>
			<string>Invalid deprecated</string>
			<key>scope</key>
			<string>invalid.deprecated</string>
			<key>settings</key>
			<dict>
				<key>background</key>
				<string>#FF5C57</string>
				<key>foreground</key>
				<string>#57C7FF</string>
			</dict>
		</dict>
	</array>
	<key>uuid</key>
	<string>D8D5E82E-3D5B-46B5-B38E-8C841C21347D</string>
	<key>colorSpaceName</key>
	<string>sRGB</string>
	<key>semanticClass</key>
	<string>theme.dark.monokai</string>
</dict>
</plist>
]====],
	base = "dark",
	palette = {
		accent = "#ff5c57",
		accent2 = "#f3f99d",
		add_bg = "#484b46",
		add_word = "#696c57",
		blue = "#9aedfe",
		border = "#737373",
		code_bg = "#20222b",
		del_bg = "#484a54",
		del_word = "#686a72",
		dim = "#919191",
		green = "#f3f99d",
		muted = "#b7b7b7",
		on_color = "#282a36",
		red = "#f1f1f0",
		selection = "#5e373e",
		subtle = "#737373",
		text = "#f8f8f2",
		yellow = "#f1f1f0",
	},
}
