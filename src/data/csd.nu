def --env --wrapped PLACEHOLDERNAME [...args] {
  let cspath = (cs search --print ...$args)
  if ($cspath | is-empty) {
    return
  }
  cd $cspath
}
