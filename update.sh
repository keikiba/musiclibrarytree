#!/bin/sh

DIR=/data/music/Resources

cd $DIR
./script/mklibrarytree.pl

# Build Freevo cache
#cp /dev/null ./log/cache-1000.log
#/usr/bin/freevo cache -- --verbose

# end
