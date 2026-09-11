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

## cswalk

the main search functionality is also exposed as a lib, both through zig and C ffi

### zig lib

first fetch the dependency:

```sh
zig fetch --save git+https://github.com/estevesnp/cs
```

then in your build.zig:

```zig
const cs = b.dependency("cs", .{});
exe.root_module.addImport("cswalk", cs.module("cswalk"));
```

example usage:

```zig
const std = @import("std");
const Io = std.Io;
const cs = @import("cswalk");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const roots = &.{ "/home/estevesnp/work", "/home/estevesnp/pers" };
    const opts: cs.SearchOpts = .{
        .reporter = .stderr,
        .max_depth = 10,
        .project_markers = &.{ ".git", ".csm" },
    };

    var projects = try cs.searchProjects(gpa, io, roots, opts);
    defer cs.freeProjects(gpa, &projects);

    std.debug.print("found projects:\n", .{});
    for (projects.keys()) |project| {
        std.debug.print("- {s}\n", .{project});
    }
}
```

### c lib

to build the lib (output is in zig-out/lib):

```sh
zig build lib -Doptimize=ReleaseSafe
```

the header file for the lib is [cswalk.h](./src/walk/ffi/include/cswalk.h)

example usage:

```c
#include "cswalk.h"
#include <stdio.h>

int main() {
    char *roots[] = {"/home/estevesnp/work", "/home/estevesnp/pers"};
    uint32_t count = sizeof(roots) / sizeof(*roots);

    CsSearchOpts opts = {
        .max_depth = 10,
        .enable_logging = true,
    };

    CsSearchResult result = cs_search_projects(roots, count, opts);
    if (!result.ok) {
        // even on failure, the result should be freed
        cs_free_projects(result.handle);
        return 1;
    }

    printf("found projects:\n");
    for (int i = 0; i < result.count; i++) {
        printf("- %s\n", result.paths[i]);
    }

    cs_free_projects(result.handle);
    return 0;
}
```

## neovim plugin

a neovim plugin to search and switch between projects is also available, by
taking advantage of the `cswalk` lib. you will need `zig` in your path in order
to compile the lib when first loading the plugin.

example configuration:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == "cs" and (kind == "install" or kind == "update") then
      if not ev.data.active then
        vim.cmd.packadd("cs")
      end
      require("cs.lib.build").build_cswalk(true)
    end
  end,
})

vim.pack.add({
  "https://github.com/ibhagwan/fzf-lua", -- needed for picker
  "https://github.com/estevesnp/cs",
})

-- example keybinds
vim.keymap.set("n", "<leader>cs", function()
  require("cs").search_projects()
end, { desc = "open project" })

vim.keymap.set("n", "<leader>cv", function()
  require("cs").search_projects({ action = "vsplit" })
end, { desc = "open project in new vsplit" })

vim.keymap.set("n", "<leader>ct", function()
  require("cs").search_projects({ action = "tab" })
end, { desc = "open project in new tab" })
```

if no options are passed in, we first attempt to fetch the config from the
`cs env --full` command, with a fallback to a set of default options.

these default options can be overwritten via `require("cs").setup`.

NOTE: these are the default options. if you don't want to change them, there is
no need to call `require("cs").setup`.

```lua
require("cs").setup({
  preview = jit.os == "Windows" and "dir {}" or "ls {}",
  roots = {},
  markers = { ".git", ".jj" },

  -- options not fetched from `cs env --full`
  action = "open",
  prompt = "choose a project> ",
})
```

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

## tmux integration

here are some useful binds to display a popup window with cs:

```tmux
bind C-o display-popup -E "cs search --session --no-preview"
bind C-w display-popup -E "cs search --window --no-preview"
```

## usage

output of `cs --help`

```
usage: cs [action] [flags]

subcommands:

  search                      search for project
  env                         print config and environment information
  edit                        edit config
  roots                       add or remove paths to roots. also accepts root
  shell                       print shell integrations
  version                     print version. also accepts --version and -v
  help                        print this message. also accepts --help and -h

search:

  description: search for projects from configured roots

  usage: cs [search] [flags] [project]

  arguments:
    project                   query to pre-fill picker. if it has an exact match
                              to any project, instantly selects it

  flags:
    -s, --strategy <strat>    strategy for how to search for projects.
                              concurrent: search for projects and attempt to
                                          match while also displaying paths
                                          inside fzf
                              blocking:   first search for projects and then
                                          spawn fzf if no match is found
                              the option can be chosen directly, e.g. --blocking
                              options: concurrent (default), blocking


    -a, --action <action>     select action to perform on project selection.
                              the option can be chosen directly, e.g. --print
                              options: session, window, print

    -m, --max-depth <depth>   how many directories deep to search for in each
                              root. defaults to 5

    -p, --preview <preview>   preview to use on fzf. e.g.: 'ls {}'

    --no-preview              equivalent to --preview=''. disables fzf preview


env:
  description: display environment information about the program, such as the
               config path, the config itself and what roots are configured
               when searching

  usage: cs env [flags]
    -c, --config <display>    select how to display the config. either display
                              all possible options (full), or only the ones that
                              are configured (partial).
                              the option can be chosen directly, e.g. --full
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


roots:
  description: add or remove the paths that are configured as roots

  usage: cs roots [action] [flags] [paths]

  arguments:
    action                    what to do regarding the provided paths.
                              options: add, remove

    paths                     paths to perform the action on.
                              when adding, paths must always be provided.
                              when removing, paths must be provided unless the
                              --clear flag is provided.

  flags:
    -c, --clear               remove all paths before performing an action.
                              can be used with 'remove' to clear out all roots

    --no-clear                opposite of --clear


shell:
  description: print shell integrations using cs to embed in scripts

  usage : cs shell [shell]

  arguments:
    shell                     shell to print integrations for. if no shell is
                              provided, tries using SHELL from the environment.
                              supported shells: bash, zsh, fish
```
