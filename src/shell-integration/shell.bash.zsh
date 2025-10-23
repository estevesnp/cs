csd() {
  local cspath
  cspath=$(cs --print "$1") || return
  [ -n "$cspath" ] || return
  builtin cd -- "$cspath" || return
}

