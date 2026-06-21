function csd
    set -l cspath (cs --print $argv[1]); or return
    test -n "$cspath"; or return
    cd -- $cspath
end
