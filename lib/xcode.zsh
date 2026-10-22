# Open a worktree's Xcode workspace (the app project plus the Swift package, not the bare package).

help_xcode() {
  cat <<USAGE
Usage: skiprun xcode [query]

Lists the worktrees of the git repository you are in (those on a branch), opens
the only one at once, offers a pick (fzf, or a numbered menu) when there are
more; a query that matches one branch opens it directly. Opens
Project.xcworkspace, else the first .xcworkspace, else the .xcodeproj, with xed.
USAGE
}

# The Xcode document to open in a tree.
xcode_document() {
  local tree=$1
  local -a found
  [[ -d $tree/Project.xcworkspace ]] && { print -r -- "$tree/Project.xcworkspace"; return 0 }
  found=( "$tree"/*.xcworkspace(N/) ); (( ${#found} )) && { print -r -- "$found[1]"; return 0 }
  found=( "$tree"/(Darwin/|)*.xcodeproj(N/) ); (( ${#found} )) && { print -r -- "$found[1]"; return 0 }
  return 1
}

cmd_xcode() {
  [[ $1 == (-h|--help) ]] && { help_xcode; return 0 }
  (( $# <= 1 )) || die "xcode takes at most one query"
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  local -a WT_PATHS WT_NAMES; local WT_PATH WT_NAME
  list_worktrees "$PWD"
  pick_worktree "${1:-$OPT_WORKTREE}"
  local doc; doc=$(xcode_document "$WT_PATH") || die "nothing to open in $WT_PATH (no .xcworkspace or .xcodeproj)"
  xed "$doc"
}
