# No-Build Areas

## Description
This plugin allows server administrators to create custom-sized no-build areas in Team Fortress 2 maps. These areas prevent Engineers from building their structures in specific locations. Unlike the original plugin, this version enables completely custom-sized areas with an intuitive mouse-based creation system and height adjustment.

## Features
- Create no-build areas of any size and squared shape
- Adjust height using mouse controls for precise placement
- Visual preview during creation with dimensions display
- Set which buildings are allowed/disallowed (sentries, dispensers, teleporters)
- Team-specific restrictions (RED, BLU, or both)
- Save areas to database for persistence across map changes and server restarts
- Visualize all no-build areas on the map
- Delete areas that are no longer needed

## Installation
1. Upload all files to your SourceMod directory
2. Configure your database in `configs/databases.cfg`:
   ```
   "nobuildareas"
   {
       "driver"      "mysql" // or "sqlite"
       "host"        "your-database-host"
       "database"    "your-database-name"
       "user"        "your-username"
       "pass"        "your-password"
       //"port"      "3306" // Uncomment if needed
   }
   ```
3. Load the plugin: `sm plugins load nobuildareas` or restart your server

## Commands
- `sm_nobuild` - Opens the no-build areas management menu
- `sm_shownobuild` - Shows all no-build areas for 10 seconds
- `sm_cancelarea` - Cancels the current area creation process

## Usage Guide

### Creating No-Build Areas
1. Type `!nobuild` or `sm_nobuild` in chat
2. Select "Create no-build area" from the menu
3. **Area Creation Controls:**
   - **Point at a location** where you want to place a corner
   - **Single left-click** to lower the height
   - **Right-click** to raise the height
   - **Double-click** to set the point
4. Set both corners to define your area
5. Select which team(s) the restriction applies to
6. Choose which buildings to allow (if any)
7. Confirm creation

### Tips for Area Creation
- The visual preview shows exact dimensions in units
- Height adjustment is in increments of 8 units
- For areas in mid-air, first aim at a reference point then adjust height

### Managing No-Build Areas
- Use `!shownobuild` to visualize all existing areas
- Use the "Delete nearest no-build area" option to remove unwanted areas
- Areas persist through map changes and server restarts

## Credits
- Original plugin by HelpMe
- Custom implementation with improvements by ampere