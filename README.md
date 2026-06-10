# dB

**Volume control, app by app. Right from your menu bar.**

dB is a free, open-source macOS menu bar app that lets you set a separate
volume for every app — turn Chrome down without touching Spotify, mute system
sounds while a video call stays loud.

- Lives in the menu bar
- Free and open source (MIT) — no paywall, no subscription
- No kernel extensions, no virtual audio drivers
- macOS 14.4+

## How it works

dB uses the Core Audio **process tap** API introduced in macOS 14.4
(`AudioHardwareCreateProcessTap`). When you lower an app's volume, dB:

1. Creates a tap on that app's audio processes with
   `muteBehavior = .mutedWhenTapped`, which silences the app's direct output.
2. Creates a private aggregate device wrapping your default output device.
3. Renders the tapped audio back to the output device with your chosen gain.

At 100% no tap is active and audio flows completely untouched.

## Install

### Download (recommended)

1. Grab the latest **`dB-x.y.z.dmg`** from the
   [Releases page](../../releases/latest).
2. Open the DMG and drag **dB** into your **Applications** folder.
3. **First launch only:** right-click (or Control-click) **dB** in Applications
   and choose **Open**, then click **Open** again. This step is required because
   the app isn't notarized yet — after the first time, it opens normally.
4. Click the **dB** label in your menu bar.

### Build from source

Requires the Xcode command line tools:

```sh
git clone <this repo>
cd mac-volume-slider
./build.sh
open dist/dB.app
```

Optionally move `dist/dB.app` to `/Applications`.

### Cutting a release (maintainers)

Pushing a version tag builds the app and publishes a DMG to GitHub Releases
automatically via GitHub Actions:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## Permissions

The first time you lower an app's volume, macOS will ask for **System Audio
Recording** permission — this is what the process tap API requires. Grant it in
the prompt, or later under **System Settings → Privacy & Security → Screen &
System Audio Recording → System Audio Recording Only**. dB only routes audio to
your speakers with gain applied; nothing is recorded or stored.

## Usage

- Click the **dB** label in the menu bar to open the mixer.
- Apps appear when they hold an audio stream and stay listed for the session.
- Drag a slider to set that app's volume; click ↺ to reset to 100%.
- The ••• menu has Launch at Login and Quit.

Custom volumes are remembered per app across launches.

## Limitations

- Requires macOS 14.4 or later (the process tap API does not exist before that).
- Browser audio is grouped under the browser — all tabs share one OS-level
  audio stream, so per-tab volume isn't possible from an OS-level app.
- Apps that use exotic audio paths (e.g. some pro audio software with direct
  HAL access) may not be tappable.

## License

[MIT](LICENSE)
