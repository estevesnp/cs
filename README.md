# cs

simple program to change tmux sessions

## usage

```
usage: cs [repo] [flags]

arguments:

  repo                          repository to automatically open if found

flags:

  -h, --help                    print this message
  --config                      print config and config path
  --preview <str>               preview command to pass to fzf
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
      "root": "/Users/esteves/proj",
      "depth": 10
    },
    {
      "root": "/Users/esteves/tmp",
      "depth": 10
    }
  ],
  "preview_cmd": "eza -la --color=always {}"
}
```
