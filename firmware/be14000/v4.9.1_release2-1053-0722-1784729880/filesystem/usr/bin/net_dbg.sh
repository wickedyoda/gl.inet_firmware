export_ipt(){
    iptables-save
    echo
    ipset sa
    if [ -n "$(which fw4)" ]; then
        nft -s list ruleset >nft
    fi
}

export_ipr(){
    echo "========ip rule :=========="
    ip rule
    echo ""

    tables=$(ip rule | awk '/lookup/ {for(i=1;i<=NF;i++) if($i=="lookup") print $(i+1)}' | sort -u)

    for table in $tables; do
        [ "$table" != "0" ] && {
            echo "========table $table :=========="
            ip route show table "$table"
            echo ""
        }
    done
}

export_ipt6(){
    ip6tables-save
}

export_ipr6(){
    echo "========ip -6 rule :=========="
    ip -6 rule
    echo ""

    tables=$(ip -6 rule | awk '/lookup/ {for(i=1;i<=NF;i++) if($i=="lookup") print $(i+1)}' | sort -u)

    for table in $tables; do
        [ "$table" != "0" ] && {
            echo "========table $table :=========="
            ip -6 route show table "$table"
            echo ""
        }
    done
}

export_wg(){
    if command -v gl_wg &> /dev/null; then
        gl_wg
    else
        wg
    fi | sed -e 's/public key: .*/public key: *****/' \
    -e 's/peer: .*/peer: *****/' \
    -e 's/endpoint: .*/endpoint: *****/' \
    -e 's/listening port: .*/listening port: *****/'
}

export_ipt >ipt
export_ipr >ipr
export_ipt6 >ipt6
export_ipr6 >ipr6
export_wg >wg
