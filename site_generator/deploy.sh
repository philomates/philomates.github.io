#!/bin/bash
ls -t ../ | grep -v site_generator | xargs -I {} rm -rf "../{}"
lein run
cp -r public/* ../
