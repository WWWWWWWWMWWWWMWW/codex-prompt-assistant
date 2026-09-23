#!/bin/zsh
cd -- "${0:A:h}"
/usr/bin/python3 Tools/CodexFocusedThreadProbe/diagnose.py
printf '\n按回车关闭此窗口。'
read -r
