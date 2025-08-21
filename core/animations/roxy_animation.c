// core/animations/roxy_animation.c

#include "roxy_animation.h"

static PlaydateAPI* pd = NULL;

void roxy_animation_setPlaydateAPI(PlaydateAPI* playdate) {
  pd = playdate;
}

/*

Delta time-based animation update logic

Expected arguments from Lua (in order):
  1. currentFrame (int)        - The current animation frame
  2. startFrame (int)          - The first frame of the animation sequence
  3. endFrame (int)            - The last frame of the animation sequence
  4. loop (int, boolean)       - Whether the animation should loop (1==true, 0==false)
  5. isReversed (int, boolean) - Whether the animation is in reverse (1==true, 0==false)
  6. isFirstCycle (int)        - Whether this is the first cycle (1==true, 0==false)
  7. speed (float)             - The speed multiplier for the animation
  8. frameDuration (float)     - The duration of each frame (in seconds)
  9. dt (float)                - Elapsed since the last frame update (in seconds)
  10. accumulator (float)      - Per-animation accumulator for handling fractional frames

Function behavior:
  - If `speed` is 0, the function returns immediately without updating.
  - If `isFirstCycle` is true, the animation is initialized at `startFrame`, and the accumulator is reset.
  - `dt` is used to calculate the number of frames to advance, based on speed and frame duration.
  - The accumulator tracks fractional progress between frames to ensure smooth updates.
  - The function correctly wraps around frames if `loop` is enabled, using modulo arithmetic for seamless looping.
  - If the animation is reversed, it decrements frames accordingly and handles underflow properly.

Returns three values to Lua:
  1. Updated `currentFrame` (int)  - The new animation frame
  2. Updated `isFirstCycle` (int)  - Whether it's still the first cycle (0 if initialized)
  3. Updated `accumulator` (float) - The remaining fractional frame progress to carry over

*/

int roxy_animation_update_l(lua_State* L) {
  // Retrieve parameters from Lua
  int currentFrame    = pd->lua->getArgInt(1);
  int startFrame      = pd->lua->getArgInt(2);
  int endFrame        = pd->lua->getArgInt(3);
  int loop            = pd->lua->getArgInt(4);  // 1 for true, 0 for false
  int isReversed      = pd->lua->getArgInt(5);  // 1 for true, 0 for false
  int isFirstCycle    = pd->lua->getArgInt(6);  // 1 if first cycle, 0 otherwise
  float speed         = pd->lua->getArgFloat(7);
  float frameDuration = pd->lua->getArgFloat(8);
  float dt            = pd->lua->getArgFloat(9);
  float accumulator   = pd->lua->getArgFloat(10);

  // Ensure delta time is not too small to avoid division issues.
  if (dt < 0.001f) {
    dt = 0.001f;
  }

  // If the speed is zero, we return without changing the frame.
  if (speed <= 0.0f) {
    pd->lua->pushInt(currentFrame);
    pd->lua->pushInt(isFirstCycle);
    pd->lua->pushFloat(accumulator);
    return 3;
  }

  // On the first update cycle, initialize the frame and accumulator.
  if (isFirstCycle == 1) {
    currentFrame = startFrame;
    accumulator = 0.0f;
    isFirstCycle = 0;
  } else {
    // Calculate how much progress we've made in terms of frames.
    // (dt * speed) gives the time-adjusted speed,
    // Dividing by frameDuration converts that into "frame units".
    float frameDelta = (dt * speed) / frameDuration;
    accumulator += frameDelta;

    // Only update the frame if we've accumulated at least one full frame's worth of progress.
    if (accumulator >= 1.0f) {
      int framesToAdvance = (int)accumulator;
      accumulator -= framesToAdvance;

      // Update the current frame based on direction.
      if (!isReversed) {
        currentFrame += framesToAdvance;
        if (currentFrame > endFrame) {
          if (loop) {
            // Wrap around: determine the range and use modulo arithmetic.
            int frameRange = endFrame - startFrame + 1;
            currentFrame = startFrame + ((currentFrame - startFrame) % frameRange);
          } else {
            currentFrame = endFrame;
          }
        }
      } else {  // If animation is reversed
        currentFrame -= framesToAdvance;
        if (currentFrame < startFrame) {
          if (loop) {
            int frameRange = endFrame - startFrame + 1;
            // Adjust for underflow using modulo arithmetic.
            int diff = startFrame - currentFrame;
            currentFrame = endFrame - ((diff - 1) % frameRange);
          } else {
            currentFrame = startFrame;
          }
        }
      }
    }
  }

  // Return the updated values: currentFrame, isFirstCycle flag, and the accumulator.
  pd->lua->pushInt(currentFrame);
  pd->lua->pushInt(isFirstCycle);
  pd->lua->pushFloat(accumulator);

  return 3;
}
