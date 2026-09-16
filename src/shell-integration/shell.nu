def --env --wrapped csd [...args] {
  let cspath = (cs search --print ...$args)
  if ($cspath | is-empty) {
    return
  }
  cd $cspath
}
