#!/bin/bash
ls -t ../ | grep -v site_generator | xargs -I {} rm -rf "../{}"
lein run
cp -r public/* ../

cd static-clojure-mode/
npx shadow-cljs release demo
cp public/js/clojure-mode.js ../../js/
