#!/bin/bash

count=1
for cpu in $(ls cpu-*)
do
    echo $cpu
    cat $cpu | tail -n +"$1" | head -n "$2" | grep "20120601 " | awk '{print $24 " " $25}' >> "net-$count.in"
    count=$((count+1))
done