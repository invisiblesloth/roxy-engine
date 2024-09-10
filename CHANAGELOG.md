### Version 0.5.0 - 10-Sep 2024

- **Version Maturity**:
  - This release marks the transition to a stricter adherence to **Semantic Versioning (SemVer) 2.0.0**. Future releases will follow this structured approach, ensuring that the version number accurately reflects changes in functionality, bug fixes, and API stability.
  
- **Version Number Update**:
  - Updated the version number in `roxy.lua` to reflect `v0.5.0` as part of this shift towards formalized versioning.
  
This update primarily focuses on process changes related to versioning, without introducing new features or bug fixes.

### Version 0.4.4 - 10-Sep 2024

- **Repository Cleanup:**
  - Removed the `.nova/Tasks/Playdate Simulator.json` file and the associated `.nova` folder that were unintentionally included in the repository. These files were not needed for the engine’s functionality.
  - Removed all `.DS_Store` files from the repository and updated the `.gitignore` file to ensure these macOS system files are no longer included in future commits.

- **Version Correction:**
  - Corrected the version number in `roxy.lua`, which was erroneously marked as v0.4.4 in version 0.4.3. This has been updated to reflect the correct version in alignment with the repository.

These updates focus on cleaning up unnecessary files and preventing them from being reintroduced, ensuring a more polished and professional repository.

### Version 0.4.3 - 19-Aug 2024

- **README.md Enhancements:**
  - Further refined the wording and structure of the README.md file.
  - Added horizontal rules (`***`) to help compartmentalize sections for better readability.
  - Reordered sections for improved flow: Features, Setup, Configurations, Documentation, Change Log, Roadmap, Features Under Consideration, Potential Challenges & Open Questions, and License.
  - Added a new **Configurations** section, providing a detailed breakdown of available configuration options in `config.json`.
  - Added a new **Potential Challenges & Open Questions** section to the README.md to highlight areas requiring further testing and evaluation, including the stability of `RoxySprite` and `RoxyAnimation`, and the usage of object pools. 
  - Introduced a **License** section, summarizing the MIT License under which Roxy is released and acknowledging inspirations and adaptations.
  - Added a new **Contact & Support** section with the support email, indicating that responses may take time as the team is small.

- **New Template Files:**
  - Added a `mainTemplate.lua.example` file, similar to `SceneTemplate.lua`, providing a guided structure for setting up a `main.lua` file. The template includes instructions and best practices for initializing Roxy, registering scenes, setting up game settings and data, and launching the game.

- **Default Configurations:**
  - Updated `config.json` to set the default transition to `"Cut"` as it is the simplest transition.

- **Cleanup and Build Improvements:**
  - Renamed template files to end in `.example` (e.g., `mainTemplate.lua.example`) to avoid issues during the build process caused by non-existent referenced files in templates.
  - Removed unused graphics files from `source/assets/images` and `source/libraries/assets/images` to clean up the project directory.

- **Sequence Management Enhancements:**
  - Added a table of sequences (`self.sequences`) to the base `RoxyScene` class.
  - Introduced methods for adding, removing, and clearing sequences associated with a scene:
	- `RoxyScene:addSequence(sequence)`
	- `RoxyScene:removeSequence(sequence)`
	- `RoxyScene:removeAllSequences()`
  - These changes allow for more precise cleanup of scene-specific sequences, ensuring that transition sequences and other global sequences are unaffected.

- **Miscellaneous Changes:**
  - Updated the `updateSettingsIfChanged` parameter to `updateValuesIfChanged` in `Roxy.lua` to match the latest changes in `SettingsManager`.

These updates improve the usability, organization, and maintainability of the Roxy game engine, providing better documentation, enhanced sequence management, and a more polished setup experience.

### Version 0.4.2 - 16-Aug 2024

- **Updated Header Comment:**
  - The header comment at the top of `Roxy.lua` has been updated to accurately reflect the current version and license information:
	```
	-- Roxy Game Engine
	-- version: 0.4.2
	-- License: MIT
	```

- **Image Table Transition Enhancements:**
  - The visuals for the Image Table transition have been revamped to be more interesting and polished. This update builds upon the simplifications made in Version 0.4.0, which set the groundwork for these improvements.
  - Renamed the transition table PNG files:
	- `filmTransitionHead-table-400-240.png` is now `SLOTHUniversalLeaderEnter-table-400-240.png`
	- `filmTransitionTail-table-400-240.png` is now `SLOTHUniversalLeaderExit-table-400-240.png`

- **New Scene Template:**
  - A comprehensive scene template (`SceneTemplate.lua`) has been created, complete with detailed instructions to guide developers in creating scenes for their games. The template includes recommended practices for performance optimization, input handling, and scene lifecycle management, helping users get started quickly and efficiently.

- **README.md Enhancements:**
  - The README.md file has been significantly updated:
	- **About Section:** Expanded to clarify that Roxy is in a pre-release state, with a clear explanation of its current status and future goals.
	- **Feature List:** Expanded and refined to provide a more comprehensive overview of what Roxy offers.
	- **Setup Instructions:** Improved clarity and accuracy in the setup instructions, with the removal of the project template reference (which will be released later).
	- **Roadmap:** Expanded with a prioritized list of upcoming features, and a new "Features Under Consideration" section to highlight potential future developments.

These updates further polish the Roxy game engine, making it easier for developers to create and manage scenes, while also providing clearer guidance and future development plans.

### Version 0.4.1 - 15-Aug 2024

- **RoxyMenu Simplifications**:
  - Removed the ability to remove or update menu items, streamlining the menu system.
  - Eliminated unused methods: `updateMenuWidths()`, `updateMenuHeight()`, and `calculateItemWidths(nameOrKey, string)` to simplify the codebase.
  - Improved the efficiency of the `addItem` method by directly calculating and updating menu width only when necessary.

- **New Testing Tools**:
  - Created a test scene for RoxyMenu to assess auto width and height functionality with a large number of menu items.
  - Enhanced menu navigation control tests:
	- Added support for quick navigation via press and hold.
	- Integrated crank input for smooth menu navigation.

- **Code and Comment Refinements**:
  - Reviewed and updated comments across the entire codebase for consistency, clarity, and to follow best practices.
  - Updated `updateDeltaTime_l(lua_State* L)` for improved clarity and efficiency, with an early return if the Playdate API is not initialized.
  - Removed the now-unused `previousTime` variable from `Roxy.lua`.

- **RoxyTransition Improvements**:
  - Removed the `self.transitionTimer` leftover from debugging in version 0.4.0.
  - Ensured that the codebase consistently uses common Lua idioms, such as `self.singleAnimationLoop = singleAnimationLoop ~= false` in RoxySprite.
  - Restored the standard approach in the `setIsPaused` method in RoxySprite by reverting from `_isPaused` to `isPaused` after resolving a previous variable conflict.

- **Miscellaneous Changes**:
  - Removed the redundant `roxy.graphics.screenshot()` function in favor of directly calling `Graphics.getDisplayImage()` to improve performance.
  - Updated comments and documentation for critical modules, including `ConfigurationManager`, `GameDataManager`, `SceneManager`, `SequenceManager`, `SettingsManager`, `TransitionManager`, `RoxyScene`, `RoxySequence`, `RoxySprite`, `RoxyMenu`, `RoxyEase`, `roxyGraphics`, `roxyMath`, `roxyTables`, and `roxyText`.

