#!/bin/bash
# Adds a release to appcast.xml, newest first.
#   Scripts/update-appcast.sh VERSION BUILD_NUMBER ARCHIVE_URL ED_SIGNATURE LENGTH RELEASE_URL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="$ROOT/appcast.xml"
VERSION="$1"
BUILD_NUMBER="$2"
ARCHIVE_URL="$3"
ED_SIGNATURE="$4"
LENGTH="$5"
RELEASE_URL="$6"
PUBLISHED="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

if grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
  echo "appcast.xml already lists build $BUILD_NUMBER" >&2
  exit 1
fi

ITEM="$(mktemp)"
cat > "$ITEM" <<ITEM_XML
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$RELEASE_URL</sparkle:fullReleaseNotesLink>
      <pubDate>$PUBLISHED</pubDate>
      <enclosure url="$ARCHIVE_URL"
                 type="application/octet-stream"
                 sparkle:edSignature="$ED_SIGNATURE"
                 length="$LENGTH"/>
    </item>
ITEM_XML

awk -v item="$ITEM" '
  { print }
  /<language>en<\/language>/ && !done { while ((getline line < item) > 0) print line; done = 1 }
  END { if (!done) exit 1 }
' "$APPCAST" > "$APPCAST.new"
rm "$ITEM"
mv "$APPCAST.new" "$APPCAST"
xmllint --noout "$APPCAST"
