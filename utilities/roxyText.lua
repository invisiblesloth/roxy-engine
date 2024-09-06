local pd <const> = playdate
local Graphics <const> = pd.graphics
local Font <const> = Graphics.font

roxy = roxy or {}
roxy.text = {}

-- ! Fonts
-- The Playdate system font
roxy.text.FONT_SYSTEM = Graphics.getSystemFont()
roxy.text.FONT_SYSTEM_OFFSET = 1  -- Offset to adjust text positioning with the system font

-- Load the custom font
-- local boldFontPath = "libraries/roxy/assets/fonts/Your-Bold-Font"
-- roxy.text.FONT_SYSTEM_BOLD = Font.new(boldFontPath)
-- assert(roxy.text.FONT_SYSTEM_BOLD, "ERROR: Custom font not loaded.")  -- Ensure the font is loaded correctly
-- NOTE: You will need to include a bold font if required.
-- Add more fonts *HERE*

-- ! Constants
-- Constants for text alignment, mirroring Playdate SDK's `kTextAlignment`
roxy.text.ALIGN_LEFT = kTextAlignment.left		-- Left-aligned text
roxy.text.ALIGN_RIGHT = kTextAlignment.right	-- Right-aligned text
roxy.text.ALIGN_CENTER = kTextAlignment.center	-- Center-aligned text

-- ! Functions

local currentFont = roxy.text.FONT_SYSTEM  -- Default font
local currentFontOffset = roxy.text.FONT_SYSTEM_OFFSET  -- Default font offset

-- Returns the currently set font and its offset
function roxy.text.getCurrentFont()
	return currentFont, currentFontOffset
end

-- Returns the current font offset
function roxy.text.getCurrentFontOffset()
	return currentFontOffset
end

-- Sets the current font, with an optional font offset and variant
function roxy.text.setFont(font, variant, fontOffset)
	currentFont = font  -- Update the current font
	currentFontOffset = fontOffset or roxy.text.FONT_SYSTEM_OFFSET  -- Set font offset, defaulting to system offset
	local variant = variant or Font.kVariantNormal  -- Default to the normal variant if not specified
	Graphics.setFont(font, variant)  -- Apply the font and variant
end

-- Draws text at a specified position with alignment, using the specified or current font.
-- Abstracts multiple Playdate text drawing functions into one.
function roxy.text.draw(string, x, y, alignment, font)
	alignment = alignment or roxy.text.ALIGN_LEFT  -- Default to left alignment
	string = string or ""  -- Ensure the string is not nil

	if font then 
		local currentFont <const> = Graphics.getFont()  -- Cache the currently set font
		Graphics.setFont(font)  -- Temporarily set the new font
		Graphics.drawTextAligned(string, x, y, alignment)  -- Draw the text with the specified alignment
		Graphics.setFont(currentFont)  -- Reset to the previously set font
	else
		Graphics.drawTextAligned(string, x, y, alignment)  -- Draw the text with the current font
	end
end
