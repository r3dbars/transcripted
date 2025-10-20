#!/bin/bash

# Add Debug folder group and files to Xcode project
# This is a simplified approach - normally would parse pbxproj properly

echo "Files need to be added manually to Xcode:"
echo ""
echo "1. Open Murmur.xcodeproj in Xcode"
echo "2. Right-click on 'Murmur' folder in Project Navigator"
echo "3. Select 'New Group' and name it 'Debug'"
echo "4. Right-click on 'Debug' folder"
echo "5. Select 'Add Files to Murmur...'"
echo "6. Select these files:"
echo "   - Murmur/Debug/AudioDebugMonitor.swift"
echo "   - Murmur/Debug/DebugWindow.swift"
echo "7. Make sure 'Copy items if needed' is UNCHECKED"
echo "8. Click 'Add'"
echo ""
echo "Files created at:"
ls -la Murmur/Debug/

