#!/bin/bash

# Dateipfade
IPVSADM_OUTPUT=$(mktemp)
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"

# Extrahiere die aktuelle IPVS-Konfiguration
ipvsadm -L -n > "$IPVSADM_OUTPUT"

# Funktion zum Extrahieren der Gewichtungen aus der Keepalived-Konfiguration
extract_keepalived_weights() {
    awk '
    BEGIN { vs = ""; }
    /virtual_server/ { vs = $2 " " $3; }
    /real_server/ {
        rs = $2 " " $3;
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
extract_ipvsadm_weights() {
    awk '
    /TCP/ { vs = $2; }
    /->/ {
        rs = $2;
        weight = $4;
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

    while read -r line; do
        vs=$(echo "$line" | awk '{print $1":"$2}')
        rs=$(echo "$line" | awk '{print $3":"$4}')
        k_weight=$(echo "$line" | awk '{print $5}')
        i_weight=$(grep "$vs $rs" "$ipvsadm_weights" | awk '{print $3}')
	if [ "$k_weight" != "$i_weight" ]; then
            echo "Unterschied für $vs -> $rs: Keepalived Gewicht = $k_weight, IPVS Gewicht = $i_weight"
        fi
    done < "$keepalived_weights"

    # Aufräumen
    rm -f "$keepalived_weights" "$ipvsadm_weights"
}

# Hauptteil des Skripts
compare_weights

# Aufräumen
rm -f "$IPVSADM_OUTPUT"

