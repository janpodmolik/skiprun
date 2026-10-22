# Shut down a platform's runtime when it sits idle: the emulator and gradle daemons eat CPU and RAM.

help_stop() {
  cat <<USAGE
Usage: skiprun stop [ios|android]

ios      shuts down every booted simulator
android  kills the emulator and stops the gradle daemons
Default: both. Never run by the other commands — two platforms side by side
is a legitimate state.
USAGE
}

stop_android() {
  android_tools
  "$ADB" emu kill 2>/dev/null
  pkill -f 'qemu-system' 2>/dev/null
  if (( $+commands[gradle] )); then
    gradle --stop >/dev/null 2>&1
  elif [[ -x Android/gradlew ]]; then
    Android/gradlew --stop >/dev/null 2>&1
  fi
  ok "Android emulator + gradle daemons stopped"
}

stop_ios() {
  xcrun simctl shutdown all 2>/dev/null
  ok "iOS simulators shut down"
}

cmd_stop() {
  case $1 in
    -h|--help) help_stop; return 0 ;;
    android) stop_android ;;
    ios) stop_ios ;;
    "") stop_android; stop_ios ;;
    *) die "stop: unknown platform '$1' (ios or android)" ;;
  esac
}
