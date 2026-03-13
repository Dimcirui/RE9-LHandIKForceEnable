# Force Left Hand IK Enable

**Version: 2.2**  
**Authors: Dimcirui, Motokajuu**

A REFramework-based script for Resident Evil 9 (RE9) that force-enables left-hand Inverse Kinematics (IK). This script is designed to correct hand offset issues—where the left hand deviates from its intended position—commonly encountered after character skeleton modifications or when using certain mods.

## ✨ Features

-   **Layer-Based Detection**: Automatically detects animation states (layers, banks, and motion IDs) to decide when IK should be active.
-   **Intelligent Distance Verification**: 
    -   **Grace Mode**: Uses proximity checks (L-Hand to R-Hand distance) to handle conflicting animation groups.
    -   **Leon Mode**: Features "Distance Sustain," maintaining IK engagement even when animation conditions aren't perfectly matched, as long as the hands remain close.
-   **Per-Character Configuration**: Flexible JSON-based settings for different characters (Leon, Grace, etc.).
-   **Grace Period Support**: Includes an optional "Distance Grace" period to prevent jittery IK disengagement.
-   **Real-time Debug UI**: Built-in ImGui overlay for monitoring status, matched conditions, and measuring real-time hand distances.
-   **Optimized Performance**: Uses caching for game objects, transforms, and joints to ensure minimal CPU overhead.

## 🛠 Installation

1.  **Requirements**: Ensure you have [REFramework](https://www.nexusmods.com/residentevilrequiem/mods/13) installed.
2.  **Manual Install**:
    -   Download the mod.
    -   Extract the `reframework` folder into your game's root directory (where `re9.exe` is located).
3.  **Mod Manager**: Alternatively, install via [Fluffy Mod Manager](https://www.fluffyquack.com/).

## ⚙️ Configuration

Open the REFramework menu (**Insert** key by default) and look for **"IK LHand Fix"** under the Script UI.

-   **Global Enabled**: Toggle the entire script on/off.
-   **Debug Mode**: Shows detailed animation layer data and current distance measurements.
-   **Character Settings**:
    -   **Enabled**: Toggle individual character logic.
    -   **Distance Threshold**: The maximum distance (in meters) between hands to consider them "clasping."
    -   **Reload Config**: Refresh settings from the JSON files.

### Advanced Configuration (JSON)
Custom configurations are stored in `reframework/data/LHandIKFix/hand_ik_fix_<CharacterName>.json`. 

Example structure:
```json
{
    "char_enabled": true,
    "distance_threshold": 0.07,
    "distance_interval": 0.1,
    "distance_sustain": true,
    "conditions": [...],
    "kill_conditions": [...]
}
```

## 🤝 Credits

-   **Dimcirui**: Original author and logic design.
-   **Motokajuu**: Contributor.
-   Special thanks to the REFramework community for the essential tools.

---
*For issues or support, visit the [Nexus Mods profile](https://www.nexusmods.com/profile/Dimcirui/mods).*
