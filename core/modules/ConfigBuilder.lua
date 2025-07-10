-- core/modules/ConfigBuilder.lua

local mergeImmutable  <const> = roxy.Table.mergeImmutable
local tableInsert     <const> = table.insert

class("ConfigBuilder").extends()

-- ! Initialize
-- Constructor: start with one base layer (or empty table)
-- @param base table?
function ConfigBuilder:init(base)
  -- Layers is an array of tables we’ll merge in order
  self.layers = { base or {} }
end

-- ! With
-- Add another override layer
-- @param layer table?
-- @return self
function ConfigBuilder:with(layer)
  if layer then
    tableInsert(self.layers, layer)
  end
  return self
end

-- ! Build
-- Merge all layers in sequence and return the result
-- @return table
function ConfigBuilder:build()
  local result = self.layers[1]
  for i = 2, #self.layers do
    result = mergeImmutable(result, self.layers[i])
  end
  return result
end