These updates improve the codebase's clarity, maintainability, and performance, focusing on streamlining the RoxyMenu, enhancing testing capabilities, and refining documentation.

### Version 0.4.0 - 14-Aug 2024

- **Scene Management Enhancements**:
  - Removed `RoxyScene:removePopup()` and the associated call in `RoxyScene:cleanup()` since `RoxyPopup` was deprecated in version 0.3.0.
  - Renamed `RoxyScene:clearGraphics()` to `RoxyScene:clearScreen()` to align with Playdate SDK API terminology.
  - Updated scenes extending `RoxyScene` to include the `background` parameter in their initialization methods.
  - Renamed the scene lifecycle phases for clarity: `Load` to `Enter`, `Enter` to `Start`, to better align with transition phases.
  - Moved pausing sprites and disabling collisions from the `Exit` phase to the `Cleanup` phase, allowing scenes to animate until they are no longer drawn.
  - Moved `sequenceManager:removeAll()` from `RoxyScene:cleanup()` to `RoxyTransition:execute()` to prevent premature termination of sequences during transitions.

- **Transition Updates**:
  - Introduced two new configuration properties:
	- `holdTimeAddsToDuration`: Controls whether the hold time adds to or subtracts from the transition duration. Defaults to `false`.
	- `useFullDurationForMixTransitions`: Controls whether mix-type transitions, like Cross Dissolve, use the full duration or half. Defaults to `false`.
  - Updated `CrossDissolve` to use `Ease.outQuad` instead of `Ease.outCubic` for a more visually accurate completion.
  - Simplified the visuals for the Image Table transition while maintaining its film leader countdown inspiration.
  - Consolidated all transition execution functionality into `RoxyTransition`, removing it from `TransitionManager` for better organization and maintainability.
  - Added `currentScene = nil` in `RoxyTransition:execute()` to ensure the current scene is garbage collected after cleanup.

- **Input Handling and Sequence Management**:
  - Added `SequenceManager:stopAll()` to stop all running sequences.
  - Removed the limit on input handling during transitions, allowing input processing to continue during a transition.
  - Enhanced error prevention in `InputManager:handleInput()` by adding a check to ensure `self.currentHandler` exists before accessing it.

- **Code Refinements**:
  - Renamed `oldScene` and `oldSceneScreenshot` to `currentScene` and `currentSceneScreenshot` for clarity.
  - Replaced `Graphics.image.kDitherTypeBayer2x2` with `Graphics.image.kDitherTypeBayer8x8` for improved visual quality during transitions.
  - Removed the `self.isActive` flag from `RoxyTransition`, as it was redundant with `self.isTransitioning` managed by `TransitionManager`.

- **Testing and Cleanup**:
  - Removed old test scenes and created two new ones (MainMenu and SecondaryMenu) for trialing all available transitions.
  - Renamed `newTransition` in `TransitionManager:transitionToScene()` in favor of a simpler `transition` reference.

These updates improve the performance, clarity, and maintainability of the Roxy game engine, with significant enhancements to scene management, transitions, and input handling.

### Version 0.3.6 - 13-Aug 2024

- **Code Simplifications**:
  - **RoxyScene**:
	- Removed legacy references to `RoxyPopup` in `RoxyScene:pause()` and `RoxyScene:resume()`, streamlining the pause and resume functionality for scenes.
  - **RoxySprite**:
	- Updated `RoxySprite:update()` to reduce unnecessary calls to `markDirty()`, only marking the sprite as dirty when the animation frame changes, improving performance for animated sprites.
  - **SceneManager**:
	- Simplified the `SceneManager:setUpBackgroundDrawing()` method by refining the background drawing callback, removing unnecessary conditional logic.
  - **Main Game Loop**:
	- Simplified the transition drawing check in the main game loop, removing redundant checks and ensuring the transition is always drawn when active.

- **Transition Updates**:
  - **CrossDissolve and Imagetable Transitions**:
	- Updated these transitions to no longer accept a hold time, enforcing a default hold time of `0.0` for smoother transition execution.

These updates focus on simplifying and optimizing key components of the Roxy game engine, improving performance and code maintainability while ensuring smoother transition handling.

### Version 0.3.5

- **Reorganization and Code Improvements**:
  - **Main Game Loop**:
	- Reorganized the main game loop to improve efficiency and readability by grouping drawing functions together and moving timer updates to the end of the loop.

- **Bug Fixes**:
  - **Sprite Initialization**:
	- Fixed a typo in the `PerformanceTest` scene where both sprites were mistakenly using the same placeholder variable. Each sprite now correctly uses its own unique variable.
  - **RoxyMenu**:
	- Fixed a bug where the selected item in `RoxyMenu` would not show up when the menu was inactive due to matching text and background colors.

- **Method Enhancements**:
  - **RoxyScene and RoxySprite**:
	- Reworked `RoxyScene:addSprite()` and `RoxyScene:removeSprite()` methods to no longer pass the sprite name to `RoxySprite:add()` or `RoxySprite:remove()`. These methods now directly handle sprite objects, improving flexibility when renaming sprites.
  - **Transition Execution**:
	- Moved `newScene:resetDrawOffset()` to execute earlier during transition midpoint, ensuring scene offset is reset before the new scene is loaded.
	- Removed redundant `execute()` methods from Cut and Imagetable transitions as they only called the superclass method without any modification.
	- Reordered `RoxyTransition:setUpSequence()` to fully configure and start the transition sequence before executing the function, which enhances animation performance.
	- Updated `RoxyTransition:execute()` to simplify and ensure the `onMidpoint` function is called only once, eliminating an unnecessary check and ensuring smoother transitions.

- **InputManager Enhancements**:
  - Added a `crankDirection` property with methods for getting, setting, and resetting the crank direction, providing more control over input handling.

- **RoxyMenu Refactor**:
  - **Code Cleanup and Organization**:
	- Refined comments, reorganized methods, and cleaned up code for better readability and maintainability.
  - **Performance Improvements**:
	- Consolidated multiple methods into a single method to reduce overhead and improve performance.
	- Simplified math calculations in `RoxyMenu` to optimize menu rendering and height calculations.
  - **Bug Fixes**:
	- Fixed an issue where default dimensions were not set properly, leading to menu display inconsistencies.
	- Updated default `RoxyMenu` settings for more consistent behavior.

These updates enhance the organization, flexibility, and performance of the Roxy game engine, while also addressing important bug fixes and refining key components like RoxyMenu and transitions.

### Version 0.3.4

- **New Additions**:
  - **LICENSE and README Files**:
	- Added a comprehensive LICENSE file, including the MIT license for the Roxy Game Engine and notes on inspiration and adaptations.
	- Introduced a README.md file to provide initial documentation and setup instructions for the game engine.
  - **Utility Function**:
	- Introduced `roxyMath.lua`, featuring a new `roxy.math.isNaN(x)` utility to check for NaN (Not-a-Number) values.

- **Enhancements**:
  - **Imagetable Transition**:
	- Updated the Imagetable transition to default to a hold time of `0`, unless explicitly overridden. This replaces the previous behavior of using the configuration's default hold time.
  - **Scene Initialization**:
	- Refined the initialization method for individual scenes to accept `properties`, laying the groundwork for future enhancements.
	- Introduced a `defaultProperties` table in scene templates, merging with custom properties to streamline configuration and initialization. Adjusted the `SceneManager` object pool to accommodate this change, ensuring scenes now pull from the image pool rather than creating background images on the fly.

