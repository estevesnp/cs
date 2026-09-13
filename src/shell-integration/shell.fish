function csd
    set -l cspath (cs search --print $argv); or return
    test -n "$cspath"; or return
    cd -- $cspath
end
