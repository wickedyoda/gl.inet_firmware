#!/bin/bash

# Script Name: gl_inoutdoor_switch.sh
# Function: Perform corresponding action based on parameter indoor or outdoor for GL-E5800 only

# Check if parameters are provided
if [ $# -eq 0 ]; then
    echo "Error: Invalid parameter, please use indoor or outdoor"
    echo "Usage: $0 <indoor|outdoor>"
    exit 1
fi

# Check if the model is GL-E5800
model=$(cat /proc/gl-hw-info/model)
if [ "$model" != "e5800" ]; then
    echo "Info: This script is for GL-E5800 only, current model: $model"
    exit 0
fi

# Function to switch indoor/outdoor mode
swicth_inoutdoor_mode() {
    # TODO: load the outdoor/indoor BDF here

    # Reload wifi to apply the changes'bdf
    /sbin/wifi reload
}

# Get the first parameter
action=$1
# Perform corresponding actions according to the parameters
case $action in
    indoor)
        logger -t "inoutdoor_switch" "current mode is switched to indoor"
        swicth_inoutdoor_mode
        ;;
    outdoor)
        logger -t "inoutdoor_switch" "current mode is switched to 'indoor'"
        swicth_inoutdoor_mode
        ;;
    *)
        echo "Error: Invalid parameter '$action', please use indoor or outdoor"
        echo "Usage: $0 <indoor|outdoor>"
        exit 1
        ;;
esac

exit 0

