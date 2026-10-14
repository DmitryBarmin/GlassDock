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

Options: `--self-test` validates recency/cache policy; `--diagnostics` prints permission and display metadata without titles or screenshots; `--demo` displays synthetic previews for 18 seconds; `--background` starts quietly without opening Settings when permissions are already granted. Missing permissions still show onboarding. Demo also lives in the status-menu item. No external dependencies, telemetry, or screenshots saved to disk.

macOS permissions are granted manually. Use the menu's access screen and its buttons to initiate standard Accessibility/Screen Recording requests and open the corresponding System Settings. Restart after enabling permissions. Never reset TCC or edit its database.

To start at login, add `/Applications/GlassDock.app` in System Settings → General → Login Items. For a quiet launch via a local launcher, use `open -g /Applications/GlassDock.app --args --background`. Size, opacity, and corner preferences are local macOS defaults; thumbnails are never saved or uploaded.

Minimized-window limitations: ScreenCaptureKit pauses/minimized windows may lack fresh content. GlassDock retains the last good thumbnail in memory, warming up to 96 visible windows every three seconds and focused/new windows on AX events. A window minimized before its first successful capture (including before startup), an evicted thumbnail beyond the 96-window cache, or a protected window will have no preview until reopened/captured. Quit DockDoor manually when ready to use GlassDock, otherwise both utilities can react to the same hover. Window matching uses public AX geometry/title and ScreenCaptureKit IDs; ambiguous/unmatchable windows are omitted to avoid focusing the wrong window.
