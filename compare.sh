#!/bin/bash

# Dateipfade
IPVSADM_OUTPUT=$(mktemp)
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"

# Extrahiere die aktuelle IPVS-Konfiguration
ipvsadm -L -n > "$IPVSADM_OUTPUT"

# Normalisiert eine Adresse zu einheitlichem Format: [ip]:port
# IPv4: 1.2.3.4 443       -> [1.2.3.4]:443
# IPv6: [2001:db8::1] 443 -> [2001:db8::1]:443
# ipvsadm-Stil: 1.2.3.4:443 -> [1.2.3.4]:443
# ipvsadm-Stil: [2001:db8::1]:443 -> [2001:db8::1]:443
normalize_addr() {
    local input="$1"
    # Bereits im Format [x]:port (ipvsadm IPv6)
    if [[ "$input" =~ ^\[.*\]:[0-9]+$ ]]; then
        echo "$input"
    # Format x:port, aber kein IPv6 (also IPv4 ipvsadm-Stil: 1.2.3.4:80)
    elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        local ip="${input%:*}"
        local port="${input##*:}"
        echo "[$ip]:$port"
    # Sollte nicht vorkommen, Fallback
    else
        echo "$input"
    fi
}

# Funktion zum Extrahieren der Gewichtungen aus der Keepalived-Konfiguration
# Gibt aus: [vs_ip]:vs_port [rs_ip]:rs_port weight
extract_keepalived_weights() {
    awk '
    BEGIN { vs = ""; }
    /virtual_server/ {
        ip = $2; port = $3;
        # Entferne eventuelle Klammern und baue einheitliches Format
        gsub(/\[|\]/, "", ip);
        vs = "[" ip "]:" port;
    }
    /real_server/ {
        ip = $2; port = $3;
        gsub(/\[|\]/, "", ip);
        rs = "[" ip "]:" port;
        getline;
        while ($1 != "}") {
            if ($1 == "weight") {
                weight = $2;
                print vs, rs, weight;
            }
            getline;
        }
    }
    ' "$KEEPALIVED_CONF"
}

# Funktion zum Extrahieren der Gewichtungen aus der IPVS-Konfiguration
# ipvsadm -L -n gibt aus:
#   TCP  1.2.3.4:80 rr          (IPv4)
#   TCP  [2001:db8::1]:80 rr    (IPv6)
#   -> 10.0.0.1:80       Masq  1  0  0   (IPv4 real server)
#   -> [2001:db8::2]:80  Masq  1  0  0   (IPv6 real server)
# Gibt aus: [vs_ip]:vs_port [rs_ip]:rs_port weight
extract_ipvsadm_weights() {
    awk '
    /^(TCP|UDP|SCTP)/ {
        vs = $2;
        # Normalisiere IPv4 zu [ip]:port
        if (vs !~ /^\[/) {
            n = split(vs, parts, ":");
            vs = "[" parts[1] "]:" parts[2];
        }
    }
    /->/ {
        rs = $2;
        weight = $4;
        # Normalisiere IPv4 zu [ip]:port
        if (rs !~ /^\[/) {
            n = split(rs, parts, ":");
            rs = "[" parts[1] "]:" parts[2];
        }
        print vs, rs, weight;
    }
    ' "$IPVSADM_OUTPUT"
}

# Vergleiche die Gewichtungen
compare_weights() {
    echo "Vergleiche Gewichtungen zwischen ipvsadm und Keepalived-Konfiguration:"
    echo ""

    keepalived_weights=$(mktemp)
    ipvsadm_weights=$(mktemp)

    extract_keepalived_weights > "$keepalived_weights"
    extract_ipvsadm_weights > "$ipvsadm_weights"

    found_diff=0

    while read -r vs rs k_weight; do
        i_weight=$(grep "^$vs $rs " "$ipvsadm_weights" | awk '{print $3}')

        if [ -z "$i_weight" ]; then
            echo "FEHLT in IPVS: $vs -> $rs (Keepalived Gewicht = $k_weight)"
            found_diff=1
        elif [ "$k_weight" != "$i_weight" ]; then
            echo "Unterschied für $vs -> $rs: Keepalived Gewicht = $k_weight, IPVS Gewicht = $i_weight"
            found_diff=1
        fi
    done < "$keepalived_weights"

    if [ "$found_diff" -eq 0 ]; then
        echo "Keine Unterschiede gefunden."
    fi

    # Aufräumen
    rm -f "$keepalived_weights" "$ipvsadm_weights"
}

# Hauptteil des Skripts
compare_weights

# Aufräumen
rm -f "$IPVSADM_OUTPUT"
