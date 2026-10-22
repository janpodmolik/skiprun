# Screenshots of a simulator, an iPhone or an Android device, saved to a temp folder and put on the clipboard.

help_shot() {
  cat <<USAGE
Usage: skiprun shot ios [--device <name|udid>]
       skiprun shot android [--serial <serial>]

Saves a PNG under \$TMPDIR/skiprun-shots (the newest 20 are kept) and puts it
on the clipboard, ready to paste. The file name says where it came from:
ios-simulator-<name>-…, ios-device-<name>-…, android-<serial>-….

ios      the booted simulator (simctl) or the connected iPhone (devicectl);
         with both, a pick, unless --device names one
android  the only online device, \$ANDROID_SERIAL, or a pick
USAGE
}

# A fresh PNG path in the shots folder, pruning the folder to the newest ones first.
shot_file() {
  local folder=${${TMPDIR:-/tmp}%/}/skiprun-shots keep=20
  mkdir -p "$folder"
  local -a old=( "$folder"/*.png(N.om[$(( keep + 1 )),-1]) )
  (( ${#old} )) && rm -f -- "${old[@]}"
  local label=${1//[^A-Za-z0-9._-]/-}
  print -r -- "$folder/$label-$(date +%Y%m%d-%H%M%S).png"
}

shot_finish() {
  local file=$1
  [[ -s $file ]] || { rm -f -- "$file"; die "no screenshot captured" }
  osascript -e "set the clipboard to (read (POSIX file \"$file\") as «class PNGf»)"
  print -r -- "$file (on the clipboard)"
}

# Sets SHOT_KIND (simulator|device), SHOT_ID and SHOT_NAME from the booted simulators and
# the connected iPhones; --device matches a name or an identifier of either.
shot_ios_target() {
  local want=$1 line
  local -a sims phones labels
  sims=( ${(f)"$(xcrun simctl list devices booted -j | python3 "$SKIPRUN_LIBEXEC/simulator.py" booted)"} )
  phones=( ${(f)"$(xcrun devicectl list devices --json-output - 2>/dev/null | python3 "$SKIPRUN_LIBEXEC/iphones.py")"} )
  if [[ -n $want ]]; then
    for line in "${sims[@]}"; do
      [[ $want == "${line%%	*}" || $want == "${line#*	}" ]] && { SHOT_KIND=simulator; SHOT_ID=${line%%	*}; SHOT_NAME=${line#*	}; return 0 }
    done
    for line in "${phones[@]}"; do
      [[ $want == "${line%%	*}" || $want == "${line#*	}" ]] && { SHOT_KIND=device; SHOT_ID=${line%%	*}; SHOT_NAME=${line#*	}; return 0 }
    done
    # Not seen in either list: let devicectl try the identifier as given (ECID, serial, DNS name).
    SHOT_KIND=device; SHOT_ID=$want; SHOT_NAME=$want
    return 0
  fi
  for line in "${sims[@]}"; do labels+=("simulator	${line#*	}	${line%%	*}"); done
  for line in "${phones[@]}"; do labels+=("device	${line#*	}	${line%%	*}"); done
  case ${#labels} in
    0) die "no booted simulator and no connected iPhone (xcrun simctl list devices booted; xcrun devicectl list devices)" ;;
    1) line=$labels[1] ;;
    *) local -a shown=( "${(@)labels%%	*}" )
       local i; for (( i = 1; i <= ${#labels}; i++ )); do shown[i]="${labels[i]%%	*} · ${${labels[i]#*	}%%	*}"; done
       local choice; choice=$(pick "screenshot of" "" "${shown[@]}")
       [[ -n $choice ]] || die "nothing picked"
       line=$labels[${shown[(ie)$choice]}] ;;
  esac
  SHOT_KIND=${line%%	*}
  local rest=${line#*	}
  SHOT_NAME=${rest%%	*}
  SHOT_ID=${rest#*	}
}

cmd_shot() {
  local platform=$1 serial="" device=""
  case $platform in
    -h|--help) help_shot; return 0 ;;
    "") help_shot >&2; return 1 ;;
    ios|android) shift ;;
    *) die "shot: unknown platform '$platform' (ios or android)" ;;
  esac
  while (( $# )); do
    case $1 in
      --serial) serial=$2; shift 2 ;;
      --device) device=$2; shift 2 ;;
      -h|--help) help_shot; return 0 ;;
      *) die "shot: unknown argument '$1' (see skiprun shot --help)" ;;
    esac
  done
  local file
  if [[ $platform == ios ]]; then
    local SHOT_KIND SHOT_ID SHOT_NAME
    shot_ios_target "$device"
    file=$(shot_file "ios-$SHOT_KIND-$SHOT_NAME")
    if [[ $SHOT_KIND == simulator ]]; then
      xcrun simctl io "$SHOT_ID" screenshot "$file" >/dev/null 2>&1
    else
      xcrun devicectl device capture screenshot --device "$SHOT_ID" --destination "$file" -q 2>&1 | grep -v '^$' >&2
    fi
  else
    android_tools
    serial=$(android_pick_serial "$serial") || exit 1
    file=$(shot_file "android-$serial")
    "$ADB" -s "$serial" exec-out screencap -p > "$file"
  fi
  shot_finish "$file"
}
