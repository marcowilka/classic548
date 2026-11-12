# ClassicAFP DMG artwork

## What appears in the window

| Element | Source |
|---|---|
| Background (paper → teal gradient, arrow, captions) | Original (`generate_background.swift`) |
| App icon | Signed `ClassicAFP.app` |
| Applications icon | Drawn by **Finder** from the symlink to `/Applications` |

Caption: “Drag to Applications to install”  
Hint: “Then open ClassicAFP → enable File System Extensions”

## Regenerate

```bash
swift Scripts/dmg/generate_background.swift Scripts/dmg/background.png
```

`build-macos-dmg.sh` regenerates `background.png` automatically if it is missing.
