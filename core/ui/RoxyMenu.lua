local pd <const> = playdate
local Graphics <const> = pd.graphics
local Text <const> = roxy.text
local Gridview <const> = pd.ui.gridview

local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

class("RoxyMenu").extends()

local defaultProperties = {
	isActive = false,
	wrapSelection = false,
	color = nil,
	font = Text.FONT_SYSTEM,
	textAlignment = Text.ALIGN_LEFT,
	verticalGapBetweenItems = 2,
	padding = { horizontal = 4, vertical = 2 },
	contentInset = { horizontal = 2, vertical = 2 },
	dimensions = { x = 32, y = 16, width = nil, height = 208 },
	display = { width = displayWidth, height = displayHeight },
	cornerRadius = 1
}

function RoxyMenu:init(properties)
	properties = properties or {}

	-- Merge provided properties with default properties 
	-- ensuring all necessary settings are included
	local mergedProperties = roxy.table.mergeImmutable(defaultProperties, properties)

	-- Assign basic menu properties
	self.sceneName = mergedProperties.sceneName
	self.isActive = mergedProperties.isActive
	self.wrapSelection = mergedProperties.wrapSelection
	self.color = mergedProperties.color
	self.font = mergedProperties.font
	self.textAlignment = mergedProperties.textAlignment
	self.verticalGapBetweenItems = mergedProperties.verticalGapBetweenItems
	self.cornerRadius = mergedProperties.cornerRadius
	self.selectedCornerRadius = mergedProperties.selectedCornerRadius or mergedProperties.cornerRadius

	-- Layout settings
	self.padding = {
		horizontal = mergedProperties.padding.horizontal,
		vertical = mergedProperties.padding.vertical
	}
	self.contentInset = {
		horizontal = mergedProperties.contentInset.horizontal,
		vertical = mergedProperties.contentInset.vertical
	}
	self.dimensions = {
		x = mergedProperties.dimensions.x,
		y = mergedProperties.dimensions.y,
		width = mergedProperties.dimensions.width,
		height = mergedProperties.dimensions.height
	}
	self.display = {
		width = mergedProperties.display.width,
		height = mergedProperties.display.height
	}
	
	-- Initialize item tracking and selection state
	self.itemNames = {}
	self.displayNames = {}
	self.clickHandlers = {}
	self.itemPositions = {}
	self.itemWidths = {}
	self.currentItemNumber = 0
	self.currentItemName = nil
	self.selectedCellBounds = { x = 0, y = 0, width = 0, height = 0 }

	-- Calculate derived properties
	self.textHeight = self.font:getHeight()
	self.rowHeight = 2 * self.padding.vertical + self.textHeight + self.verticalGapBetweenItems
	self.color, self.invertedColor, self.fillColor, self.invertedFillColor = self:calculateColorScheme(mergedProperties.color)
	self.menuWidth, self.autoWidth = self:setInitialMenuWidth(mergedProperties.dimensions.width)
	self.menuHeight, self.autoHeight = self:setInitialMenuHeight(mergedProperties.dimensions.height)
	self.menuMaxWidth = self.display.width - self.dimensions.x
	self.menuMaxHeight = self.display.height - self.dimensions.y
	self.cellWidth = 0
	self.cellHeight = self.textHeight

	-- Initialize gridview for managing menu items
	self.listview = Gridview.new(self.cellWidth, self.cellHeight)
	self.listview:setNumberOfColumns(1)
	self.listview:setCellPadding(self.padding.horizontal, self.padding.horizontal, self.padding.vertical, self.padding.vertical + self.verticalGapBetweenItems)
	self.listview:setContentInset(self.contentInset.horizontal, self.contentInset.horizontal, self.contentInset.vertical, self.contentInset.vertical)
	
	-- Custom cell drawing logic
	self.listview.drawCell = function(menu, section, row, column, selected, x, y, width, height)
		self:drawCell(selected, x, y, width, height, row)
	end
end

-- ! Draw Menu
-- Draws the menu at the specified position and dimensions
function RoxyMenu:draw(color, x, y, width, height)
	color = color or self.invertedColor or Graphics.kColorWhite
	x = x or self.dimensions.x or 0
	y = y or self.dimensions.y or 0
	width = width or math.min(self.menuWidth, self.menuMaxWidth)
	height = height or math.min(self.menuHeight, self.menuMaxHeight)

	local backgroundHeight = math.min(self.menuHeight - self.verticalGapBetweenItems, self.menuMaxHeight)
	
	-- TODO: Implement `needsDisplay` check in a future release, possibly requiring the menu to be put into a sprite.
	-- if self.listview.needsDisplay == true then
	if self.listview then
		Graphics.setColor(color)  -- Set the drawing color
		
		-- Choose the drawing function based on the corner radius
		local drawFunc = self.selectedCornerRadius < 1 and Graphics.fillRect or Graphics.fillRoundRect
		drawFunc(x, y, width, backgroundHeight, self.selectedCornerRadius)
		
		-- Draw the list view within the specified rectangle
		self.listview:drawInRect(x, y, width, height)
	end
