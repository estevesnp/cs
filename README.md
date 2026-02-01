# cs

cli tool for searching and opening projects in tmux

## dependencies

- [fzf](https://github.com/junegunn/fzf) - project picker (native support is planned, removing dependency)
- [tmux](https://github.com/tmux/tmux) - for opening projects in a new tmux session

## installation

needs [zig](https://codeberg.org/ziglang/zig) version `0.16.0-dev.2368+380ea6fb5` (nightly) or higher

1. clone repository

```sh
git clone https://github.com/estevesnp/cs.git
```

2. build `cs`

```sh
zig build -Doptimize=ReleaseSafe
```

3. add executable to PATH. default build path is `path/to/repo/zig-out/bin/cs`

## config

the config path is `$XDG_CONFIG_HOME/cs/config.json` in linux/mac (with a fallback to `HOME`),
and `%APPDATA%\cs\config.json` in windows.

the config path can be overwritten by setting the `CS_CONFIG_PATH` environment variable.

can configure options such as:

- markers for `cs` to identify a project
- custom [preview option to fzf](https://github.com/junegunn/fzf?tab=readme-ov-file#preview-window)
- default action to perform upon project selection
  - `session` - open new tmux session
  - `window` - open new tmux window
  - `print` - print out selected project (e.g. for scripting)
- etc

example config:

```json
{
  "project_roots": ["/home/estevesnp/proj", "/home/estevesnp/pers"],
  "project_markers": [".git", ".jj", ".csm"],
  "preview": "eza {} -la --color=always",
  "action": "session"
}
```

## shell integration

current shell integrations:

- `csd` - cd to chosen project using `cs --print`

### setting up shell integration

- zsh

```zsh
source <(cs --shell zsh)
```

- bash

```bash
eval "$(cs --shell bash)"
```

## usage

```
usage: cs [project] [flags]

arguments:

  project                          project to automatically open if found


flags:

  -h, --help                       print this message
  -v, -V, --version                print version
  --env                            print config and environment information
  --edit [editor]                  open config in editor. if no editor is
                                   provided, the following env vars are checked:
                                     - VISUAL
                                     - EDITOR
  -a, --add-paths <path> [...]     update config adding search paths
  -s, --set-paths <path> [...]     update config overriding search paths
  -r, --remove-paths <path> [...]  update config removing search paths
  --shell [shell]                  print out shell integration functions.
                                     options: zsh, bash
                                     tries to detect shell if none is provided
  --no-preview                     disables fzf preview
  --preview <str>                  preview command to pass to fzf
  --action  <action>               action to execute after finding project.
                                     options: session, window, print
                                     can call the action directly, e.g. --print
                                     can also do -w instead of --window


description:

  search configured paths for projects and run an action on the selection,
  such as creating a new tmux session from it or printing out it's path
```

## TODO

- project marker as cli option?
- project roots as cli option?
- tmux script?
- propper error diagnostics and error handling
- native frontend
- shell completions?
