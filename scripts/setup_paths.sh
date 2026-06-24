#!/bin/bash
# setup_paths.sh
# A executer UNE SEULE FOIS apres le clonage du depot sur une nouvelle machine.
# Remplace les chemins absolus hardcodes par le $HOME de l'utilisateur courant.

set -e

OLD_HOME="/home/konseibo"
NEW_HOME="$(eval echo ~$(whoami))"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Configuration des chemins ==="
echo "Ancien chemin : $OLD_HOME"
echo "Nouveau chemin : $NEW_HOME"
echo "Dossier des scripts : $SCRIPTS_DIR"
echo ""

if [ "$OLD_HOME" == "$NEW_HOME" ]; then
    echo "⚠️  Les chemins sont identiques, aucune modification necessaire."
    exit 0
fi

# Liste des fichiers a verifier
FILES=(
    "wrf_cron.sh"
)

echo "=== Fichiers modifies ==="
MODIFIED=0

for FILE in "${FILES[@]}"; do
    FILEPATH="$SCRIPTS_DIR/$FILE"

    if [ ! -f "$FILEPATH" ]; then
        echo "⚠️  $FILE : introuvable, ignore."
        continue
    fi

    if grep -q "$OLD_HOME" "$FILEPATH"; then
        sed -i "s|$OLD_HOME|$NEW_HOME|g" "$FILEPATH"
        echo "✅ $FILE : $OLD_HOME → $NEW_HOME"
        MODIFIED=$((MODIFIED + 1))
    else
        echo "—  $FILE : aucune occurrence de $OLD_HOME trouvee."
    fi
done

echo ""
echo "=== Resume ==="
echo "$MODIFIED fichier(s) modifie(s)."
echo "Termine."
