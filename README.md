# cs

cli tool for searching and opening projects in tmux

## dependencies

- [fzf](https://github.com/junegunn/fzf) - project picker (native support is planned, removing dependency)
- [tmux](https://github.com/tmux/tmux) - for opening projects in a new tmux session

## installation

1. clone repository

```sh
git clone https://github.com/estevesnp/cs.git
```

2. build `cs`

```sh
zig build -Doptimize=ReleaseSafe
```

3. add executable to PATH. default build path is `path/to/repo/zig-out/bin/cs`
   - build path can be overwritten by using the `-p` flag, like `zig build -Doptimize=ReleaseSafe -p ~/.local/bin`

## config

the config dir path is `$XDG_CONFIG_HOME/cs` in linux/mac (with a fallback to `$HOME/.config/cs`),
and `%APPDATA%\cs` in windows.

the config path can be overwritten by setting the `CS_CONFIG_PATH` environment variable.

the config consists of two files:

- `config.json` - general config
- `roots.json` - local paths to start checking for projects

example `config.json`:

```json
{
  "project_markers": [".git", ".jj", ".csm"],
  "preview": "eza {} -a1 --color=always --icons",
  "max_depth": 10
}
```

example `roots.json`:

```json
["/home/estevesnp/work", "/home/estevesnp/pers"]
```

to see the full config options, you can look at the `config` property of the
output of `cs env --full`, which contains all default config values

## shell integration

current shell integrations:

- `csd` - cd to chosen project using `cs search --print`

### setting up shell integration

- zsh

```zsh
source <(cs shell zsh)
```

- bash

```bash
eval "$(cs shell bash)"
```

- fish

```fish
cs shell fish | source
```

## usage

output of `cs --help`

```
usage: cs [action] [flags]

subcommands:

  search                     search for project
  env                        print config and environment information
  edit                       edit config
  shell                      print shell integrations
  version                    print version. also accepts --version and -v
  help                       print this message. also accepts --help and -h

search:

  description: search for projects from configured roots

  usage: cs [search] [flags] [project]

  arguments:
    project                   query to pre-fill picker. if it has an exact match
                              to any project, instantly selects it

  flags:
    -a, --action <action>     select action to perform on project selection.
                              can also choose the action directly, like --print.
                              options: session, window, print

    -m, --max-depth <depth>   how many directories deep to search for in each
                              root. defaults to 5


env:
  description: display environment information about the program, such as the
               config path, the config itself and what roots are configured
               when searching

  usage: cs env [flags]
    -c, --config <display>    select how to display the config. either display
                              all possible options (full), or only the ones that
                              are configured (partial).
                              can also choose the display directly, like --full.
                              options: partial (default), full


edit:
  description: open the config inside your editor

  usage: cs edit [flags]

  flags:
    -m, --mode                select what to open in the editor.
                              options: config (default), roots, dir (config dir)

    -e, --editor              select what editor to open the config with.
                              if none is provided, defaults to the environment:
                              CS_EDITOR -> VISUAL -> EDITOR


shell:
  description: print shell integrations using cs to embed in scripts

  usage : cs shell [shell]

  arguments:
    shell                     shell to print integrations for.
                              in none is provided, try using the SHELL env var.
                              supported shells: bash, zsh, fish
```
