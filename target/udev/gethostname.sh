#!/bin/bash

# this file is used by persistent-storage-*.rules to 
# get a simple short name for cluster disk sharing. It
# should be put in directory /etc.

hostname=$(cat /etc/hostname)
hostname=${hostname##*-}
echo "n${hostname}"
