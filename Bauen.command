#!/bin/bash
# Doppelklick im Finder: baut Spurwerk.ipa und zeigt sie danach im Finder an.
cd "$(dirname "$0")"
./bauen.sh && open -R Spurwerk.ipa
echo
read -n 1 -s -r -p "Fertig – beliebige Taste zum Schließen"
