#!/bin/bash
# menu.sh - Interactive menu for SCDF stream automation

show_menu() {
  echo
  echo "SCDF Stream Creation Test Menu"
  echo "-----------------------------------"
  echo "1) Destroy stream"
  echo "2) Unregister processor apps"
  echo "3) Register processor apps"
  echo "4) Register default apps"
  echo "5) Create stream definition"
  echo "6) Deploy stream"
  echo "7) View stream status"
  echo "8) View registered processor apps"
  echo "9) View default apps"
  echo "t1) Test S3 source (s3 | log)"
  echo "t2) Test textProc pipeline (s3 | textProc | embedProc | postgres)"
  echo "t3) Test new embedProc pipeline (s3 | textProc | embedProc | log)"
  echo "q) Exit"
  echo -n "Select a step to run [1-9, t1, t2, q to quit]: "
}
