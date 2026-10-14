# GlassDock

Native macOS 26+ menu-bar utility. Hover the lower half of a running application's Dock icon for 80 milliseconds to see compact thumbnails in separate clear glass frames. Warm thumbnails appear immediately; fresh captures update afterwards. Click content to restore/focus its window. A translucent eye.slash marks minimized windows; the small corner x invokes that window's native close button, preserving unsaved-document prompts. Settings control thumbnail width (140–420 points), opacity (35–100%), and left/right close-button corner (right by default). The latest focused or minimized window appears first. Automatic sibling focus immediately after minimizing is treated as part of that minimize action.

Requirements: Apple Silicon Mac, macOS 26+, and Xcode 26 / matching Command Line Tools or newer (Swift 6, macOS 26 SDK). No external dependencies.

Clone this repository, then build without changing the installed app:

```sh
git clone https://github.com/DmitryBarmin/GlassDock.git GlassDock
cd GlassDock
./build.sh --build-only
```

The bundle is `build/GlassDock.app`. To build and install into `/Applications/GlassDock.app`, quit an older GlassDock instance and run `./build.sh`, then `open /Applications/GlassDock.app`. The install step refuses to overwrite a different bundle identifier. The downloadable ZIP contains the app bundle; move it into Applications before opening it. Builds are locally ad hoc signed, without Apple notarization.

Options: `--self-test` validates recency/cache/scheduling policy; `--diagnostics` prints permission and display metadata without titles or screenshots; `--demo` displays synthetic previews for 18 seconds; `--background` starts quietly without opening Settings when permissions are already granted. `--metrics` prints cumulative inventory/capture/Dock-query counts and cache byte usage to stderr every 15 seconds while running, without window titles or content. Missing permissions still show onboarding. Demo also lives in the status-menu item. No external dependencies, telemetry, or screenshots saved to disk.

macOS permissions are granted manually. Use the menu's access screen and its buttons to initiate standard Accessibility/Screen Recording requests and open the corresponding System Settings. Restart after enabling permissions. Never reset TCC or edit its database.

To start at login, add `/Applications/GlassDock.app` in System Settings → General → Login Items. For a quiet launch via a local launcher, use `open -g /Applications/GlassDock.app --args --background`. Size, opacity, and corner preferences are local macOS defaults; thumbnails are never saved or uploaded.

Thumbnails are warmed once at startup and for newly discovered windows. Only the observed focused window of the foreground application gets a background snapshot about every three seconds, keeping its last visible contents useful when minimized. This skips hidden/minimized windows, sleep and active capture work; it performs no all-window inventory sweep. Fresh captures run while their application's preview is visible, at most once per window every 700 ms. Pointer tracking uses coordinate events; the 40 ms hover timer runs near the Dock or visible previews. Inventory requests are coalesced, and capture completion paints without scheduling another capture.

Minimized-window limitations: ScreenCaptureKit pauses/minimized windows may lack fresh content. GlassDock retains the last successfully captured thumbnail in memory; edits made after that capture can be absent. The cache is bounded to 96 windows and 24 MiB of image data, preserving recent focused/minimized windows first. A window minimized before its first successful capture (including before startup), an evicted thumbnail, or a protected window will have no preview until reopened/captured. Quit DockDoor manually when ready to use GlassDock, otherwise both utilities can react to the same hover. Window matching uses public AX geometry/title and ScreenCaptureKit IDs; ambiguous/unmatchable windows are omitted to avoid focusing the wrong window.
