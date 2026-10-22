# Show what skiprun resolved for this project; forget the remembered picks.

help_config() {
  cat <<USAGE
Usage: skiprun config [--reset]

Prints the config files in effect, the project (root, product, bundle id) and
the values skiprun would use. --reset removes the remembered env, scheme and
configuration lines from the project's .skiprun; the next run resolves them
again (and asks again where several match).

Files: ~/.config/skiprun/config (machine), <project>/.skiprun (project, add it
to .gitignore). Keys: env, ios.simulator, ios.scheme[.<env>],
ios.configuration[.<env>], android.avd, android.serial.
USAGE
}

cmd_config() {
  local reset=0
  while (( $# )); do
    case $1 in
      --reset) reset=1; shift ;;
      -h|--help) help_config; return 0 ;;
      *) die "config: unknown argument '$1' (see skiprun config --help)" ;;
    esac
  done
  PROJECT_ROOT=$(find_project_root) || PROJECT_ROOT=""
  cfg_load
  if (( reset )); then
    [[ -n $PROJECT_ROOT ]] || die "not inside a Skip project"
    local file; file=$(project_config_file)
    [[ -f $file ]] || { ok "nothing remembered ($file does not exist)"; return 0 }
    sed -i '' -E '/^[[:space:]]*(env|ios\.scheme(\.[^=]*)?|ios\.configuration(\.[^=]*)?)[[:space:]]*=/d' "$file"
    [[ -s $file ]] || rm -f -- "$file"
    ok "forgot env, scheme and configuration picks in ${file/#$HOME/~}"
    cfg_load
  fi
  local global; global=$(global_config_file)
  print -r -- "machine config: $global$([[ -f $global ]] || print -r ' (none)')"
  if [[ -z $PROJECT_ROOT ]]; then
    print -r -- "project:        none (no Skip.env above $PWD)"
  else
    local project; project=$(project_config_file)
    print -r -- "project config: $project$([[ -f $project ]] || print -r ' (none)')"
    print -r -- "project root:   $PROJECT_ROOT"
    print -r -- "product:        $(product_name)"
    print -r -- "bundle id:      $(bundle_id)"
    print -r -- "android app id: $(android_app_id)"
    local -a flavors=( ${(f)"$(android_flavors)"} )
    print -r -- "environments:   ${${(j:, :)flavors}:-none in gradle}"
  fi
  print -r -- "env:            ${CFG[env]:-(resolved on the next run)}"
  local key
  for key in ${(ko)CFG}; do
    [[ $key == (ios.scheme*|ios.configuration*) ]] && print -r -- "$key = ${CFG[$key]}"
  done
  print -r -- "ios.simulator:  ${CFG[ios.simulator]:-(booted one, else the first iPhone of the selected Xcode)}"
  print -r -- "android.avd:    ${CFG[android.avd]:-(first AVD)}"
  print -r -- "android.serial: ${CFG[android.serial]:-(not set)}"
}
