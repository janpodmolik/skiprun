# skiprun

Build, install and launch a [Skip](https://skip.dev) app on the iOS simulator,
the Android emulator or a physical Android phone, from one command that knows
your schemes, configurations, flavors and devices.

`skip app launch` builds with a hard-coded scheme and only `debug`/`release`;
a project with an Xcode scheme per backend (say `MyApp Staging` with
configuration `Debug-Staging`) and matching Gradle flavors cannot use it.
`skiprun` reads the schemes and configurations from the project, maps an
environment name onto both platforms, remembers the choice, picks the device
for you, and keeps the small things right that cost an afternoon each: it
installs only an APK from `outputs/` (an intermediate one fails with
`INSTALL_FAILED_TEST_ONLY`), pairs a phone over Wi-Fi with IPv4 (adb's own
`.local` resolution picks link-local IPv6 and dies), and stops the gradle
daemons together with the emulator.

## Install

```bash
brew install --HEAD janpodmolik/tap/skiprun   # current main, until the first tagged release
brew install janpodmolik/tap/skiprun          # tagged release (from v0.1.0 on)
```

Or from a clone:

```bash
git clone https://github.com/janpodmolik/skiprun ~/Developer/skiprun
export PATH="$HOME/Developer/skiprun/bin:$PATH"   # in ~/.zshrc
```

Needs macOS with Xcode (`xcodebuild`, `xcrun simctl`, `xed`), the Skip CLI
(`brew install skiptools/skip/skip`), the Android SDK with `platform-tools`
and `emulator` (`$ANDROID_HOME`, else `~/Library/Android/sdk`) and `python3`
(ships with the Xcode command line tools). `fzf` is optional: with it, every
pick is a fuzzy list; without it, a numbered menu.

## Use

Run it from anywhere inside a Skip project, the directory tree holding
`Skip.env`:

```bash
skiprun ios                 # simulator
skiprun android             # emulator
skiprun android --device    # the phone on USB or Wi-Fi
skiprun android --logs      # ... and stream the app's logcat
skiprun ios --env production
skiprun stop                # shut both platforms down when done
```

`-C <dir>` runs against another project, `skiprun <command> --help` explains
each command.

With more than one git worktree (say `main` and a prototype branch), `ios`
and `android` first ask which one to build; the current worktree is listed
first, so Enter keeps it. `-w <query>` names the branch and skips the ask
(`skiprun -w proto android --device`), a bare `-w` forces it. A worktree
without its own `.skiprun` builds with the values of the one you started in.

### Commands

| Command | What it does |
| --- | --- |
| `ios [--env E] [--scheme S] [--configuration C] [--simulator NAME] [-n]` | `xcodebuild` of `Project.xcworkspace` (else the first workspace, else the `.xcodeproj`) for the simulator SDK, then install and launch on the booted simulator. With none booted it boots `ios.simulator`, else the first iPhone of the runtime matching the selected Xcode's SDK. |
| `android [--env E] [--avd NAME] [--logs] [-n]` | Starts the emulator when none runs (`android.avd`, else the first AVD), `skip gradle -p Android assemble<E>Debug`, installs the APK from `.build/Android/*/outputs/apk/<e>/debug/`, launches the app. `--logs` streams the filtered logcat; Ctrl+C stops streaming, the app keeps running. |
| `android --device [S] [--env E] [--logs] [-n]` | The same on a physical phone: the given serial, else a Wi-Fi `ip:port` serial first (builds keep working after the cable comes out), then USB. Never touches the emulator. |
| `android connect` | Reconnect the phone over Wi-Fi: the locked endpoint, then mDNS discovery, then a typed `IP:PORT`. |
| `android pair` / `android qr` | First pairing on a network, with the pairing code or with a QR code rendered in the terminal (no IDE needed). |
| `android lock` | `adb tcpip 5555` over the live connection: a fixed port that survives screen-off until the phone reboots. Android 14+ re-randomizes the wireless-debug port after every doze. |
| `android usb` | Authorize over a cable once, then switch that device to Wi-Fi. Needs neither pairing nor mDNS. |
| `android status` | Which layer is broken: pairing record, locked port, live mDNS advertisement, adb connection. |
| `logs [--serial S]` | Attach the filtered logcat (Skip, crashes, the app id) to the running app. |
| `shot ios [--device D]` / `shot android [--serial S]` | Screenshot onto the clipboard and into `$TMPDIR/skiprun-shots` (newest 20 kept). iOS: the booted simulator (`simctl`) or the connected iPhone (`devicectl`), a pick when both are there. Android: the emulator or the phone over adb. The file name says where it came from: `ios-simulator-iPhone-17-Pro-…`, `ios-device-<name>-…`, `android-<serial>-…`. Needs nothing from the app. |
| `stop [ios|android]` | Shut down every simulator / kill the emulator and stop the gradle daemons. Default: both. No command runs it for you: two platforms side by side is a legitimate state. |
| `xcode [query]` | Pick a worktree of the current git repository (fzf, or a menu) and open its `Project.xcworkspace` with `xed`. One worktree opens at once; a query matching one branch opens it directly. The same pick `ios` and `android` use before a build. |
| `config [--reset]` | Print the files in effect and what skiprun resolved. `--reset` forgets the remembered environment, scheme and configuration. |

`-n` / `--dry-run` prints the build, install and launch commands instead of
running them.

### Environments

`--env <name>` replaces per-project environment variables. The name means:

- Android: Gradle task `assemble<Name>Debug`, APK under
  `outputs/apk/<name>/debug/`.
- iOS: configuration `Debug-<Name>` (case-insensitive) and the scheme whose
  name contains `<name>`. When no scheme does, the schemes that name no
  environment at all are the candidates: with schemes `MyApp` and
  `MyApp Staging`, `--env production` builds `MyApp` with
  `Debug-Production`.

Without `--env`: the `env` key of the config, else the project's only
environment, else a one-time pick that is remembered. A project without
environments (schemes `MyApp`, configurations `Debug`/`Release`) builds
`Debug` and `assembleDebug` with no configuration at all.

Known environment names are the Gradle flavors
(`productFlavors { create("…") }` in `Android/app/build.gradle.kts`) and the
`Debug-*` configurations of the Xcode project. `xcodebuild -list` takes some
fifteen seconds, which is why the resolved scheme and configuration are
remembered; `--scheme` and `--configuration` override and update that
memory.

### Config files

Two files of `key = value` lines (`#` comments), the project file winning:

| File | Purpose |
| --- | --- |
| `~/.config/skiprun/config` | Machine preferences: which simulator, which AVD. |
| `<project>/.skiprun` | Per project: the environment and the remembered scheme and configuration; add it to `.gitignore`. |

| Key | Meaning |
| --- | --- |
| `env` | Default `--env`. |
| `ios.simulator` | Simulator to boot when none is (name or UDID). |
| `ios.scheme[.<env>]`, `ios.configuration[.<env>]` | What `ios` builds for the environment (remembered automatically). |
| `android.avd` | AVD to start when no emulator runs. |
| `android.serial` | Phone to prefer for `--device`, `logs` and `shot`. |

Example `~/.config/skiprun/config`:

```
ios.simulator = iPhone 17 Pro
android.avd = pixel_8
```

Nothing else is stored. `device lock` keeps its endpoint in
`~/.local/state/skiprun/locked-endpoint`.

### Shell aliases

The commands are meant to be aliased; a set that has worked for a while:

```zsh
alias sri='skiprun ios'
alias sra='skiprun android'
alias srad='skiprun android --device'
alias sradp='skiprun android --device --env production'
alias srad-wifi='skiprun android connect'
alias srad-pair='skiprun android pair'
alias srad-qr='skiprun android qr'
alias srad-lock='skiprun android lock'
alias srad-usb='skiprun android usb'
alias srad-status='skiprun android status'
alias sr='sri && sra'
alias ishot='skiprun shot ios'
alias ashot='skiprun shot android'
alias srx='skiprun xcode'
alias ska='skiprun stop android'
alias ski='skiprun stop ios'
alias sk='skiprun stop'
```

## Wi-Fi debugging, in short

Once per network: `skiprun android qr` (or `pair`). Once per phone boot:
`skiprun android connect`, then `skiprun android lock`. Then
`skiprun android --device` builds over Wi-Fi, and Android Studio sees the
same device. When something is off, `skiprun android status` names the layer.

Discovery uses macOS `dns-sd`, not `adb mdns services` (adb's backend misses
live advertisements and serves dead cached ports), and probes every candidate
port before returning it. `adb pair` and `adb connect` exit 0 on failure, so
their output text is what gets checked, and a refused port is re-resolved
rather than reported against a number that no longer exists.

## Layout

```
bin/skiprun          dispatcher: global options, sources lib/*.zsh
lib/common.zsh       output, picker, project root, Skip.env, config, environments, worktrees
lib/ios.zsh          scheme/configuration discovery, simulator, build, install, launch
lib/android.zsh      emulator or phone: APK build/install/launch, logcat
lib/wifi.zsh         the Wi-Fi helpers (android connect | pair | qr | lock | usb | status)
lib/xcode.zsh        worktree picker
lib/shot.zsh         screenshots
lib/stop.zsh         shutdown
lib/config.zsh       config command
libexec/simulator.py picks a simulator from `simctl list -j`
libexec/iphones.py   connected iPhones from `devicectl list devices`
libexec/adb-qr-pair.py renders the pairing QR (stdlib only)
Formula/skiprun.rb   Homebrew formula for a tap
```

## Open questions for upstreaming to skiptools

Things to settle before offering this to `skip` itself (as `skip app launch`
options or a `skip run` command):

1. Scheme and configuration resolution: should `skip app launch` take
   `--scheme`, `--configuration` and an `--env` that maps onto the Gradle
   flavor, or should Skip read an `environments` table from `Skip.env`?
2. Where does a remembered pick belong: a `.skiprun`-style project file, or
   `Skip.env` comments that Skip already owns?
3. Device selection: `skip devices` lists devices; should launch accept a
   `--device <name|udid|serial>` on both platforms and default to the booted
   simulator / running emulator / the only phone the way skiprun does?
4. Install source: Skip's Gradle plugin knows the real APK path; the
   `outputs/`-only rule exists because the shell cannot. An API that prints
   the built artifact path would remove the guesswork.
5. Wi-Fi pairing: is the mDNS/IPv4 workaround something Skip wants to carry,
   or should it stay a separate tool that `skip` can point to?
6. iOS physical devices (`devicectl`) are not covered here; Skip's launch
   already lists them. A combined tool would need signing options.
7. Logs and screenshots: a cross-platform `skip logs` (logcat filter on Android, `log stream`
   with the bundle id predicate on the simulator) would complete the loop.
8. Shell: this is zsh; Skip's CLI is Swift. A port would be a rewrite, so the
   behaviours above (not the code) are the contribution.
