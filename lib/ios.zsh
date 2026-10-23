# iOS: scheme/configuration discovery, simulator choice, build, install, launch.

help_ios() {
  cat <<USAGE
Usage: skiprun ios [--env <name>] [--scheme <name>] [--configuration <name>]
                   [--simulator <name|udid>] [-n|--dry-run]

Builds the app with xcodebuild (Project.xcworkspace), installs and launches it
on the booted simulator. With none booted it boots the configured simulator
(ios.simulator) or the first iPhone of the selected Xcode's runtime.

An environment <name> selects configuration Debug-<name> and the scheme whose
name contains it; a scheme that names no environment stands for the ones left
over. Several candidates → a pick (fzf, or a numbered menu), remembered in
.skiprun. --scheme / --configuration override and update that memory.
USAGE
}

# The Xcode container to build: Project.xcworkspace, any workspace, else the project.
ios_container() {
  local -a found
  if [[ -d $PROJECT_ROOT/Project.xcworkspace ]]; then
    IOS_CONTAINER=( -workspace "$PROJECT_ROOT/Project.xcworkspace" )
  elif found=( "$PROJECT_ROOT"/*.xcworkspace(N/) ) && (( ${#found} )); then
    IOS_CONTAINER=( -workspace "$found[1]" )
  elif found=( "$PROJECT_ROOT"/(Darwin/|)*.xcodeproj(N/) ) && (( ${#found} )); then
    IOS_CONTAINER=( -project "$found[1]" )
  else
    die "no .xcworkspace or .xcodeproj found in $PROJECT_ROOT"
  fi
}

# The .xcodeproj behind the container: only a project listing carries the configurations.
ios_project() {
  local -a found
  if [[ -d $PROJECT_ROOT/Project.xcworkspace ]]; then
    local ref; ref=$(sed -nE 's|.*location = "group:([^"]+\.xcodeproj)".*|\1|p' "$PROJECT_ROOT/Project.xcworkspace/contents.xcworkspacedata" | head -n 1)
    [[ -n $ref && -d $PROJECT_ROOT/$ref ]] && { print -r -- "$PROJECT_ROOT/$ref"; return 0 }
  fi
  found=( "$PROJECT_ROOT"/(Darwin/|)*.xcodeproj(N/) )
  (( ${#found} )) && { print -r -- "$found[1]"; return 0 }
  return 1
}

# Fills IOS_SCHEMES, IOS_CONFIGURATIONS and IOS_ENVS (the <x> of every Debug-<x>). ~15 s on a
# real project, which is why the resolved scheme and configuration are remembered.
typeset -ga IOS_SCHEMES IOS_CONFIGURATIONS IOS_ENVS
ios_load_listing() {
  (( ${#IOS_CONFIGURATIONS} )) && return 0
  local project; project=$(ios_project) || die "no .xcodeproj found in $PROJECT_ROOT"
  say "Listing schemes and configurations of ${project:t} (once, then remembered)..."
  local listing
  listing=$(xcodebuild -list -json -project "$project" -skipPackagePluginValidation -skipMacroValidation 2>/dev/null \
    | python3 -c '
import json, sys
project = json.load(sys.stdin).get("project", {})
seen = []
for scheme in project.get("schemes", []):
    if scheme not in seen:
        seen.append(scheme)
        print("S\t" + scheme)
for configuration in project.get("configurations", []):
    print("C\t" + configuration)
') || die "xcodebuild -list failed for $project"
  IOS_SCHEMES=( ${${(M)${(f)listing}:#S	*}#S	} )
  IOS_CONFIGURATIONS=( ${${(M)${(f)listing}:#C	*}#C	} )
  IOS_ENVS=( ${(L)${${(M)IOS_CONFIGURATIONS:#(#i)Debug-*}#(#i)Debug-}} )
  (( ${#IOS_SCHEMES} )) || die "no schemes in $project (share one in Xcode: Manage Schemes → Shared)"
}

# Sets SCHEME and CONFIGURATION for ENV from the options, the memory, or the listing.
resolve_ios_build() {
  local suffix=${ENV:+.$ENV}
  SCHEME=${OPT_SCHEME:-$(cfg "ios.scheme$suffix")}
  CONFIGURATION=${OPT_CONFIGURATION:-$(cfg "ios.configuration$suffix")}
  if [[ -z $CONFIGURATION ]]; then
    ios_load_listing
    local want=${ENV:+Debug-$ENV}; want=${want:-Debug}
    local i=${IOS_CONFIGURATIONS[(i)(#i)$want]}
    (( i <= ${#IOS_CONFIGURATIONS} )) || die "no configuration '$want' (have: ${(j:, :)IOS_CONFIGURATIONS}); pass --configuration"
    CONFIGURATION=$IOS_CONFIGURATIONS[$i]
  fi
  if [[ -z $SCHEME ]]; then
    ios_load_listing
    local -a cands
    [[ -n $ENV ]] && cands=( ${(M)IOS_SCHEMES:#(#i)*$ENV*} )
    if (( ${#cands} == 0 )); then
      cands=( "${IOS_SCHEMES[@]}" )
      local e; for e in "${IOS_ENVS[@]}"; do cands=( ${cands:#(#i)*$e*} ); done
    fi
    (( ${#cands} )) || cands=( "${IOS_SCHEMES[@]}" )
    if (( ${#cands} == 1 )); then
      SCHEME=$cands[1]
    else
      SCHEME=$(pick "scheme${ENV:+ ($ENV)}" "" "${cands[@]}")
      [[ -n $SCHEME ]] || die "no scheme picked"
    fi
  fi
  cfg_remember "ios.scheme$suffix" "$SCHEME"
  cfg_remember "ios.configuration$suffix" "$CONFIGURATION"
}

# Sets SIM_UDID and SIM_NAME: a booted simulator, else the configured or default one, booted here.
ios_target_simulator() {
  local helper=$SKIPRUN_LIBEXEC/simulator.py line
  line=$(xcrun simctl list devices booted -j | python3 "$helper" booted | head -n 1)
  if [[ -n $line ]]; then
    SIM_UDID=${line%%	*}; SIM_NAME=${line#*	}
    ok "Simulator already running: $SIM_NAME"
    return 0
  fi
  local want=${OPT_SIMULATOR:-$(cfg ios.simulator)}
  if [[ -n $want ]]; then
    line=$(xcrun simctl list devices available -j | python3 "$helper" find "$want")
    [[ -n $line ]] || die "no available simulator matches '$want' (xcrun simctl list devices available)"
  else
    local sdk; sdk=$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)
    line=$(xcrun simctl list devices available -j | python3 "$helper" default "$sdk")
    [[ -n $line ]] || die "no available iPhone simulator (xcrun simctl list devices available)"
  fi
  SIM_UDID=${line%%	*}; SIM_NAME=${line#*	}
  say "Starting iOS simulator ($SIM_NAME)..."
  run xcrun simctl boot "$SIM_UDID"
  run open -a Simulator
  if (( ${SKIPRUN_DRY_RUN:-0} )); then
    print -r -- "+ xcrun simctl bootstatus $SIM_UDID -b"
  else
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
  fi
}

cmd_ios() {
  local OPT_ENV="" OPT_SCHEME="" OPT_CONFIGURATION="" OPT_SIMULATOR=""
  while (( $# )); do
    case $1 in
      --env) OPT_ENV=$2; shift 2 ;;
      --scheme) OPT_SCHEME=$2; shift 2 ;;
      --configuration) OPT_CONFIGURATION=$2; shift 2 ;;
      --simulator) OPT_SIMULATOR=$2; shift 2 ;;
      -n|--dry-run) SKIPRUN_DRY_RUN=1; shift ;;
      -h|--help) help_ios; return 0 ;;
      *) die "ios: unknown argument '$1' (see skiprun ios --help)" ;;
    esac
  done
  require_project
  choose_build_worktree
  ios_container
  resolve_env ios
  resolve_ios_build
  ios_target_simulator

  local derived=$PROJECT_ROOT/.build/Darwin/DerivedData
  say "Building iOS app: $SCHEME ($CONFIGURATION)..."
  local -a build_env=( ${(f)"$(ios_build_env)"} )
  run env "${build_env[@]}" xcodebuild "${IOS_CONTAINER[@]}" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -sdk iphonesimulator -derivedDataPath "$derived" \
    -skipPackagePluginValidation -skipMacroValidation -quiet build || die "Build failed"

  local products=$derived/Build/Products/$CONFIGURATION-iphonesimulator
  local app=$products/$(product_name).app
  if [[ ! -d $app ]]; then
    local -a apps=( "$products"/*.app(N/) )
    (( ${#apps} )) && app=$apps[1]
  fi
  if (( ${SKIPRUN_DRY_RUN:-0} )) && [[ ! -d $app ]]; then
    print -r -- "+ (would install $app)"
    return 0
  fi
  [[ -d $app ]] || die "built app not found under $products"
  local bundle; bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist" 2>/dev/null)
  [[ -n $bundle ]] || bundle=$(bundle_id)
  say "Installing ${app:t} on $SIM_NAME"
  run xcrun simctl install "$SIM_UDID" "$app" || die "Install failed"
  say "Launching $bundle"
  run xcrun simctl launch "$SIM_UDID" "$bundle"
}

# ios_build_env — variables xcodebuild needs for this project. A bridging (Skip Fuse) module
# needs the Skip packages as dynamic frameworks, or SkipFoundation is linked statically into two
# of them and the ObjC runtime reports a duplicate class at every launch.
ios_build_env() {
  local -a ymls=( "$PROJECT_ROOT"/Sources/*/Skip/skip.yml(N) )
  (( ${#ymls} )) && grep -lE '^\s*enabled:\s*true' "${ymls[@]}" >/dev/null 2>&1 && print -r -- "SKIP_DYNAMIC_LIBRARIES=1"
  return 0
}
