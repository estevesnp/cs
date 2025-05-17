# cs

simple program to change tmux sessions

### TODO

- actually integrate with tmux
- create alternative if no fzf
- stream to fzf/output directly
  - start fzf process earlier, while parsing args / reading config is going on
  - extract writer from fzf process and provide to actual program
- restructure flags
  - flag to popout tmux (check fzf flags)