These updates introduce essential documentation, utility functions, and improvements to scene and transition handling, setting the stage for future development and customization.

### Version 0.3.3

- **Enhancements**:
  - **Object Pooling**:
	- Created an object pool for scenes managed by `SceneManager`, including pools for `background1` and `background2` images.
	- Updated `TransitionManager` to manage 3 instances of each transition object, while creating 2 instances for scene objects due to overlapping lifecycles.
	- Streamlined the object pool population for both `TransitionManager` and `SceneManager` to ensure efficient resource management.

  - **Code Refactoring**:
	- Reintroduced `self.x` and `self.y` in `RoxyTransition` as they are used by Mix type transitions.
	- Updated imagetable transitions to exclusively use linear easing for better consistency.
	- Moved drawing methods from specific transition classes back to their respective type classes to improve organization.
	- Updated the configuration file to include `transitions` within `defaultConfiguration`.

  - **General Improvements**:
	- Added the ability to pass the pool size to `populatePools(poolSize)` for both transitions and scenes.
	- Standardized the use of a Configuration Object Pattern (or Configuration Parameters Pattern) to manage properties across specific transitions, improving readability and maintainability. Transition type classes (Cut, Cover, Imagetable, and Mix) still use Inline Initialization (or Inline Properties) to minimize the number of objects needed for default properties.

  - **Performance Enhancements**:
	- Downgraded to `kDitherTypeBayer2x2` pattern from `kDitherTypeBayer4x4` to enhance performance in transitions using the `drawFaded` functionality.
	- Modified the Mix transition to utilize a local variable for `self.oldSceneScreenshot` to avoid redundant references, thus improving performance.

- **Bug Fixes**:
  - Fixed several issues with `TransitionManager`'s object pool where multiple objects were being improperly managed by the transition classes.
  - Corrected property inheritance in `FadeToBlack` and `FadeToWhite` transitions, ensuring `properties.dither` and other properties are correctly passed to the parent class.
  - Ensured that transitions correctly draw and handle `panelImage` properties, addressing an issue where these were not correctly utilized.

These updates focus on enhancing performance, improving code organization, and fixing critical bugs to ensure a more efficient and maintainable game engine.

### Version 0.3.2

- **Enhancements**:
  - **Object Pooling**:
	- Combined various object pools into a single table in `TransitionManager` for better organization and management. This includes pools for imagetables, images, dither patterns, and sequences.
	- Updated the Cover transition type to use the dither pattern stored in the dither pool: `transitionManager:getDither("bayer2x2")`.

  - **Code Refactoring**:
	- Further refactored `RoxyTransition` to improve readability and ensure consistent organization of transition properties in both `RoxyTransition` and its derived classes (e.g., Cut, Cover, Imagetable, and Mix).
	- Added comments to improve code clarity and maintenance.
	- Simplified the calculation for `durationExit` to enhance performance and readability by using the already calculated `durationEnter`.

  - **General Improvements**:
	- Added `self.newSceneScreenshot = nil` to the base `RoxyTransition` class to ensure it's available if a transition ever needs it.

These updates focus on enhancing the performance and maintainability of the Roxy game engine, improving transition handling, and ensuring a more stable and efficient experience for developers.

### Version 0.3.1

- **Enhancements**:
  - **Object Pooling**:
	- Introduced object pools for transitions in `TransitionManager` to optimize performance and reduce garbage collection overhead. Object pools include imagetables, images, dither patterns, and sequences.

  - **Code Refactoring**:
	- Refactored transition classes to improve organization and readability.
	- Cleaned up comments in `SceneManager` for better code clarity.
	- Simplified the guard clause in `TransitionManager:prepareTransitionScreenshot()` to avoid redundancy.

  - **Performance Improvements**:
	- Made minor performance enhancements to `RoxySequence`, including optimizing method calls and reducing redundant property accesses.
	- Ensured `pd.drawFPS(self.fpsX, self.fpsY)` is called at the end of the update method to guarantee it draws on top of all other elements.
	- Reworked the transition drawing method in `TransitionManager` to streamline the drawing process and improve performance.

- **Bug Fixes**:
  - **Transition Progress**:
	- Fixed a bug where imagetable transitions could result in `NaN` progress values under certain conditions.
	- Added checks for `NaN` in `RoxyAnimation` and `RoxySequence` to prevent invalid progress values.

  - **TransitionManager**:
	- Updated `TransitionManager:prepareTransitionScreenshot()` to handle cases where `currentTransition` was reset.
	- Removed unused properties `self.dither` and `self.panelImage` from `RoxyImagetableTransition` to clean up code.

These updates focus on enhancing the performance and maintainability of the Roxy game engine, improving transition handling, and ensuring a more stable and efficient experience for developers.

### Version 0.3.0

- **Enhancements**:
  - **Folder Structure**:
	- Created a `core/` folder and moved relevant classes and managers into it for better organization and clarity of the core functionality of Roxy.

- **Code Cleanup**:
  - **Class Removal**:
	- Removed `RoxyPopup` and `RoxyConfirmationToast` classes as they were not fully designed or considered part of the core functionality for Roxy.
  - **Debug and Performance Code**:
	- Removed time log, `sample(name, function)`, and other code related to performance testing and debugging to streamline the codebase.

These updates focus on refining the structure of the Roxy game engine, removing unnecessary components, and cleaning up code related to performance testing, ensuring a cleaner and more maintainable codebase.

### Version 0.2.11

- **Enhancements**:
  - **Background Management**:
	- Consolidated `RoxyScene:setBackgroundImage()` and `RoxyScene:setBackgroundColor()` into a single method for improved clarity and code organization.
	- Refactored the derived scene class initialization to pass the initial background to the base scene class, which now handles background settings.
	- Introduced a `shouldDrawBackground` property in `RoxyScene` to bypass the `draw()` call for scenes without a background, potentially enhancing performance.
	- Combined graphical image functionality into `RoxyScene:setBackground(background)` and used `Graphics.clear(self.backgroundColor)` in `RoxyScene:drawBackground(x, y, width, height)` for cleaner and more performant code.
  - **Code Organization**:
	- Renamed the `third_party` folder to `libraries` for better structure, even though the Sequence library is currently not used in Roxy.

- **Bug Fixes**:
  - **Code Cleanup**:
	- Fixed a typo with a rogue `else` in `RoxyScene:removeSprite(sprite)`.
  - **Loop Adjustments**:
	- Adjusted for loops in `RoxyMenu:addItem()`, `RoxyMenu:cleanItemData()`, and `GameDataManager:resetAll()` to run in reverse to prevent issues with subsequent iterations.

These updates focus on enhancing the background management of scenes, improving code organization, fixing typographical errors, and ensuring loop iterations are handled correctly to prevent potential issues.

### Version 0.2.10

