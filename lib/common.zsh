# Shared helpers: output, pickers, project discovery, Skip.env, config, environments.

say()  { print -r -- "▶ $*" }
ok()   { print -r -- "✅ $*" }
warn() { print -r -- "⚠️  $*" >&2 }
die()  { print -r -- "❌ $*" >&2; exit 1 }

# Prints the command instead of running it under --dry-run.
run() {
  if (( ${SKIPRUN_DRY_RUN:-0} )); then
    print -r -- "+ ${(q-)@}"
  else
    "$@"
  fi
}

# pick <prompt> <query> <item>... — one item per argument; fzf when installed, zsh select otherwise.
pick() {
  local prompt=$1 query=$2; shift 2
  if (( $+commands[fzf] )) && [[ -t 2 ]]; then
    printf '%s\n' "$@" | fzf --height 10 --reverse --prompt "$prompt> " ${query:+--query "$query"}
  else
    local choice
    select choice in "$@"; do [[ -n $choice ]] && break; done
    print -r -- "$choice"
  fi
}

# The nearest ancestor of the cwd that holds Skip.env.
find_project_root() {
  local dir=$PWD
  while [[ $dir != / ]]; do
    [[ -f $dir/Skip.env ]] && { print -r -- "$dir"; return 0 }
    dir=${dir:h}
  done
  return 1
}

require_project() {
  PROJECT_ROOT=$(find_project_root) || die "not inside a Skip project (no Skip.env found above $PWD)"
  cd -- "$PROJECT_ROOT" || die "cannot enter $PROJECT_ROOT"
  cfg_load
}

# skip_env <KEY> — a value from Skip.env (xcconfig syntax, // comments).
skip_env() {
  [[ -f $PROJECT_ROOT/Skip.env ]] || return 1
  sed -nE "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*||p" "$PROJECT_ROOT/Skip.env" | sed -E 's|[[:space:]]*//.*$||; s|[[:space:]]*$||' | head -n 1
}

product_name()  { skip_env PRODUCT_NAME }
bundle_id()     { skip_env PRODUCT_BUNDLE_IDENTIFIER }
android_app_id() {
  local id; id=$(skip_env ANDROID_APPLICATION_ID)
  [[ -n $id ]] && print -r -- "$id" || bundle_id
}

# Config: `key = value` lines, `#` comments; the project file overrides the machine file.
typeset -gA CFG
config_home() { print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/skiprun" }
state_home()  { print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/skiprun" }
global_config_file()  { print -r -- "$(config_home)/config" }
project_config_file() { print -r -- "${PROJECT_ROOT:-$PWD}/.skiprun" }

cfg_read_file() {
  local file=$1 line key value
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%\#*}
    [[ $line == *=* ]] || continue
    key=${line%%=*}; key=${key##[[:space:]]#}; key=${key%%[[:space:]]#}
    value=${line#*=}; value=${value##[[:space:]]#}; value=${value%%[[:space:]]#}
    [[ -n $key ]] && CFG[$key]=$value
  done < "$file"
}

cfg_load() {
  CFG=()
  cfg_read_file "$(global_config_file)"
  [[ -n $PROJECT_ROOT ]] && cfg_read_file "$(project_config_file)"
}

cfg() { print -r -- "${CFG[$1]}" }

# Writes a value into the project's .skiprun, replacing an existing line for the key.
cfg_remember() {
  local key=$1 value=$2 file; file=$(project_config_file)
  [[ ${CFG[$key]} == "$value" ]] && return 0
  CFG[$key]=$value
  local pattern="^[[:space:]]*${key//./\\.}[[:space:]]*="
  if [[ -f $file ]] && grep -qE "$pattern" "$file"; then
    sed -i '' -E "s|${pattern}.*|$key = $value|" "$file"
  else
    print -r -- "$key = $value" >> "$file"
  fi
  print -r -- "   remembered $key = $value in ${file/#$HOME/~}"
}

# Android SDK tools.
android_sdk() { print -r -- "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}" }
android_tools() {
  ADB=$(android_sdk)/platform-tools/adb
  EMULATOR=$(android_sdk)/emulator/emulator
  [[ -x $ADB ]] || die "adb not found at $ADB (set ANDROID_HOME)"
}

# Flavor names declared inside productFlavors {} of the app module.
android_flavors() {
  local gradle=$PROJECT_ROOT/Android/app/build.gradle.kts
  [[ -f $gradle ]] || return 0
  awk '
    /productFlavors[[:space:]]*\{/ { inside = 1; depth = 0 }
    inside {
      opens = gsub(/\{/, "{"); closes = gsub(/\}/, "}"); depth += opens - closes
      if (match($0, /create\("[A-Za-z0-9_]+"\)/)) print substr($0, RSTART + 8, RLENGTH - 10)
      if (depth <= 0 && (opens || closes)) inside = 0
    }' "$gradle"
}

# resolve_env <ios|android> — sets ENV from --env, the config, the project's single
# environment, or a remembered pick. Android never needs the slow xcodebuild listing.
resolve_env() {
  ENV=${OPT_ENV:-$(cfg env)}
  [[ -n $ENV ]] && return 0
  local -a envs
  envs=( ${(f)"$(android_flavors)"} )
  if (( ${#envs} == 0 )) && [[ $1 == ios ]]; then
    ios_load_listing
    envs=( "${IOS_ENVS[@]}" )
  fi
  case ${#envs} in
    0) ENV="" ;;
    1) ENV=$envs[1] ;;
    *) ENV=$(pick environment "" "${envs[@]}")
       [[ -n $ENV ]] || die "no environment picked"
       cfg_remember env "$ENV" ;;
  esac
}
