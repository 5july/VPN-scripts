#!/bin/sh
#
# Simple script to check if your connect to VPN server
#

curl https://api.5july.net/1.0/ipcheck |jq '.connected' |grep true

if [ $? -eq 0 ]; then
   echo "Du är ansluten"
   exit 0
fi

echo "du är inte ansluten"