- **Enhancements**:
  - **Naming Conventions**:
	- Updated camel case for functions that "set up" things, such as `SceneManager:setUpBackgroundDrawing()`, throughout the codebase to ensure consistency.
	- Renamed `transitionClass` in `TransitionManager` to `newTransition` to align with the naming style of `newScene`.
  - **Sequence Management**:
	- Added `SequenceManager:removeAll()` to clear all sequences.
	- Integrated `SequenceManager:removeAll()` into `RoxyScene:exit()` to ensure sequences are properly managed, preventing sequences from continuing to run after a scene is cleared and so as not to affect transition sequences.
  - **Code Cleanup**:
	- Cleaned up `RoxyScene` code following the rework of `RoxyScene:drawBackground()`.
	- Enhanced test scenes with improved comments for better code readability and maintainability.

- **Bug Fixes**:
  - **Performance Improvements**:
	- Removed the forced garbage collection from the transition execution method, as it was found to negatively impact performance rather than improving it.

These updates focus on enhancing naming conventions for better code clarity, improving sequence management during scene transitions, and cleaning up code for improved maintainability. Additionally, performance has been improved by removing unnecessary forced garbage collection.

### Version 0.2.9

- **Enhancements**:
  - **RoxySprite**:
	- Added `setCenter` as a passthrough method to allow for method chaining.
  
  - **RoxyScene**:
	- Reworked `drawBackground` to use cached graphics, improving performance.
	- Added functionality to dynamically change the scene's background image or color.
	- Improved comments for better code readability and maintainability.
  
  - **Input Handling**:
	- Updated `RoxyScene:pause(excludePopups)`, `RoxyScene:resume(excludePopups)`, and `RoxyScene:exit()` to iterate in reverse order, ensuring all sprites are correctly paused, resumed, or disabled.

- **Bug Fixes**:
  - **Sprite Management**:
	- Fixed `RoxyScene:removeAllSprites()` to iterate over all sprites in reverse order, ensuring complete removal of all sprites from the scene.
  
  - **Sequence Management**:
	- Updated `SequenceManager:remove(sequenceToRemove)` to iterate in reverse order for consistency and to avoid potential issues when modifying the table during iteration.
  
  - **Settings Management**:
	- Updated `SettingsManager:resetSome(settingNames, saveToDisk)` to iterate in reverse order, preventing potential issues during table modification.

These updates focus on improving performance, enhancing the functionality and flexibility of the Roxy framework, and fixing critical bugs to ensure a more stable and efficient experience.

### Version 0.2.8

- **Enhancements**:
  - **Show FPS Optimization**:
	- Improved the `showFPS` functionality to calculate the FPS position during initialization rather than every game update tick. This change enhances performance by reducing unnecessary calculations.

- **Code Cleanup**:
  - **RoxyScene**:
	- Cleaned up comments and reorganized the code for better readability and maintainability.
	- Moved the creation of `self.inputHandler = {}` to a scene's `init` method, eliminating the need for a separate `setupInputHandler` method.

- **Library Removal**:
  - Removed Nic Magnier's Sequence library and the associated test scene following the completion of testing. This streamlines the codebase and removes unnecessary dependencies.

These updates focus on optimizing performance, improving code organization, and cleaning up the codebase by removing unneeded components.

### Version 0.2.7

- **Bug Fixes**:
  - **GameDataCenter**:
	- Corrected a typo in `GameDataManager:validateMaxSlots(maxSlots)`.
	- Added missing `self.gameDataDefault = gameData` in `GameDataManager:setup(gameData, numberOfSlots, saveToDisk, modifyExistingData)`.
	- Fixed mismatch name for `MAX_SLOT_LIMIT`.
  - **roxy.c**:
	- Resolved missing easing function names in the C to Lua setup that were causing crashes on the device.

- **Enhancements**:
  - **Scene Management**:
	- Implemented a class alias pattern for scenes to streamline scene creation and renaming.
	- Cleaned up test scenes and optimized the `RoxySequence` test scene to prevent recreating the imagetable every frame.

- **Performance Monitoring**:
  - Added time logs and profiling tools to measure performance and identify bottlenecks. These logs will be removed in a future release.

These updates enhance the stability and usability of the Roxy framework, fix critical bugs, and introduce new features for better scene management and performance monitoring.

### Version 0.2.6

- **Enhancements**:
  - **Namespace Refinement**:
	- Renamed the project to "Roxy" instead of "Roxy Engine".
  
  - **RoxyMenu Improvements**:
	- Changed redundant print statements to error messages in `RoxyMenu`.
	- Fixed method chaining issue in `RoxyMenu:removeItem` that previously broke the chain when an error occurred while trying to remove an item.
  
  - **Code Quality**:
	- Removed redundant `// v0.2.5` comment from `roxy.c`.
	- Converted to direct attribute access within classes for properties like `isRunning` and `isActive` in `RoxySequence`, `RoxyMenu`, `RoxyBubble`, `RoxySprite`, `SequenceManager`, and `TransitionManager`.
	- Removed unused `self.customHoldThreshold` from `Roxy:init()`.
	- Removed debugging print statements from `GameDataManager`.
	- Removed useless `return` calls following error messages throughout the codebase to ensure they are never reached.

- **New Features**:
  - **Game Data Management**:
	- Added a configurable maximum number of save slots in `GameDataManager`. If a larger number of slots than the current maximum is specified during `GameDataManager:setup()`, the maximum will be increased up to a limit of 1000 slots.

- **Bug Fixes**:
  - **Menu Activation**:
	- Fixed an issue in `RoxyMenu` where activating an already active menu or clicking on an inactive menu would break method chaining.
  - **Attribute Management**:
	- Ensured that direct attribute access does not interfere with the expected functionality of `RoxySequence`, `RoxyMenu`, `RoxyBubble`, `RoxySprite`, `SequenceManager`, and `TransitionManager`.

These updates refine the namespace and naming conventions, improve the clarity and usability of menu-related functions, enhance code quality, and introduce new features for better game data management. Additionally, several bug fixes ensure a more robust and reliable experience with the Roxy framework.

### Version 0.2.5

- **New Features**:
  - **Game Data Management**:
	- Introduced the `GameDataManager` singleton to handle game data management. This new manager provides robust methods for initializing, setting, getting, resetting, and deleting game data slots. It supports features like adding slots dynamically and collapsing data slots.
	- Enhanced the `GameDataManager` to handle game data more efficiently, including improved methods for managing slots and resetting data. The class now provides better error handling and warnings, ensuring a smoother user experience.

- **Enhancements**:
  - **Settings Management**:
	- Converted the `RoxySettings` class to `SettingsManager` as a singleton, aligning it with other managers in the system. This change improves the consistency and structure of the Roxy Engine.
	- Optimized the `SettingsManager` for better performance and efficiency. Key methods such as `setup`, `set`, `reset`, and `save` have been refined for clarity and speed.

These updates introduce a powerful mechanism for managing game data, optimize settings management for better performance, and enhance the overall structure and consistency of the Roxy Engine.

### Version 0.2.4

- **Enhancements**:
  - **Namespace Refinement**:
	- Updated namespaces for utility modules:
	  - `roxy.utilities.tables` is now `roxy.table`.
	  - `roxy.utilities.json` is now `roxy.json`.
	  - `roxy.utilities.graphics` is now `roxy.graphics`.
	- Separated `roxyUtilities.lua` into distinct modules:
	  - `roxyTables.lua` for table utilities.
	  - `roxyJson.lua` for JSON utilities.
	  - `roxyGraphics.lua` for graphics utilities.

