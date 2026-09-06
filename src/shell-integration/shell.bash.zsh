csd() {
  local cspath
  cspath=$(cs search --print -- "$1") || return
  [ -n "$cspath" ] || return
  builtin cd -- "$cspath" || return
}
