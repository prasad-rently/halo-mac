#!/bin/bash
set -e
TOKEN=$(openssl rand -hex 3)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
FILE="Halo/App/BuildToken.swift"
sed -i '' "s/static let token  = \"[^\"]*\"/static let token  = \"$TOKEN\"/" "$FILE"
sed -i '' "s/static let commit = \"[^\"]*\"/static let commit = \"$COMMIT\"/" "$FILE"
echo "────────────────────────────────────────"
echo "  BUILD TOKEN : $TOKEN"
echo "  COMMIT      : $COMMIT"
echo "────────────────────────────────────────"