end


-- ! Activate and Deactivate Menu
function RoxyMenu:activate()
	if not self.isActive then
		if #self.itemNames > 0 then
			self.isActive = true
			
			-- Ensure currentItemNumber is within valid range
			if self.currentItemNumber < 1 then
				self.currentItemNumber = 1
			elseif self.currentItemNumber > #self.itemNames then
				self.currentItemNumber = #self.itemNames
			end
			
			self:select(self.currentItemNumber)
		else
			warn("Warning: No menu items to select.")
		end
	else
		warn("Warning: Attempted to activate an active menu.")
	end
	
	return self
end

function RoxyMenu:deactivate()
	self.listview:setSelectedRow(0)
	self.isActive = false
	return self
end

function RoxyMenu:getIsActive()
	return self.isActive
end

-- ! Add Item to Menu
-- Adds a new item to the menu with the specified click handler and display name
function RoxyMenu:addItem(nameOrKey, clickHandler, displayName, position)
	assert(nameOrKey, "ERROR: A name (or key) is required.")
	
	self.clickHandlers[nameOrKey] = clickHandler or function() print("Menu item \"" .. nameOrKey .. "\" clicked!") end
	self.displayNames[nameOrKey] = displayName or nameOrKey
	
	-- Calculate the width of the new item
	local newItemWidth = self.font:getTextWidth(self.displayNames[nameOrKey])
	self.itemWidths[nameOrKey] = newItemWidth

	-- Adjust menu width if the new item is the widest
	if self.autoWidth and newItemWidth > (self.menuWidth or 0) then
		self.menuWidth = 2 * (self.contentInset.horizontal + self.padding.horizontal) + newItemWidth
	end

	if position then
		if position <= 0 or position > #self.itemNames + 1 then
			error("ERROR: Menu item out of range.")
		end
		table.insert(self.itemNames, position, nameOrKey)
	else
		table.insert(self.itemNames, nameOrKey)
		position = #self.itemNames
	end
	
	-- Adjust the position of items after the inserted item
	for i = 1, #self.itemPositions do
		if self.itemPositions[i] >= position then
			self.itemPositions[i] = self.itemPositions[i] + 1
		end
	end
	self.itemPositions[nameOrKey] = position

	self.listview:setNumberOfRows(#self.itemNames)
	if self.autoHeight then self.menuHeight = self:calculateMenuHeight() end
	
	return self
end

-- ! Select Specific Menu Item
-- Selects a specific item in the menu by its position or name
function RoxyMenu:select(menuItem, ignoreActiveStatus)
	if self.isActive or ignoreActiveStatus then
		if menuItem then
			if type(menuItem) == "number" then
				if menuItem < 1 then
					error("ERROR: `menuItem` must be a number greater than 0 (or a string).")
				end
				self.listview:setSelectedRow(menuItem)
			elseif type(menuItem) == "string" then
				self.listview:setSelectedRow(self.itemPositions[menuItem])
			else
				error("ERROR: `menuItem` must be a number or string.")
			end
		end
		self:updateCurrentSelection()
	end
	return self
end

-- ! Select Next Menu Item
-- Selects the next item in the menu, with optional wrap-around
function RoxyMenu:selectNext(ignoreActiveStatus, wrapSelection)
	if self.isActive or ignoreActiveStatus then
		wrapSelection = wrapSelection or self.wrapSelection or false
		self.listview:selectNextRow(wrapSelection)
		self:updateCurrentSelection()
	end
	return self
end

-- ! Select Previous Menu Item
-- Selects the previous item in the menu, with optional wrap-around
function RoxyMenu:selectPrevious(ignoreActiveStatus, wrapSelection)
	if self.isActive or ignoreActiveStatus then
		wrapSelection = wrapSelection or self.wrapSelection or false
		self.listview:selectPreviousRow(wrapSelection)
		self:updateCurrentSelection()
	end
	return self
end

-- ! Update Selection
-- Updates the current item selection based on the listview state
function RoxyMenu:updateCurrentSelection()
	local _, row, _ = self.listview:getSelection()
	if row >= 1 and row <= #self.itemNames then
		self.currentItemNumber = row
		self.currentItemName = self.itemNames[row]
	else
		self.currentItemNumber = 0
		self.currentItemName = nil  -- Ensure no item is selected when out of bounds or no items are present
	end
end

-- ! Get Selected Menu Item
-- Returns information about the currently selected item
function RoxyMenu:getSelectedItem()
	local _, row, _ = self.listview:getSelection()
	if row and row >= 1 and row <= #self.itemNames then
		local itemName = self.itemNames[row]
		return {
			name = itemName,
			clickHandler = self.clickHandlers[itemName],
			position = self.itemPositions[itemName],
			displayName = self.displayNames[itemName]
		}
	end
	return nil
end

-- ! Click Item
-- Triggers the click handler for the currently selected item
function RoxyMenu:click(ignoreActiveStatus)
	ignoreActiveStatus = ignoreActiveStatus or false  -- Default to false if not provided
	if self.isActive or ignoreActiveStatus then
		if self.currentItemName and self.clickHandlers[self.currentItemName] then
			self.clickHandlers[self.currentItemName]()
		else
			warn("Warning: No click handler defined for '" .. tostring(self.currentItemName) .. "' or no item is currently selected.")
		end
	else
		warn("Warning: Attempt to click on an inactive menu or without ignoreActiveStatus boolean.")
	end
end

-- ! Draw Cell
-- Custom draw function for each cell in the listview
function RoxyMenu:drawCell(selected, x, y, width, height, row)
	Graphics.setImageDrawMode(Graphics.kDrawModeCopy)  -- Reset image draw mode
	
	local name = self.itemNames[row]

	-- Apply selection appearance as needed
	if self.isActive and selected then
		self:drawSelection(x, y, width, height)
	end
	
	-- Set text mode based on menu's state and item's selection state
	if selected and self.isActive then
		Graphics.setImageDrawMode(self.invertedFillColor)
	else
		Graphics.setImageDrawMode(self.fillColor)
	end

	-- Set the font
	Graphics.setFont(self.font)

	Graphics.drawTextInRect(
		self.displayNames[name],
		x,						-- x
		y + Text.getCurrentFontOffset(),  -- y
		width,					-- Width
		height,					-- Height
		nil,					-- Leading Adjustment
		"...",					-- Truncation String
		self.textAlignment		-- Alignment
	)
end

-- ! Draw Selection Box
-- Draws the selection box around the currently selected item
function RoxyMenu:drawSelection(x, y, width, height)
	local dims = {
		x = x - self.padding.horizontal,
		y = y - self.padding.vertical,
		width = width + 2 * self.padding.horizontal,
		height = height + 2 * self.padding.vertical
	}
	
	local cornerRadius = self.selectedCornerRadius
	Graphics.setColor(self.color)
	local drawFunc = cornerRadius < 1 and Graphics.fillRect or Graphics.fillRoundRect
	drawFunc(dims.x, dims.y, dims.width, dims.height, cornerRadius)

	-- Update selected cell bounds
	self.selectedCellBounds.x = x
	self.selectedCellBounds.y = y
	self.selectedCellBounds.width = width
	self.selectedCellBounds.height = height
end

-- ! Calculate Color Scheme
-- Determines the color scheme for the menu based on the provided color
function RoxyMenu:calculateColorScheme(color)
	local defaultColor = color or Graphics.kColorBlack
	if defaultColor == Graphics.kColorBlack then
		return Graphics.kColorBlack, Graphics.kColorWhite, Graphics.kDrawModeFillBlack, Graphics.kDrawModeFillWhite
	else
		return Graphics.kColorWhite, Graphics.kColorBlack, Graphics.kDrawModeFillWhite, Graphics.kDrawModeFillBlack
	end
end

-- ! Set Menu Dimensions
-- Sets the initial width of the menu based on the provided or calculated width
function RoxyMenu:setInitialMenuWidth(width)
	if width then
		return width, false
	else
		return 0, true
	end
end

-- Sets the initial height of the menu based on the provided or calculated height
function RoxyMenu:setInitialMenuHeight(height)
	if height then
		return height, false
	else
		return self:calculateMenuHeight() or 150, true
	end
end

-- Calculates the height of the menu based on the number of items
function RoxyMenu:calculateMenuHeight()
	local height = 2 * self.contentInset.vertical + self.rowHeight * #self.itemNames
	return height
end
