# cs

easily change and manage projects in tmux sessions

## usage

```
usage: cs [project] [flags]

arguments:

  project                          project to automatically open if found


flags:

  -h, --help                       print this message
  -v, -V, --version                print version
  --env                            print config and environment information
  -a, --add-paths <path> [...]     update config adding search paths
  -s, --set-paths <path> [...]     update config overriding search paths
  -r, --remove-paths <path> [...]  update config removing search paths
  --no-preview                     disables fzf preview
  --preview <str>                  preview command to pass to fzf
  --action  <action>               action to execute after finding repository.
                                     options: session, window, print
                                     can call the action directly, e.g. --print
                                     can also do -w instead of --window


description:

  search configured paths for git repositories and run an action on them,
  such as creating a new tmux session or changing directory to the project
```

## csd function

```bash
csd() {
    local cspath
    cspath=$(cs --print "$1") || return
    [ -n "$cspath" ] || return
    builtin cd -- "$cspath" || return
}
```

## TODO

- propper error diagnostics
- native frontend
- shell completions?
