#!/bin/bash
# menu.sh - Interactive menu for SCDF stream automation

show_menu() {
  echo
  echo "SCDF Stream Creation Test Menu"
  echo "-----------------------------------"
  echo "s1) Create and deploy default HDFS stream"
  echo "s2) Create and deploy default S3 stream"
  echo "s3) Run test_hdfs_app (includes CF auth)" # Updated description
  echo "s4) Create and deploy test HDFS and textProc"
  echo "1) Destroy stream"
  echo "2) Unregister processor apps"
  echo "3) Register processor apps"
  echo "4) Register default apps"
  echo "5) Create stream definition"
  echo "6) Deploy stream"
  echo "7) View stream"
  echo "8) View processor apps"
  echo "9) View default apps"
  echo "q) Exit"
  echo -n "Select a step to run [1-9, s1, s2, q to quit]: "
}
