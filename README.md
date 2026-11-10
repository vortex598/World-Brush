# World-Brush (Godot 4 Plugin)

 Meant for ease of use, and for hand painted worlds.
 
A terrain editor plugin for Godot 4 that uses the WMT (World Map Tile) system. It provides sculpting, painting, vertex coloring, object placement, and terrain management tools in a right-side "Terrain" tab.

## Credits
- Made by RaylenHook
- Using the Noggit Editor font for icons.

## What's included

- `addons/terrain_editor/` - the editor plugin (scripts, shaders, UI, assets)
- `wmt/` - the WMT terrain runtime (required dependency)
- `world/ & tileset/` - the default staring assets bundled in (folders are required, but not assets within)

## Installation

1. Copy these folders into your Godot project root:
   - `addons/terrain_editor/` → `your_project/addons/terrain_editor/`
   - `wmt/` → `your_project/wmt/`
   - `tileset/` → `your_project/tileset/`
   - `world/` → `your_project/world/`
   
   (info) The plugin expects the WMT runtime at `your_project/wmt/wmt.gd`.

2. Open your project in Godot 4.

3. Enable the plugin:
   - Go to **Project → Project Settings → Plugins**
   - Enable **Terrain Editor** (or the name shown from `plugin.cfg`)

4. A **Terrain** tab will appear in the editor. Select/create a WMT terrain node to start editing.

## Usage

1. **controls**: to find the controls, go to the terrain tab on the right and look at the bottom of the tab for a hotkeys button.
2. **adding assets**: drag your desired terrain textures in `your_project/tileset/`, and your desired 3D objects in `your_project/world/`.

### Understanding terrain textures

1. `texture-file-name`, for example "grass.png", this is the visible texture you will see on the terrain.
2. `texture-file-name_h`, for example "grass_h.png", this is the height texture it uses alpha (hence the textures that come packaged with) as the height/visibility when blending between textures
3. I purposely left out specular support, since it's hand painted style terrain.

### Understanding terrain

1. A terrain map in the scene is a `wmt node` (world map terrain node) which you can make from the godot node browser.
2. `.wmt` files, for example "island.wmt", is a whole terrain map, (not an individual tile)

## Notes

- The plugin folder contains example `tileset/` and `world/` folders, with basic assets inside both.
- For Texture painting: place all terrain textures in `your_project/tileset`. The plugin references this folder for texture browsing, painting and assigning.
- To use the object placing tool: place all 3D objects in `your_project/world`. This is where the plugin references 3D objects for the object browser and for placing objects.
- Undo history is kept in memory (up to 100 actions) and a lightweight metadata file is written to `user://wmt_undo_history.txt`. 
- This package was built from a working project setup; if you encounter missing resources or path issues, check that `your_project/addons/terrain_editor/` and `wmt/` are at the paths above.

## Requirements

- Godot 4.x (tested in a Godot 4 project environment)
