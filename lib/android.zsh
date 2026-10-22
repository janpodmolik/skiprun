# Android: emulator, APK build, install (from outputs/ only), launch, logcat.

help_android() {
  cat <<USAGE
Usage: skiprun android [--env <name>] [--avd <name>] [--logs] [-n|--dry-run]
       skiprun android --device [<serial>] [--env <name>] [--logs] [-n|--dry-run]
       skiprun android connect | pair | qr | lock | usb | status

Builds assemble<Env>Debug with \`skip gradle\`, installs the APK found under
.build/Android/*/outputs/ (never an intermediate one) and launches the app.
Without --device on the emulator, started when none runs (android.avd, else
the first AVD). With --device on the phone: the given serial, else a Wi-Fi
ip:port serial first, then USB; the emulator is never touched.
--logs streams the app's filtered logcat (Ctrl+C stops streaming, the app
keeps running); \`skiprun logs\` attaches later.

Getting the phone there over Wi-Fi (phone and Mac on the same Wi-Fi):
  connect   reconnect: the locked endpoint, then mDNS, then a typed IP:PORT
  pair      first time on a network: pairing code from Developer options →
            Wireless debugging → "Pair device with pairing code"
  qr        the same with a QR code rendered in the terminal (no IDE needed)
  lock      pin adbd to port 5555 so screen-off cannot drop it (until reboot)
  usb       authorize over a cable once, then switch that device to Wi-Fi
  status    which layer is broken: pairing, locked port, mDNS, adb connection

Discovery uses macOS dns-sd and resolves hosts to IPv4: adb takes the first
getaddrinfo answer, link-local IPv6 on a dual-stack phone, and dies with
"No route to host" against a port that is open.
USAGE
}

help_logs() {
  cat <<USAGE
Usage: skiprun logs [--serial <serial>]

Streams the running app's logcat, filtered to Skip, crashes and the app id.
Targets the only connected device, \$ANDROID_SERIAL, or a pick among several.
USAGE
}

android_parse_run_options() {
  OPT_ENV="" OPT_AVD="" OPT_SERIAL="" OPT_LOGS=0 OPT_DEVICE=0
  while (( $# )); do
    case $1 in
      --env) OPT_ENV=$2; shift 2 ;;
      --avd) OPT_AVD=$2; shift 2 ;;
      --device) OPT_DEVICE=1; shift
               [[ -n $1 && $1 != -* ]] && { OPT_SERIAL=$1; shift } ;;
      --logs) OPT_LOGS=1; shift ;;
      -n|--dry-run) SKIPRUN_DRY_RUN=1; shift ;;
      -h|--help) help_android; exit 0 ;;
      *) die "android: unknown argument '$1' (see skiprun android --help)" ;;
    esac
  done
}

# Serials in state `device`, one per line.
adb_online_serials() { "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }' }

# Target the emulator by its exact serial, never `adb -e`: a phone connected over
# USB, Wi-Fi or mDNS counts as emulator-like and trips "more than one emulator".
android_target_emulator() {
  if ! "$ADB" devices | grep -q '^emulator-.*device$'; then
    local avd=${OPT_AVD:-$(cfg android.avd)}
    if [[ -z $avd ]]; then
      local -a avds=( ${(f)"$("$EMULATOR" -list-avds 2>/dev/null)"} )
      (( ${#avds} )) || die "no AVD found (create one in Android Studio → Device Manager)"
      avd=$avds[1]
    fi
    say "Starting emulator $avd (in background, log: ${${TMPDIR:-/tmp}%/}/skiprun-emulator.log)..."
    if (( ${SKIPRUN_DRY_RUN:-0} )); then
      print -r -- "+ $EMULATOR -avd $avd &"
      EMU_SERIAL="emulator-<pending>"
      return 0
    fi
    nohup "$EMULATOR" -avd "$avd" >"${${TMPDIR:-/tmp}%/}/skiprun-emulator.log" 2>&1 &
  fi
  # A fresh emulator sits in `offline` first; wait for one that is fully `device`.
  say "Waiting for the emulator..."
  EMU_SERIAL=""
  until [[ -n $EMU_SERIAL ]]; do
    EMU_SERIAL=$("$ADB" devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')
    [[ -z $EMU_SERIAL ]] && sleep 2
  done
  until [[ $("$ADB" -s "$EMU_SERIAL" shell -n getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; do sleep 2; done
  ok "Emulator booted: $EMU_SERIAL"
}

# A physical phone: online, not the emulator, not the mDNS `_tcp` duplicate; a Wi-Fi
# ip:port serial first so builds keep working after the cable comes out.
android_target_phone() {
  if [[ -n $OPT_SERIAL ]]; then PHONE_SERIAL=$OPT_SERIAL; return 0; fi
  local candidates; candidates=$(adb_online_serials | grep -v '^emulator-' | grep -v '_tcp')
  PHONE_SERIAL=$(print -r -- "$candidates" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$' | head -n 1)
  [[ -n $PHONE_SERIAL ]] || PHONE_SERIAL=$(print -r -- "$candidates" | head -n 1)
  if [[ -z $PHONE_SERIAL ]]; then
    if "$ADB" devices | grep -v '^emulator-' | grep -qw unauthorized; then
      die "the phone is 'unauthorized': unlock it and tap 'Allow USB debugging' (check 'Always')"
    fi
    print -r -- "❌ No phone found. Check: a DATA cable, USB debugging ON, 'adb devices' lists it." >&2
    print -r -- "   Wi-Fi: skiprun android pair (first time), then skiprun android connect." >&2
    exit 1
  fi
}

# android_build_install_launch <serial> — the shared tail of `android` and `device`.
android_build_install_launch() {
  local serial=$1
  local task="assemble${(C)ENV}Debug"
  say "Building APK (${ENV:-debug}: $task)..."
  run skip gradle -p Android "$task" || die "Build failed"
  local -a apks=( "$PROJECT_ROOT"/.build/Android/*/outputs/apk/${ENV:+$ENV/}debug/*-debug.apk(N) )
  if (( ${#apks} == 0 )); then
    (( ${SKIPRUN_DRY_RUN:-0} )) && { print -r -- "+ (would install .build/Android/*/outputs/apk/${ENV:+$ENV/}debug/*-debug.apk on $serial)"; return 0 }
    die "no APK under .build/Android/*/outputs/apk/${ENV:+$ENV/}debug"
  fi
  local apk=$apks[1] pkg; pkg=$(android_app_id)
  say "Installing ${apk#$PROJECT_ROOT/} on $serial"
  run "$ADB" -s "$serial" install -r "$apk" || die "Install failed"
  if (( ${SKIPRUN_DRY_RUN:-0} )); then
    print -r -- "+ $ADB -s $serial shell am start -n <launcher activity of $pkg>"
    return 0
  fi
  local activity; activity=$("$ADB" -s "$serial" shell -n cmd package resolve-activity --brief "$pkg" 2>/dev/null | tail -n 1 | tr -d '\r')
  [[ -n $activity && $activity != *"No activity found"* ]] || die "no launcher activity for $pkg on $serial"
  run "$ADB" -s "$serial" logcat -c 2>/dev/null
  say "Launching $activity"
  run "$ADB" -s "$serial" shell am start -n "$activity"
  if (( OPT_LOGS )); then
    sleep 2
    android_stream_logs "$serial" "$pkg"
  else
    ok "Done (app running; skiprun logs streams its logcat)"
  fi
}

android_stream_logs() {
  local serial=$1 pkg=$2
  local pid; pid=$("$ADB" -s "$serial" shell -n pidof -s "$pkg" 2>/dev/null | tr -d '\r')
  if [[ -z $pid ]]; then
    warn "$pkg is not running on $serial (it may have crashed on start). Last crash:"
    "$ADB" -s "$serial" logcat -d 2>/dev/null | grep -iE "FATAL|AndroidRuntime|ClassNotFound|Caused by|$pkg" | tail -n 30
    return 1
  fi
  print -r -- "📜 Streaming logs of $pkg (Ctrl+C stops streaming — the app keeps running)"
  print -r -- "────────────────────────────────────────────────────"
  "$ADB" -s "$serial" logcat --pid="$pid" 2>/dev/null | grep --line-buffered -iE "skip\.|FATAL|AndroidRuntime|Exception|Caused by|$pkg"
}

cmd_android() {
  case $1 in
    connect|pair|qr|lock|usb|status)
      local sub=$1; shift
      [[ $1 == (-h|--help) ]] && { help_android; return 0 }
      (( $# == 0 )) || die "android $sub takes no arguments"
      android_tools
      "wifi_$sub"
      return ;;
  esac
  local OPT_ENV OPT_AVD OPT_SERIAL OPT_LOGS OPT_DEVICE EMU_SERIAL PHONE_SERIAL
  android_parse_run_options "$@"
  require_project
  choose_build_worktree
  android_tools
  pkill -f "$ADB logcat" 2>/dev/null
  resolve_env android
  if (( OPT_DEVICE )); then
    android_target_phone
    say "Target phone: $PHONE_SERIAL"
    android_build_install_launch "$PHONE_SERIAL"
  else
    android_target_emulator
    android_build_install_launch "$EMU_SERIAL"
  fi
}

# The device for logs and screenshots: --serial, $ANDROID_SERIAL, the only one online, else a pick.
android_pick_serial() {
  local want=${1:-$ANDROID_SERIAL}
  [[ -n $want ]] && { print -r -- "$want"; return 0 }
  local -a serials=( ${(f)"$(adb_online_serials)"} )
  case ${#serials} in
    0) die "no Android device online (adb devices)" ;;
    1) print -r -- "$serials[1]" ;;
    *) pick device "" "${serials[@]}" ;;
  esac
}

cmd_logs() {
  local serial=""
  while (( $# )); do
    case $1 in
      --serial) serial=$2; shift 2 ;;
      -h|--help) help_logs; return 0 ;;
      *) die "logs: unknown argument '$1' (see skiprun logs --help)" ;;
    esac
  done
  require_project
  android_tools
  serial=$(android_pick_serial "$serial") || exit 1
  android_stream_logs "$serial" "$(android_app_id)"
}