These updates enhance the clarity and organization of the Roxy Engine's namespace and module structure, making it easier for developers to find and use the utility functions they need.

### Version 0.2.3

- **New Features**:
  - **Game Settings Management**:
	- Introduced the `RoxySettings` class, enabling the ability to save and manage game settings (distinct from game data). This addition streamlines the process of initializing and managing game configurations.

- **Enhancements**:
  - **Roxy Utilities**:
	- Added `roxy = roxy or {}` to `roxyUtilities.lua` to ensure the `roxy` namespace is initialized properly.
	- Introduced the `keyChange()` function to `roxy.utilities.table` for efficiently detecting changes in table keys.
  
  - **Integration with Roxy**:
	- Integrated `RoxySettings` into the main `Roxy` class to simplify the initialization of game settings, making it easier to set up and retrieve game configurations.

- **Improvements**:
  - **Settings Management**:
	- Enhanced the `set` method in `RoxySettings` to accept either a single setting or a table of settings, providing flexibility in how settings are updated.
	- Implemented warnings for non-existent settings within the `settingExists` method, ensuring users are informed without halting execution.

These updates introduce a robust mechanism for managing game settings, improve the utility functions for better performance and reliability, and streamline the integration of settings management into the Roxy engine.

### Version 0.2.2

- **New Features**:
  - **C-Lua Integration**:
	- Ported `getClampedTime` function from Lua to C to improve performance for `RoxySequence`. The native implementation enhances efficiency during time calculations in sequences.

- **Enhancements**:
  - **Naming Conventions**:
	- Ensured that all Lua wrapper functions end in `_l` for clarity and consistency across the codebase.
	- Updated the namespace for native Input Manager functions to `roxy.input`, aligning it with other native function namespaces and moving away from the Lua `InputManager` class.
  
  - **Error Handling**:
	- Standardized the naming of error parameters in C functions to `error`, avoiding abbreviations like `err` or `optErr` to maintain consistency with the Roxy Engine practices.

  - **Code Quality**:
	- Added `(void)L;` throughout the C code to suppress warnings and clarify the intent, ensuring a cleaner and more understandable codebase.

These updates enhance the performance of critical functions in the Roxy Engine, improve the consistency of naming conventions, and ensure better error handling and code quality.

### Version 0.2.1

- **New Features**:
  - **C-Lua Integration**:
	- Created Roxy easing functions natively in C under the namespace `roxy.easingFunctions`.
	- Added `deltaTime` to `roxy.c` to provide delta time functionality for use in the Roxy Engine and games that utilize it.

- **Enhancements**:
  - **Naming Conventions**:
	- Updated the naming convention for Roxy Text from `Text` to `roxy.text` (e.g., `Text.setFont()` is now `roxy.text.setFont()`).
	- Renamed `roxy.utilities.tables`, `roxy.utilities.json`, and `roxy.utilities.graphics` to align with `roxy.text` and the Playdate SDK's naming conventions.
	- Ported Roxy Math to run natively in C and updated the naming convention to `roxy.math`.

- **Clean Up**:
  - **RoxySequence**:
	- Restored `RoxySequence` to run entirely in Lua, except for the easing functions, to prepare for a more robust approach to porting compartmentalized sections of `RoxySequence` to run natively in C.
	- Removed the notion of global pacing for `RoxySequence`.

These updates enhance the organization of the codebase, provide new native easing functions, and improve the clarity and consistency of naming conventions within the Roxy Engine. The addition of delta time functionality and the restoration of `RoxySequence` to Lua improve the robustness and maintainability of the engine. The removal of global pacing simplifies and streamlines the `RoxySequence` functionality.

### Version 0.2.0

- **New Features**:
  - **C-Lua Integration**:
	- Added `math_clamp_l` to expose `math_clamp` to Lua, enabling clamping functionality directly within Lua scripts.

- **Enhancements**:
  - **File Organization**:
	- Separated native C functions into `roxy.c`, `roxy_math.c`, `input_manager.c`, and `roxy_sequence.c`. These files are now located alongside their Lua counterparts in the "libraries/roxy" folder.
  - **Lua Binding Names**:
	- Improved the clarity of Lua binding names for native functions:
	  - `roxy.math` for mathematical utilities.
	  - `inputManagerNative` for input management functions.
	  - `roxySequenceNative` for sequence-related functions.

- **Bug Fixes**:
  - **Memory Management**:
	- Ensured proper initialization of `PlaydateAPI* pd` in each C file to prevent segmentation faults and improve stability.

These updates enhance the organization of the codebase, improve the clarity of Lua bindings, and extend the functionality available to Lua scripts, leading to a more robust and maintainable game engine.

### Version 0.1.31

- **New Features**:
  - **Method Chaining**:
	- Added method chaining support to `RoxyMenu` and `RoxyPopup`.

- **Enhancements**:
  - **RoxySequence**:
	- Improved `RoxySequence:update()` for better performance by ensuring the instance variable `previousUpdateTime` is consistently updated.

- **Bug Fixes**:
  - **Input Handling**:
	- Updated the fallback hold time for imagetable transitions from `0.25` seconds to `0` seconds, ensuring immediate response.

- **Improvements**:
  - **C-Lua Integration**:
	- Ported `getClampedTime` function from Lua to C for better performance and consistency. Updated `RoxySequence:updateCallbacks()` and `RoxySequence:getValue()` to use the C implementation of `getClampedTime`.

- **Removed Features**:
  - **RoxyBubble**:
	- Removed `RoxyBubble` as the feature wasn't fully considered and needed further refinement.

These updates enhance method chaining capabilities, improve the performance of sequence updates, and ensure more accurate clamping of time values within sequences. The removal of the incomplete `RoxyBubble` feature streamlines the library, focusing on more robust and thoroughly tested functionalities.

### Version 0.1.30

- **New Features**:
  - **Utilities**:
	- Added `Utilities.Tables.deepMerge()` to facilitate deep merging of tables.

- **Enhancements**:
  - **RoxyAnimation**:
	- Updated `RoxyAnimation:setAnimation()` to use the first animation in `animations` if no `name` is passed.
  - **RoxySprite**:
	- Updated `RoxySprite:playWithDelay()` to accept `delay` in seconds instead of milliseconds to match other methods in Roxy such as for `RoxySequence`.
	- Modified `RoxySprite:playWithDelay()` to use `self:play()` instead of unpausing directly.
  - **RoxyMenu**:
	- Improved `RoxyMenu:updateItem()` with validation and better error handling to ensure updates contain only expected properties and types.
  - **RoxySequence**:
	- Added a check in `RoxySequence:start()` to ensure a sequence is not added multiple times if it is already running.

These updates introduce new utility functions, enhance existing methods for consistency and error handling, and improve the overall robustness and performance of the Roxy Engine.

### Version 0.1.29

- **Bug Fixes**:
  - **RoxyPopup**:
	- Fixed an issue where `RoxyPopup` did not honor the change to `RoxyMenu:addItem()` where the display name and position elements were swapped, ensuring menu items display correctly.
  - **Math**:
	- Corrected a typo in `Math.round` where `math.floor` was incorrectly cased, ensuring proper rounding functionality.

- **Enhancements**:
  - **InputManager**:
	- Updated the native C input manager functions to run separate functions for each button, allowing multiple inputs to be handled in a single game tick. This improvement ensures that multiple button presses are processed simultaneously, enabling more complex input combinations such as diagonal movement.

