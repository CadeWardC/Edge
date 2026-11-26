#!/usr/bin/env bash
# Give a release its own file addresses: ./tools/stamp.sh <folder> <version>
# Every script and stylesheet is then asked for as file.js?v=<version>, so a browser can never run this
# release's page with another release's scripts, whatever it has cached.
set -euo pipefail
dir=$1; v=$2
sed -i "s/const VERSION = '[^']*'/const VERSION = '$v'/" "$dir/sw.js"
sed -i -E "s#(from '\./[a-z]+\.js)'#\1?v=$v'#" "$dir"/js/*.js
sed -i -E "s#(href=\"css/style\.css|src=\"lib/peerjs\.min\.js|src=\"js/main\.js)\"#\1?v=$v\"#" "$dir/index.html"
grep -q "const VERSION = '$v'" "$dir/sw.js"
grep -q "js/main.js?v=$v" "$dir/index.html"
grep -q "from './data.js?v=$v'" "$dir/js/main.js"
echo "stamped $dir as $v"
