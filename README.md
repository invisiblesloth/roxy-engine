# Roxy Playdate Game Engine

Roxy is a fast and easy-to-use game engine for Playdate – or at least, that's the goal. Right now, Roxy is in pre-release, meaning several key features, such as tools for managing text, sound, music, and more, are still in development. In other words, we've got some work to do before it's ready even for a beta release. However, we're super excited about Roxy and eager to share it in its current state. Check out the current features and roadmap for more details. We're building Roxy for ourselves, aiming to create a reliable and performant foundation for our creative game ideas. Maybe Roxy can help you too.

***

### Features

- **Modular Scene Lifecycle Management:** Manage update loops, sprites, and input handling on a per-scene basis.
- **Smooth Scene Transitions:** Incorporate smooth transitions between scenes with a variety of common transition types using a straightforward API.
- **Delta Time Support:** Keep your game running smoothly across different frame rates with built-in delta time management.
- **Settings and Save Game API:** Easily manage game settings and save data, ensuring persistent and customizable game experiences.
- **Base Menu Object:** Quickly create simple, one-column text menus with an easy-to-use base menu object.
- **Dynamic Sequencer:** Craft complex animations by combining customizable easings.
- **High-Performance Math and Easing Functions:*** Written in C for optimal performance and  accessible for your game.
- **Powerful Input Handling:** Manage input events, including button presses, holds, and the Playdate crank, with flexible and customizable handlers.
- **Configurable Engine:** Easily customize Roxy’s behavior and settings through a `config.json` file, allowing fine-tuned control over transitions, input thresholds, save slots, and more.
- **Extensible Framework:** Built with extensibility in mind, Roxy allows you to add your own custom features and modules without hassle.
- **Utility Goodies:** Load JSON files, manipulate tables, and more with convenient utilities included in Roxy.

***

### Setup

Before you begin, make sure you have the Playdate SDK installed and configured correctly on your system.

Follow these steps to set up Roxy in your project:

1. **Download or Clone:** Get the repository and place it into the `libraries/roxy/` directory within your new or existing project.

2. **Add to Project:**
    - Ensure `CMakeLists.txt` and `Makefile` are in the root directory of your project.
    - Note: Your `main.lua` file might be located in a subdirectory such as `source`. Regardless, `CMakeLists.txt` and `Makefile` should be at the top level of your project's directory structure.

3. **Import and Use:**
    Add the following to your `main.lua` file to start using Roxy:

    ```lua
    import "libraries/roxy/Roxy"
    import "scenes/MyStartingScene"  -- Replace with your game's starting scene
    
    local roxy = Roxy()
    roxy:registerScenes(MyStartingScene)
    roxy:new(MyStartingScene)
    ```

4. **Start with the Scene Template:**
    To speed up development, use the provided `SceneTemplate.lua` as a foundation for your scenes. This template includes detailed instructions and examples to help you set up scenes efficiently. Simply copy `SceneTemplate.lua` into your "scenes" directory, rename it, and modify it to fit your game's needs.

***

### Configurations

- **`transitions`**: Defines the available scene transitions.
- **`defaultTransition`**: Sets the default transition type. Default: `"Cut"`.
- **`defaultTransitionDuration`**: Duration for the default transition, in seconds. Default: `1.5`.
- **`defaultTransitionHoldTime`**: Hold time before completing the transition, in seconds. Default: `0.25`.
- **`holdTimeAddsToDuration`**: If `true`, adds hold time to the total transition duration. Default: `false` (subtracts hold time from the duration).
- **`useFullDurationForMixTransitions`**: If `true`, uses the full duration for mixed transitions. Default: `false` (blends only half the duration for smoother feel).
- **`maxSaveSlots`**: Maximum number of save slots. Default: `3`, but it adjusts automatically if more slots are needed, up to a maximum of `1000`.
- **`customHoldThreshold`**: Custom threshold for `XButtonCustomHeld` input hold duration, in frames. Default: `20` (about ⅔ second at 30 FPS).
- **`crankDirection`**: Crank direction for increasing ticks. Default: `1` (clockwise). The other option is `-1` for counterclockwise.
- **`showFPS`**: If `true`, displays the FPS counter. Default: `false`.
- **`fpsPosition`**: Position of the FPS counter on the screen. Default: `"bottomRight"`. Options: `"topLeft"`, `"topRight"`, `"bottomLeft"`, `"bottomRight"`.

***

### Documentation

Roxy includes inline code documentation. Comprehensive web documentation is planned.

***

### Contact & Support

For any issues or questions, reach out to us at support@invisiblesloth.com. We're a small team, so please be patient, and we'll get back to you as soon as possible.

***

### Change Log

For a detailed history of changes and updates, please refer to the [CHANGELOG.md](./CHANGELOG.md).

***

### Roadmap
   
