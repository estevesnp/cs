# cs

simple program to change tmux sessions

## usage

```
usage: cs [repo] [flags]

arguments:

  repo                          repository to automatically open if found


flags:

  -h, --help                    print this message
  -v, --version                 print version
  --config                      print config and config path
  --no-preview                  disables fzf preview
  --preview <str>               preview command to pass to fzf
  --script  <str>               script to run on new tmux session
  -p, --paths     <path> [...]  choose paths to search for in this run
  -s, --set-paths <path> [...]  update config setting paths to search for
  -a, --add-paths <path> [...]  update config adding to paths to search for


description:

  search for git repositories in a list of configured paths and prompt user to
  either create a new tmux session or open an existing one inside that directory
```

## config

example config:

```json
{
  "sources": [
    {
      "root": "/home/esteves/proj",
      "depth": 10
    },
    {
      "root": "/home/esteves/tmp",
      "depth": 10
    }
  ],
  "preview_cmd": "eza -la --color=always {}",
  "tmux_script": "new-window; previous-window; send-keys 'nvim .' C-m"
}
```
