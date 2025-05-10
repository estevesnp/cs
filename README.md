# cs

simple program to change tmux sessions

### TODO

- actually integrate with tmux
- create alternative if no fzf
- better handle allocations
- stream to fzf/output directly
  - start fzf process earlier, while parsing args / reading config is going on
  - extract writer from fzf process and provide to actual program
- restructure flags
  - flag only for setting paths in config
  - flag to override but not save paths in config
  - flag to override preview
  - flag to popout tmux (check fzf flags)
  - flag to print config
  - normal arg is repo to open immediately
  - simplify parsing
