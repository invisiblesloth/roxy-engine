#include "roxy_input.h"

static PlaydateAPI* pd = NULL;
static void updateButtonStates(void);

// ----------------------------------------
// ! Button Mappings
// ----------------------------------------

// Structure to map button names to their corresponding PDButtons enum
typedef struct {
    const char* name;
    PDButtons button;
} ButtonMapping;

// Buttons we want to track (indexes 0..5)
static const ButtonMapping buttons[] = {
    { "A",    kButtonA     },
    { "B",    kButtonB     },
    { "up",   kButtonUp    },
    { "down", kButtonDown  },
    { "left", kButtonLeft  },
    { "right",kButtonRight },
};

// Number of tracked buttons
#define NUM_BUTTONS (sizeof(buttons) / sizeof(buttons[0]))

// ----------------------------------------
// ! Cached State & Configuration
// ----------------------------------------

// Cached button states (updated once per frame)
static PDButtons currentState = 0;

// Track how long each button is held (in frames)
static int buttonHoldCounts[NUM_BUTTONS] = {0};

// Configurable from Lua: Number of frames a button must be held 
// before triggering a hold event.
static int buttonHoldBufferAmount = 3; // Default: 3 frames

void roxy_input_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// ----------------------------------------
// Public API
// ----------------------------------------

// ! Set Button Hold Buffer Amount
// Called from Lua to set hold buffer amount in C
int roxy_input_setButtonHoldBufferAmount_l(lua_State* L)
{
    if (!pd) return 0;
    buttonHoldBufferAmount = pd->lua->getArgInt(1);
    return 0;
}

// ! Process All Buttons
/**
 * roxy_input_processAllButtons_l:
 *   - Updates the button states.
 *   - For each button, if it is currently held, increments its hold count continuously.
 *   - Once the hold count meets or exceeds the configured buffer amount,
 *     the function pushes the corresponding continuous (hold) callback string
 *     onto the Lua stack.
 *   - If a button is not held, its hold count is reset.
 *
 * This function ignores press and release events so that those are handled
 * directly by the Playdate SDK.
 *
 * Returns the total number of hold event strings pushed onto the Lua stack.
 */
int roxy_input_processAllButtons_l(lua_State* L)
{
    if (!pd) {
        // If the Playdate API pointer isn't set, return 0 events.
        return 0;
    }

    // 1) Update the button states
    updateButtonStates();

    if (currentState == 0) return 0;

    // 2) Iterate over each button to check for continuous hold events.
    uint32_t bitmask = 0;
    for (int i = 0; i < NUM_BUTTONS; i++) {
        PDButtons buttonMask = buttons[i].button;

        // If the button is held down...
        if (currentState & buttonMask) {
            // Increment the hold count continuously.
            buttonHoldCounts[i]++;

            // If the hold count has reached or exceeded the buffer,
            // push the hold event callback.
            if (buttonHoldCounts[i] >= buttonHoldBufferAmount) {
                bitmask |= (1u << i);
            }
        } else {
            // Button is not held; reset its hold count.
            buttonHoldCounts[i] = 0;
        }
    }

    // Return the count of strings we just pushed.
    if (bitmask) {
        pd->lua->pushInt(bitmask);
        return 1;
    }
    return 0;
}

// ----------------------------------------
// Internal Functions
// ----------------------------------------

// ! Update Button States
// Retrieves and caches button states (only current state is needed now)
static inline void updateButtonStates(void)
{
    if (!pd) return; // Prevent potential crash if API is not set
    pd->system->getButtonState(&currentState, NULL, NULL);
}
