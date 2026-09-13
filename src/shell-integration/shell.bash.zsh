csd() {
  local cspath
  cspath=$(cs search --print "$@") || return
  [ -n "$cspath" ] || return
  builtin cd -- "$cspath" || return
}
