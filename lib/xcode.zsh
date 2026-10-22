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
  local query=$1
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  local -a paths names
  local tree="" line prunable=0
  while IFS= read -r line; do
    case $line in
      "worktree "*) tree=${line#worktree }; prunable=0 ;;
      prunable*) prunable=1 ;;
      "branch refs/heads/"*) (( prunable )) || { paths+=("$tree"); names+=("${line#branch refs/heads/}") } ;;
    esac
  done < <(git worktree list --porcelain)
  (( ${#names} )) || die "no worktree on a branch"
  local -a candidates=( "${names[@]}" )
  if [[ -n $query ]]; then
    local -a hits=( ${(M)names:#*$query*} )
    (( ${#hits} == 0 )) && die "no worktree matches '$query' (have: ${(j:, :)names})"
    (( ${#hits} == 1 )) && candidates=( "${hits[@]}" )
  fi
  local name
  if (( ${#candidates} == 1 )); then
    name=$candidates[1]
  else
    name=$(pick worktree "$query" "${candidates[@]}")
  fi
  [[ -n $name ]] || return 1
  local tree_path=$paths[${names[(ie)$name]}] doc
  doc=$(xcode_document "$tree_path") || die "nothing to open in $tree_path (no .xcworkspace or .xcodeproj)"
  xed "$doc"
}
