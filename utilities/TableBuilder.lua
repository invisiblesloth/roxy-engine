-- utilities/TableBuilder.lua

local pd      <const> = playdate
local Object  <const> = pd.object

local tableInsert     <const> = table.insert
local mergeImmutable  <const> = roxy.Table.mergeImmutable

class("TableBuilder").extends(Object)

-- ! Initialize
-- Constructor: start with one base layer (or empty table)
-- @param base table?
function TableBuilder:init(base)
  -- Layers is an array of tables we'll merge in order
  self.layers = { base or {} }
end

-- ! With Merger
-- Set the merge function to use when building
-- @param mergeFn function? Merge function (defaults to mergeImmutable)
-- @return self For method chaining
function TableBuilder:withMerger(mergeFn)
  self._merge = mergeFn or mergeImmutable
  return self
end

-- ! With
-- Add another override layer
-- @param layer table?
-- @return self
function TableBuilder:with(layer)
  if layer then
    tableInsert(self.layers, layer)
  end
  return self
end

-- ! With If
-- Conditionally add a layer
-- @param layer table? Layer to add if condition is true
-- @param condition boolean Whether to add the layer
-- @return self For method chaining
function TableBuilder:withIf(layer, condition)
  if condition and layer then
    tableInsert(self.layers, layer)
  end
  return self
end

-- ! With Many
-- Add multiple layers at once
-- @param layers table Array of tables to add as layers
-- @return self For method chaining
function TableBuilder:withMany(layers)
  if layers then
    for _, layer in ipairs(layers) do
      if layer then
        tableInsert(self.layers, layer)
      end
    end
  end
  return self
end

-- ! Build
-- Merge all layers in sequence and return the result
-- @return table
function TableBuilder:build()
  local merge = self._merge or mergeImmutable
  local result = self.layers[1]
  for i = 2, #self.layers do
    result = merge(result, self.layers[i])
  end
  return result
end

-- ! Reset
-- Clear all layers and optionally set a new base
-- @param base table? New base layer (defaults to empty table)
-- @return self For method chaining
function TableBuilder:reset(base)
  self.layers = { base or {} }
  return self
end

-- ! Get Layer Count
-- Returns the number of layers currently in the builder
-- @return number Number of layers
function TableBuilder:getLayerCount()
  return #self.layers
end

-- ! Peek Layer
-- Get a specific layer without building
-- @param index number Layer index (1-based)
-- @return table? The layer at the specified index
function TableBuilder:peekLayer(index)
  return self.layers[index]
end
