# Screenshots of the simulator or an Android device, saved to a temp folder and put on the clipboard.

help_shot() {
  cat <<USAGE
Usage: skiprun shot ios [--simulator <name|udid>]
       skiprun shot android [--serial <serial>]

Saves a PNG under \$TMPDIR/skiprun-shots (the newest 20 are kept) and puts it
on the clipboard, ready to paste. iOS shoots the booted simulator; Android the
only online device, \$ANDROID_SERIAL, or a pick.
USAGE
}

# A fresh PNG path in the shots folder, pruning the folder to the newest ones first.
shot_file() {
  local folder=${${TMPDIR:-/tmp}%/}/skiprun-shots keep=20
  mkdir -p "$folder"
  local -a old=( "$folder"/*.png(N.om[$(( keep + 1 )),-1]) )
  (( ${#old} )) && rm -f -- "${old[@]}"
  print -r -- "$folder/$1-$(date +%Y%m%d-%H%M%S).png"
}

shot_finish() {
  local file=$1
  [[ -s $file ]] || { rm -f -- "$file"; die "no screenshot captured" }
  osascript -e "set the clipboard to (read (POSIX file \"$file\") as «class PNGf»)"
  print -r -- "$file (on the clipboard)"
}

cmd_shot() {
  local platform=$1 serial="" simulator=""
  case $platform in
    -h|--help) help_shot; return 0 ;;
    "") help_shot >&2; return 1 ;;
    ios|android) shift ;;
    *) die "shot: unknown platform '$platform' (ios or android)" ;;
  esac
  while (( $# )); do
    case $1 in
      --serial) serial=$2; shift 2 ;;
      --simulator) simulator=$2; shift 2 ;;
      -h|--help) help_shot; return 0 ;;
      *) die "shot: unknown argument '$1' (see skiprun shot --help)" ;;
    esac
  done
  local file; file=$(shot_file "$platform")
  if [[ $platform == ios ]]; then
    local target=$simulator line
    if [[ -z $target ]]; then
      line=$(xcrun simctl list devices booted -j | python3 "$SKIPRUN_LIBEXEC/simulator.py" booted)
      [[ -n $line ]] || die "no booted simulator"
      target=${line%%	*}
    fi
    xcrun simctl io "$target" screenshot "$file" >/dev/null 2>&1
  else
    android_tools
    serial=$(android_pick_serial "$serial") || exit 1
    "$ADB" -s "$serial" exec-out screencap -p > "$file"
  fi
  shot_finish "$file"
}