These updates fix critical bugs related to menu item display and mathematical rounding, while also enhancing input handling capabilities, improving the overall responsiveness and functionality of the Roxy Engine.

### Version 0.1.28

- **Bug Fixes**:
  - **RoxySequence**:
	- Fixed an issue where `RoxySequence` did not honor `globalPacing` from the `SequenceManager`, ensuring sequences are paced correctly according to the global settings.

- **Enhancements**:
  - **InputManager**:
	- Updated `InputManager` to set `buttonHoldBufferAmount` and `customHoldThreshold` in the C layer for improved input handling and responsiveness.

- **Performance Improvements**:
  - **Roxy**:
	- Optimized the `Roxy:update()` method by minimizing redundant calls and improving the overall efficiency of the game loop.
	- Reduced the frequency of function calls within the update loop to enhance performance, ensuring smoother gameplay.

These updates improve the consistency of sequence pacing, enhance input handling flexibility, and optimize the core game loop for better performance and responsiveness in the Roxy Engine.

### Version 0.1.27

- **New Features**:
  - **Global Delta Time**:
	- Introduced `Global.deltaTime` to centralize time management across the game.
	  - Added a function to update `Global.deltaTime` based on the difference between the current and previous time.

- **Enhancements**:
  - **SequenceManager**:
	- Removed the functionality that previously calculated `deltaTime`, now using `Global.deltaTime` instead.
	- Streamlined the update process by leveraging the centralized delta time.

  - **RoxySequence**:
	- Updated to use `Global.deltaTime` instead of receiving `deltaTime` from the `SequenceManager`.
	- Added `setPreviousUpdateTime()` method to handle pauses and delays, ensuring sequences continue in real-time during events such as `playdate.stop()`, `playdate.wait()`, and `playdate.start()`.
	- Improved the `clear()` method to reset `previousUpdateTime`, ensuring proper sequence reset and avoiding stale time values.

These updates enhance the consistency and performance of time management in the Roxy Engine, providing developers with a centralized and reliable mechanism for handling time across different parts of the game. The new `setPreviousUpdateTime()` method in `RoxySequence` offers improved control over sequence timing during pauses and delays.

### Version 0.1.26

- **New Features**:
  - **SequenceManager**:
  - Added `getPacing()` and `setPacing()` methods to manage the pacing for all sequences globally.

  - **RoxySequence**:
  - Added `getPacing()` and `setPacing()` methods to manage the pacing for individual sequences.

- **Enhancements**:
  - **SequenceManager**:
  - Renamed `pacing` to `globalPacing` in the `update()` method to improve clarity.
  - Improved the performance of the `update()` method by storing the reference to `runningSequences`.

  - **RoxySequence**:
  - Accounted for pacing in the `update()` method.
  - Improved the performance of `getEasingByTime()` by storing the reference to `easingCount`.

These updates enhance the flexibility and performance of the Roxy Engine's sequence management, providing developers with improved control over sequence pacing and ensuring smoother and more efficient sequence updates.

### Version 0.1.25

- **Performance Improvements**:
  - **Performance Enhancements**:
	- Introduced `performance.c` to house key functions that benefit from running natively in C for improved performance.
	- Ported the main `for` loop in `InputManager`'s `handleInput()` method to C, creating the `inputManager_processButtonEvents()` function.

- **Enhanced Input Handling**:
  - **InputManager**:
	- Updated `InputManager:handleInput()` to utilize `inputManager.processButtonEvents()` for processing button events in C, reducing overhead and improving efficiency.
	- The C function `inputManager_processButtonEvents()` handles button state changes and hold actions, and triggers the appropriate callbacks for button pressed, released, and held events.

These updates significantly improve the performance of the Roxy Engine's input handling by leveraging C for computationally intensive tasks, resulting in faster and more efficient processing of button events.

### Version 0.1.24

- **New Utilities**:
  - **Graphics**:
	- Added `Utilities.Graphics.getRefreshRate()` to retrieve the display's refresh rate, with caching for improved performance.
	- Added checks for `Utilities.Graphics.displayWidthCenter` and `Utilities.Graphics.displayHeightCenter` in `Utilities.Graphics.getDisplaySize()` to ensure robust retrieval of display dimensions.
	- Refactored `Utilities.Graphics.getRefreshRate()` and `Utilities.Graphics.getDisplaySize()` for better error handling and efficiency.

- **Enhanced Input Handling**:
  - **InputManager**:
	- Updated `InputManager` to use a `customHoldThreshold` for triggering custom hold actions on buttons.
	- Improved input handler callback names for clarity, introducing `ButtonCustomHeld` to handle custom hold durations.

- **Configuration Updates**:
  - **Roxy Engine**:
	- Added `customHoldThreshold: 20` to the Roxy Engine default configuration, providing a customizable threshold for custom button hold actions.

These updates enhance the flexibility and robustness of the Roxy Engine's input handling and configuration management, offering developers more control and clarity when implementing custom input behaviors and graphical utilities.

### Version 0.1.23

- **Method Chaining**:
  - **RoxyAnimation**:
	- Added `return self` to key methods (`addAnimation`, `setAnimation`, `setSpeed`, `setFrameDuration`, etc.) to support method chaining, improving usability and code readability.
  - **RoxySprite**:
	- Added `return self` to outstanding methods to ensure consistency in method chaining throughout the class.

- **Improved Animation Control**:
  - **RoxyAnimation**:
	- Renamed `resetFirstFrame` to `resetAnimationStart` to better reflect its functionality of resetting the animation's start state.
	- Updated the `setSpeed` method to default to changing the speed for all animations unless explicitly told to change the speed for the current animation only.
  - **RoxySprite**:
	- Enhanced animation control methods (`play`, `pause`, `replay`, `stop`, `reverse`, etc.) to support method chaining, ensuring a more fluid and intuitive API.

- **Bug Fixes and Improvements**:
  - **Consistency**:
	- Ensured that all methods in `RoxySprite` and `RoxyAnimation` consistently return `self` where appropriate, supporting method chaining and improving code readability.
  - **Warnings and Errors**:
	- Improved warning messages for setting invalid `frameDuration` or `speed` values, ensuring developers are clearly informed of potential issues.

These updates significantly enhance the flexibility, control, and usability of the Roxy Engine's animation and sprite systems, providing developers with more precise and customizable animation handling, as well as a more intuitive API for managing animations.

### Version 0.1.22

- **New Features**:
  - **Frame Duration Handling**:
	- **RoxyAnimation**:
	  - Added the ability to specify `frameDuration` for each animation, which controls the number of game ticks each frame is displayed.
	  - Introduced `getFrameDuration` and `setFrameDuration` methods to retrieve and set the frame duration for animations.
	  - Improved the `update` method to account for `frameDuration`, ensuring accurate frame updates based on the specified duration.
	- **RoxySprite**:
	  - Added corresponding methods `getFrameDuration` and `setFrameDuration` to interact with `RoxyAnimation`'s frame duration settings.
	  - Enhanced control over animation timing by allowing developers to specify and adjust frame durations dynamically.

These updates significantly enhance the flexibility and control of the Roxy Engine's animation and sprite systems, resulting in more precise and customizable animation timing.

### Version 0.1.21

