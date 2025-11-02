awk '/^[[:space:]]*"version"[[:space:]]*:/ {print; i=substr($0,1,match($0,/[^ ]/)-1); print i "\"type\": \"module\","; next}1' package.json > tmp && mv tmp package.json
