#!/bin/bash

hostname=$(cat /etc/hostname)
hostname=${hostname##*-}
echo "n${hostname}"