- **Performance Improvements**:
  - **RoxyAnimation Optimization**:
	- Reduced redundant lookups and used local variables for frequently accessed properties.
	- Streamlined conditional logic for better readability and performance.
	- Cached frequently accessed values to minimize repeated computations.
	- Refactored complex functions into simpler, more manageable pieces to improve readability.
	- Attempted to combine the `update` and `draw` methods for performance gains but reverted due to decreased performance.
  - **RoxySprite Optimization**:
	- Reduced redundant lookups and used local variables for frequently accessed properties.
	- Streamlined conditional logic for better readability and performance.
	- Cached frequently accessed values to minimize repeated computations.
	- Refactored complex functions into simpler, more manageable pieces to improve readability.

These updates significantly enhance the performance and maintainability of the Roxy Engine's animation and sprite systems, resulting in smoother and more efficient animations. The optimizations and code refactoring also improve code readability and ease of maintenance, making it easier for developers to work with the engine.

### Version 0.1.20

- **Performance Improvements**:
  - **Animation Handling Optimization**: Updated `RoxyAnimation` to use a custom `frameTick` mechanism instead of `pd.frameTimer`. This change enhances the efficiency and performance of animation updates, especially at higher speeds.
  - **Consistent Frame Skipping**: Implemented a mechanism where animations always start with the first frame when the speed is greater than 1, ensuring predictable behavior for designers.

- **Bug Fixes**:
  - **Smooth Animation Continuity**: Improved the handling of `nextContinuity` in `RoxyAnimation` to ensure seamless transitions between animations.

- **Code Refactoring**:
  - **RoxyAnimation Class Cleanup**: Removed unused and debug code from `RoxyAnimation`. Updated comments for better clarity and maintainability.
  - **RoxySprite Class Review**: Reviewed and optimized `RoxySprite` class. Improved comments, ensured consistent method returns, and added null checks to prevent potential errors.

These updates significantly enhance the performance and reliability of the Roxy Engine's animation system, ensuring smoother and more predictable sprite animations. The optimizations and code refactoring also improve maintainability and readability, making it easier for developers to work with the engine.

### Version 0.1.19

- **Performance Improvements**:
  - **InputManager Optimization**: Updated the `InputManager:handleInput()` method for improved performance. The new implementation reduces redundancy and streamlines the process of handling button states and hold actions.

- **Bug Fixes**:
  - **Sprite Management**: Fixed issues with adding and removing sprites, ensuring that sprite management is correctly set up and implemented.
  - **Animation Handling**: Resolved a bug where `RoxyAnimations` continued to run even after switching scenes. Animations now properly stop during scene transitions.

- **New Features**:
  - **Reverse Method**: Added a `reverse()` method to `RoxySprite`, providing additional control over sprite animations and behaviors.

These updates enhance the performance and reliability of the Roxy Engine, ensuring smoother sprite management and more robust animation handling. The new `reverse()` method offers greater flexibility in controlling sprite behaviors.

### Version 0.1.18

- **Method Chaining in RoxySprite**:
  - **Enhanced Chaining Support**: Added method chaining to `RoxySprite`, allowing multiple method calls in a single statement.
  - **New Methods**: Introduced `RoxySprite:addAnimation()` and `RoxySprite:setAnimation()` methods to support chaining, enabling more fluid and readable sprite setup.

- **Built-in Sprite Methods**:
  - **Method Integration**: Integrated Playdate SDK methods into `RoxySprite` to support chaining:
	- `:setZIndex(zIndex)`
	- `:setSize(width, height)`
	- `:moveTo(x, y)`

- **Animation Default State**:
  - **Paused by Default**: Updated `RoxySprite` to default animations to a paused state. Animations now require an explicit call to `:play()` to start, providing better control and preventing unintended playback during setup.
  
  - **RoxyMenu Parameter Reorder**: 
  - **Improved Usability**: Reordered parameters in `RoxyMenu:addItem` from `(nameOrKey, clickHandler, position, displayName, editable)` to `(nameOrKey, clickHandler, displayName, position, editable)`. This change prioritizes the `displayName` over manual position control, making it easier to add items without specifying their order.

These updates enhance the usability, flexibility, and control of the Roxy Engine, making it easier to manage and customize sprites and menus within your game. The method chaining improvements lead to cleaner and more concise code, while the default paused state for animations ensures more predictable behavior.

### Version 0.1.17

- **Singleton Approach for Managers**: Refactored all Roxy managers to use the Singleton design pattern for better consistency and easier access throughout the project. This change affects `ConfigurationManager`, `SequenceManager`, `InputManager`, `SceneManager`, and `TransitionManager`.

- **Renamed Method in RoxySequence**: Updated the method `get()` to `getValue()` for better clarity and to align with naming conventions.

- **Enhanced Documentation**: Improved comments and documentation within `RoxySequence` to provide more detailed explanations and to enhance code readability.

These changes streamline the management of game components, improve code clarity, and ensure that the Roxy game engine's architecture is more robust and maintainable.

### Version 0.1.16

- **RoxySequence Integration**:
  - **New Class**: Introduced `RoxySequence` to replace the third-party Nic Magnier Sequence library.
  - **Singleton Manager**: Implemented `SequenceManager` as a singleton to handle the management of running sequences.
  - **OOP Approach**: Refactored the sequence functionality to an object-oriented approach, encapsulating sequence logic within the `RoxySequence` class.
  - **Timing Management**: Moved delta time calculations to `SequenceManager` to streamline the main update loop in the `Roxy` class.
  - **Callback Enhancements**: Added clear callback handling within sequences, providing better structure and readability.
  - **Easing Functionality**: Ensured comprehensive easing functionality, including support for various easing types and mirrored (yoyo) effects.

These changes improve the flexibility, maintainability, and performance of the sequence handling in the Roxy Engine, making it easier to integrate and manage animation sequences.

### Version 0.1.15

- **RoxyUtilities and RoxyMath Refactor**:
  - **RoxyMath**:
	- Separated math utility functions into their own file `RoxyMath.lua`.
	- Functions include `truncateDecimal`, `round`, `roundDown`, `roundUp`, `hypot`, `clamp`, `lerp`, and `map`.
	- Ensured consistency and correctness of math functions.
  - **RoxyUtilities**:
	- Organized utility functions into subsections for better structure and readability.
	- Subsections include `Utilities.Tables`, `Utilities.JSON`, and `Utilities.Graphics`.
	- Added and improved comments for clarity and maintainability.
	- Refactored utility functions to follow best practices for global variables.

These changes enhance the modularity and readability of utility functions, making them easier to manage and use across the project. The improved structure and comments also aid in better understanding and maintaining the codebase.

### Version 0.1.14

- **Naming Convention Update**: Updated naming conventions to refer to animations as "animations" instead of "states" in the context of `RoxySprite`.
  - Changed all references from "state" to "animation" for consistency and clarity.
  - Updated method names such as `addState` to `addAnimation` and `setState` to `setAnimation`.

- **State Naming Convention**: Changed the `somethingState` naming convention to `_isSomething`.
  - For example, `pauseState` is now `_isPaused` to avoid conflicts and ensure clarity.

- **Removed `nextContinuity` from `RoxyAnimation:addAnimation`**:
  - `nextContinuity` parameter was removed from the `addAnimation` method as it is only needed in `setAnimation`.

