-- core/transitions/FadeToBlack.lua

local Table <const> = roxy.Table
local Ease  <const> = roxy.EasingFunctions

local mergeImmutable <const> = Table.mergeImmutable

local EMPTY_TABLE <const> = {}

local DEFAULT_OPTS <const> = {
  name = "Fade to Black",
  ease = Ease.outInQuad
}

class("FadeToBlack").extends(RoxyCoverTransition)
local transition = FadeToBlack

function transition:init(duration, holdTime, opts, stackOp)
  local opts = mergeImmutable(DEFAULT_OPTS, (opts or EMPTY_TABLE))
  transition.super.init(self, duration, holdTime, opts, stackOp)
end
