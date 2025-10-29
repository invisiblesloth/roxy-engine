# Roxy Engine for Playdate

A performance-focused, open-source game engine for Playdate. With C-acceleration 🚀

> **Note:** Roxy is currently in pre-release. Features and APIs may evolve before version 1.0.

---

## Features

**Core Systems**
- Scene management with stacking and transitions
- Camera with smoothing, shake, and parallax
- Input handling (buttons and crank)
- Audio system (music and sound effects)
- Save/load with multiple slots

**Graphics & Animation**
- Sprite and actor systems with state machines
- C-accelerated particle system
- Multiple tilemap formats (orthogonal, isometric, staggered)
- 50+ easing functions for tweening

**Performance**
- C-optimized critical systems
- Asset pooling and caching
- Automatic culling and dirty rect optimization

---

## Setup ⚙️

### Use the Project Template (Recommended)

The fastest way to start a new Roxy project is to use the [Project Template](https://github.com/invisiblesloth/roxy-engine-project-template):

1. Go to the [roxy-engine-project-template](https://github.com/invisiblesloth/roxy-engine-project-template) repository.
2. Click "Use this template".
3. Choose "Create a new repository".
4. Name your project and select visibility (public/private).
5. Clone your new repository locally:

   ```bash
   git clone --recurse-submodules https://github.com/your-username/your-new-repo.git
   ```

> 💡 The `--recurse-submodules` flag makes sure that Roxy Engine is cloned into `source/libraries/roxy`.

### Manual Download

1. Clone or download this repository. We recommend placing it inside `libraries/roxy/` relative to your `main.lua` file.

2. Then set up Roxy in your `main.lua` file like so:

   ```lua
   import "libraries/roxy/roxy"
   roxy.new(MyStartingScene)
   ```

## Support 💬

Questions or feedback? Contact us at [support@invisiblesloth.com](mailto:support@invisiblesloth.com). We would love to hear about your experience using Roxy!

## License ⚖️

This project is licensed under the MIT License. Portions of Roxy are inspired by Noble Engine and Nic Magnier's Playdate Sequence library. Easing functions in C adapted from Robert Penner's Easing Equations.

[👉 Details](./LICENSE)

---

*Thanks for your interest and support!*
