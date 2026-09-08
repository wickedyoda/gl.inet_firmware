#! /bin/sh

device=$1

s=`/usr/sbin/blkid /dev/$device|sed -n 's/.* TYPE="\([^"]*\)".*/\1/p'|sed 's/[^[:print:]]/\*/g'`
main=`/usr/sbin/blkid -d /dev/$device|sed -n 's/.* LABEL="\([^"]*\)".*/\1/p'`
sub=`/usr/sbin/blkid -d /dev/$device|sed -n 's/.* PARTLABEL="\([^"]*\)".*/\1/p'|sed 's/[^[:print:]]/\*/g'`

#echo "label=$label"
echo "$main"
echo "$sub"