- **Custom Graphics for Roxy:** Add custom graphics specifically for the Roxy game engine.
- **Roxy Name Inspiration:** Add notes to the README.md file explaining the inspiration behind the name "Roxy."
- **Additional Example Templates:** Expand the available templates to include examples for using RoxyMenu, RoxySprite, and RoxyAnimation. Currently, we have templates for RoxyScene and main.lua.
- **Example Project Template:** Create a separate GitHub repository featuring a project template that includes the Roxy game engine as a submodule.
- **C Integration Instructions:** Provide detailed instructions on how to adjust `CMakeLists.txt` and `Makefile` for projects that include native C code alongside Roxy.
- **RoxySprite and RoxyAnimation Improvements:** Review, test, and update these older components to ensure they meet current standards and performance expectations.
- **Expanded Engine Configurations:** Introduce more options for engine-specific configurations to give developers greater control. *(See `config.json` for current configuration options.)*
- **Expanded Crank Input Mapping:** Implement advanced crank input features, such as customizable crank sensitivity.
- **Customizable Image Table Transitions:** Allow developers to replace the default transition images with their own custom graphics.
- **Expanded Text Manipulation:** Add features like text wrapping and text crawl to enhance text handling capabilities.
- **Custom Fonts:** Provide custom fonts for use within games.
- **Sound Manager:** Develop a comprehensive sound management system for handling in-game audio.
- **Accelerometer Input API:** Introduce additional input controls for the Playdate’s accelerometer.
- **Merge Input Handlers:** Provide the ability to merge multiple input handlers for more flexible input management.
- **RoxyMenu Improvements:** Enhance the RoxyMenu with animation options, sound effects, and the ability to remove or update menu items dynamically.
- **Additional Transitions:** Add more transition options to give developers greater variety and customization.
- **Custom Transitions:** Expand customization options and improve the user-friendliness of creating and integrating custom transitions.
- **Music Manager:** Build a dedicated music management system to handle in-game music tracks.

*Note: This roadmap represents a prioritized list of planned features. It is not a strict timeline, and features may be added, removed, or adjusted as development progresses. Features under consideration are not yet planned but are being evaluated for potential inclusion. If any of these features are greenlit, they may be inserted into the roadmap at any stage, not necessarily after the current list.*

### Features Under Consideration

Note: We're not certain how to approach these features yet or if they are even possible. These are just ideas that we think might be useful or needed by game developers—and by ourselves. Remember, we're making Roxy for ourselves too.

- **Expanded Documentation:** Create a comprehensive website detailing Roxy's usage, potentially hosted on GitHub via GitHub Pages.
- **Asset Pipeline and Management:** Introduce tools for managing and optimizing game assets (images, sounds, fonts).
- **Dynamic Asset Loading:** Support dynamic loading and unloading of assets to manage memory usage more efficiently during gameplay.
- **Scene Management Enhancements:** Implement the ability to push and pop scenes within the engine.
- **Multi-Language Text Support:** Provide APIs and tools for supporting multiple languages, including text replacement and font management for different character sets.
- **Playdate System Menu API Integration:** Simplify the process of integrating custom options or toggles into the Playdate system menu.
- **2D Physics Support:** Offer optional support for a lightweight 2D physics engine tailored to the capabilities of the Playdate.
- **Customizable Game Loop:** Explore options for allowing developers to specify which features they want to include in the Roxy game loop to improve game performance. This could be achieved through:
1. **Detailed Instructions:** Provide guidance on how to manually remove unnecessary features from the game loop.
2. **Predefined Game Loops:** Allow developers to choose from a set of predefined game loops via configuration and set using `Roxy:setUpGameLoop()`, selecting the one that best fits their needs for optimal performance.
3. **Dynamic Game Loop Builder:** Investigate the possibility of dynamically building a custom game loop based on selected features, prioritizing performance.
- **Custom Programmatic Fonts:** Similar to custom raster-based fonts, these fonts would be built programmatically in-game, allowing for dynamic effects such as shake or wiggle.
- **Font Effects:** Introduce effects that work with custom fonts, such as animating text into place or adding a "wiggle" effect to programmatic fonts.
- **Overlay Effects:** Develop overlay effects like shake, glitch/noise/static, and old film effects that can be applied at the game loop level to stylize the gameplay. These could also be integrated with transitions and potentially include sound effects.

***

### Potential Challenges & Open Questions

- **RoxySprite and RoxyAnimation Stability:** These components are older and require more rigorous testing. They may need significant updates to meet current standards, so expect potential changes or improvements.

- **Object Pools:** While object pools help manage memory, they come with challenges, such as potential complications in managing state across different scenes or transitions. Additionally, they might contain more objects than needed, leading to higher memory usage. We are evaluating whether this approach is the best fit for Roxy.

***

### License

Roxy is licensed under the MIT License. This summary is provided for convenience. The full text of the license, which governs your use of Roxy, is available in the [LICENSE](./LICENSE) file.

**Key Points:**

- You are free to use, copy, modify, and distribute Roxy, provided that the original copyright notice and license are included in all copies or substantial portions of the software.
- The software is provided "as is," without any warranty of any kind.
- For any questions or clarifications, please refer to the full [LICENSE](./LICENSE) file.

**Acknowledgements and Adaptations:**

- **Noble Engine:** Portions of Roxy were inspired by and adapted from the Noble Engine by Mark LaCroix and Noble Robot. While Roxy incorporates similar functionalities, it features unique implementations and enhancements that make it distinct.
- **Easing Functions:** The easing functions in Roxy are adapted from Robert Penner's Easing Equations, licensed under the BSD License. These functions are used in various parts of the engine and can be found in the `roxy_ease.h` and `roxy_ease.c` files.
- **Playdate Sequence:** Roxy's sequence functionality and flat easing function are based on Nic Magnier's Playdate Sequence library. The RoxySequence has been significantly modified to suit the engine's needs, with unique implementations and performance enhancements.

Future versions of Roxy may include certain logo assets with a different license than the MIT License.

For more detailed information, please refer to the full [LICENSE](./LICENSE) file and the corresponding sections within the license file itself.
