#!/bin/sh
/usr/bin/uname "$@" | sed s/aarch64/x86_64/g
