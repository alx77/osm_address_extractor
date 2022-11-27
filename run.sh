#!/bin/bash


HEIGHT=25
WIDTH=40
CHOICE_HEIGHT=20
BACKTITLE="Backtitle here"
TITLE="Select country"
MENU="Choose one of the following options:"

#extend this list and the following 'case' with your country if you need (all countries from https://download.geofabrik.de/ are allowed)
OPTIONS=(
    "IL" "Israel and Palestine"
    "AL" "Albania"
    "AD" "Andorra"
    "AT" "Austria"
    "BY" "Belarus"
    "BE" "Belgium"
    "BG" "Bulgaria"
    "HR" "Croatia"
    "CZ" "Czech Republic"
    "DK" "Denmark"
    "FI" "Finland"
    "FR" "France"
    "GE" "Georgia"
    "DE" "Germany"
    "GB" "Great Britain"
    "GR" "Greece"
    "HU" "Hungary"
    "IT" "Italy"
    "LV" "Latvia"
    "LT" "Lithuania"
    "LU" "Luxembourg"
    "MD" "Moldova"
    "MC" "Monaco"
    "ME" "Montenegro"
    "NL" "Netherlands"
    "NO" "Norway"
    "PL" "Poland"
    "PT" "Portugal"
    "RO" "Romania"
    "RU" "Russian Federation"
    "RS" "Serbia"
    "SK" "Slovakia"
    "SI" "Slovenia"
    "ES" "Spain"
    "SE" "Sweden"
    "CH" "Switzerland"
    "TR" "Turkey"
    "UA" "Ukraine"
)

CHOICE=$(dialog --clear \
                --backtitle "$BACKTITLE" \
                --title "$TITLE" \
                --menu "$MENU" \
                $HEIGHT $WIDTH $CHOICE_HEIGHT \
                "${OPTIONS[@]}" \
                2>&1 >/dev/tty)

clear
case $CHOICE in
    "IL")
        URL="asia/israel-and-palestine-latest.osm.pbf"
        ;;
    "AL")
        URL="europe/albania-latest.osm.pbf"
        ;;
    "AD")
        URL="europe/andorra-latest.osm.pbf"
        ;;
    "AT")
        URL="europe/austria-latest.osm.pbf"
        ;;
    "BY")
        URL="europe/belarus-latest.osm.pbf"
        ;;
    "BE")
        URL="europe/belgium-latest.osm.pbf"
        ;;
    "BG")
        URL="europe/bulgaria-latest.osm.pbf"
        ;;
    "HR")
        URL="europe/croatia-latest.osm.pbf"
        ;;
    "CZ")
        URL="europe/czech-republic-latest.osm.pbf"
        ;;
    "DK")
        URL="europe/denmark-latest.osm.pbf"
        ;;
    "FI")
        URL="europe/finland-latest.osm.pbf"
        ;;
    "FR")
        URL="europe/france-latest.osm.pbf"
        ;;
    "GE")
        URL="europe/georgia-latest.osm.pbf"
        ;;
    "DE")
        URL="europe/germany-latest.osm.pbf"
        ;;
    "GB")
        URL="europe/great-britain-latest.osm.pbf"
        ;;
    "GR")
        URL="europe/greece-latest.osm.pbf"
        ;;
    "HU")
        URL="europe/hungary-latest.osm.pbf"
        ;;
    "IT")
        URL="europe/italy-latest.osm.pbf"
        ;;
    "LV")
        URL="europe/latvia-latest.osm.pbf"
        ;;
    "LT")
        URL="europe/lithuania-latest.osm.pbf"
        ;;
    "LU")
        URL="europe/luxembourg-latest.osm.pbf"
        ;;
    "MD")
        URL="europe/moldova-latest.osm.pbf"
        ;;
    "MC")
        URL="europe/monaco-latest.osm.pbf"
        ;;
    "ME")
        URL="europe/montenegro-latest.osm.pbf"
        ;;
    "NL")
        URL="europe/netherlands-latest.osm.pbf"
        ;;
    "NO")
        URL="europe/norway-latest.osm.pbf"
        ;;
    "PL")
        URL="europe/poland-latest.osm.pbf"
        ;;
    "PT")
        URL="europe/portugal-latest.osm.pbf"
        ;;
    "RO")
        URL="europe/romania-latest.osm.pbf"
        ;;
    "RU")
        URL="russia-latest.osm.pbf"
        ;;
    "RS")
        URL="europe/serbia-latest.osm.pbf"
        ;;
    "SK")
        URL="europe/slovakia-latest.osm.pbf"
        ;;
    "SI")
        URL="europe/slovenia-latest.osm.pbf"
        ;;
    "ES")
        URL="europe/spain-latest.osm.pbf"
        ;;
    "SE")
        URL="europe/sweden-latest.osm.pbf"
        ;;
    "CH")
        URL="europe/switzerland-latest.osm.pbf"
        ;;
    "TR")
        URL="europe/turkey-latest.osm.pbf"
        ;;
    "UA")
        URL="europe/ukraine-latest.osm.pbf"
        ;;
esac
docker build -t postgres-extractor .
docker stop postgres-extractor
docker rm postgres-extractor
docker run --name postgres-extractor -e POSTGRES_PASSWORD=secret -v $(pwd)/results:/results -d postgres-extractor

docker exec postgres-extractor bash -c "/extract.sh ${URL} ${CHOICE}"