- **Refactored `RoxyAnimation`**:
  - Ensured `nextContinuity` is handled correctly in `setAnimation` to manage seamless transitions between animations.

- **Comment and Documentation Enhancement**:
  - Improved comments and documentation for better readability and understanding.
  - Enhanced warning and error messages to be more informative.

These updates enhance the consistency and readability of the animation handling in the Roxy Engine, making it more intuitive for developers to work with animated sprites. The refactor also simplifies the management of animation states and transitions.

### Version 0.1.13

- **InputManager Enhancements**: 
  - **New Methods**: Added method for getting handlers (`getHandler`).
  - **Comment Improvements**: Enhanced comments throughout the `InputManager` for better readability and maintenance.

These updates improve the robustness, flexibility, and clarity of the input handling within the Roxy Engine, providing a more comprehensive and user-friendly experience.

### Version 0.1.12

- **Refactor and Code Clean-Up**:
  - **TransitionManager**:
	- Moved `getCurrentTransitionActive()` and `getCaptureScreenshotsDuringTransition()` methods from `TransitionManager` to `RoxyTransition` to streamline transition handling and improve code organization.
  - **RoxyScene**:
	- Confirmed that methods for resetting the draw offset (`resetDrawOffset`) and clearing graphics (`clearGraphics`) should remain in `RoxyScene` for better encapsulation of scene-specific behavior.
  - **Roxy**:
	- Updated `setupGameLoop` method to clarify its purpose of setting `Roxy:update()` as the main update loop for the game.
  - **Text**:
	- Updated `Text.draw` method to cache and restore the current font using `<const>`, ensuring immutability and consistency with color handling practices.
  - **General Improvements**:
	- Added `<const>` to cache values (e.g., colors and fonts) where appropriate to ensure immutability and enhance code clarity and safety.

These updates improve code maintainability, readability, and robustness by ensuring consistent practices for handling temporary changes and restoring previous states in various components.

### Version 0.1.11

- **Class Renaming**: Updated class names to align with Roxy Engine conventions for better consistency and clarity.
  - **RoxyScene**: Renamed `BaseScene` to `RoxyScene`.
  - **RoxyTransition**: Renamed `BaseTransition` to `RoxyTransition`.

- **Transition Classes Refactor**: Introduced intermediate transition classes to enhance code organization and maintainability.
  - **Intermediate Classes**: Created `RoxyCutTransition`, `RoxyCoverTransition`, `RoxyImagetableTransition`, and `RoxyMixTransition`.
  - **Specific Transition Classes**: Updated specific transition classes to extend the appropriate intermediate classes.
	- **Cut**: Now extends `RoxyCutTransition`.
	- **FadeToBlack** and **FadeToWhite**: Now extend `RoxyCoverTransition`.
	- **CrossDissolve**: Now extends `RoxyMixTransition`.
	- **Imagetable**: Now extends `RoxyImagetableTransition`.

- **Comments and Documentation**: Improved comments and documentation for transition classes to enhance readability and ease of understanding.
  - Added detailed comments to each class and method to clarify functionality and usage.

These changes improve the structure and readability of the transition classes, making the codebase easier to maintain and extend. The updated naming conventions ensure consistency with the Roxy Engine, and the improved comments provide better guidance for future development.

### Version 0.1.10

- **Lifecycle Method Refactor**: Updated the scene lifecycle methods to enhance clarity and maintainability.
  - **BaseScene**: Introduced `load`, `enter`, `exit`, and `cleanup` methods to replace `start`, `stop`, and `unload`.
  - **TransitionManager**: Adjusted transition logic to use the new lifecycle methods (`load`, `enter`, `exit`, `cleanup`).
  - **SceneManager**: Ensured `setCurrentScene` correctly validates scenes against the new lifecycle methods. Improved comments for better readability.
  - **Example Scenes**: Updated `MainMenu` and `StaticSpriteScene` to implement the new lifecycle methods. Enhanced comments for clarity.

- **Scene Cleanup**: Removed all previous test scenes, retaining only the `MainMenu` and `StaticSpriteScene`. Updated the main menu to reflect these changes.

These changes streamline the scene management process, improve code clarity, ensure smooth transitions between scenes, and simplify the project by focusing on the main menu and static sprite scene.

### Version 0.1.9
- **Toast/Tool Tip Draw Offset Handling**: Fixed a bug where the toast/tool tip in RoxyPopup did not ignore the draw offset. Added `self.toast:setIgnoresDrawOffset(true)` to ensure consistent behavior in popup use cases.

### Version 0.1.8
- **FPS Display Toggle**: Added a configuration option to toggle the FPS display. Set `showFPS` in the configuration to `true` to display the FPS counter.
- **FPS Positioning**: Added a configuration option to specify the position of the FPS display. Use `fpsPosition` with values `topLeft`, `topRight`, `bottomLeft`, or `bottomRight`.

### Version 0.1.7
- **Parameter Name Updates**: Updated parameter names for `math.clamp()` to be clearer.
- **Scene Transition Enhancements**: Improved scene transition handling by adding methods for resetting draw offsets and clearing graphics, ensuring proper scene cleanup and reset during transitions.
- **RoxyPopup Draw Offset Handling**: Added `self:setIgnoresDrawOffset(true)` to `RoxyPopup` to ensure it ignores draw offsets for consistent rendering.

### Version 0.1.6
- **Additional Math Functions**: Added `math.round`, `math.roundUP`, and `math.roundDown` to the Utilities math functions.
- **New Math Function**: Added `math.hypot` to calculate the hypotenuse using the Pythagorean theorem.

### Version 0.1.5
- **Minor Code Cleanup**: Added getters and setters for several flags. Renamed `paused` to `isPaused` to ensure consistency with the rest of the codebase.

### Version 0.1.4
- **RoxyMenu Edited Items Bold**: Edited items in RoxyMenu are now displayed in bold.
- **"Save Changes and Close" Popup Menu Item**: Added a new "Save Changes and Close" menu item to the popup menus for easier user interaction. This save item only appears if there are editable items in the menu.
- **Editable Menu Item Cancel and Accept UI**: Implemented a consistent UI for canceling and accepting popup menu item changes. A toast message appears when editing an item as a player affordance.

### Version 0.1.3
- **RoxyMenu Design Simplification**: Simplified the design of RoxyMenu to support only a filled selection box. The option to supply a stroke width for an outlined design is now reserved for the editing mode UI.
- **Bug Fix - Menu Colors**: Fixed a bug where loading a disabled menu would display incorrect colors for the selected item on the first load. The colors are now correct on the initial load.
- **Font Loading Issue Resolved**: Fixed the broken `SYSTEM_FONT_DISABLED` font issue. The custom font loading process has been updated and improved.
- **Disabled State for Popup**: Updated the disabled state for popups. The disabled state now appears as the default state but with no items selected.

### Version 0.1.2
- **System Menu Transition Update**: Removed the custom transition override for the system menu link to the game menu. The system menu now uses the default transition for a more consistent user experience.
- **RoxySprite Enhancement**: Added the ability for RoxySprite to accept an existing RoxyAnimation, improving flexibility and ease of use.

### Version 0.1.1
- Initial release of the Roxy game engine, including configuration management, basic scene management, sprite handling, and input processing.

### Version 0.1.0
- Created the foundation for the game engine, with core architecture and basic functionality.
