#!/usr/bin/env bash
[ $# -ne 2 ]&&{ echo "Usage: $0 TOKEN REPO"; exit 1; }
curl -X POST \
  -H "Authorization: token $1" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/user/repos \
  -d "{\"name\":\"$2\",\"private\":true}"
