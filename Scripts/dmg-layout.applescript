-- Lays the disk image window out the way a Mac user expects: the app on the
-- left, the /Applications alias on the right, big icons, no toolbar. Finder
-- writes this into the image's .DS_Store, which is the only place that layout
-- can live -- there is no hdiutil flag for it.
--
-- Driving Finder needs Automation permission, so build-installer.sh treats a
-- failure here as cosmetic and ships the image anyway.
on run argv
	set volumeName to item 1 of argv
	tell application "Finder"
		tell disk volumeName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {300, 150, 900, 570}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set position of item "trolley.app" of container window to {150, 200}
			set position of item "Applications" of container window to {450, 200}
			update without registering applications
			delay 1
			close
		end tell
	end tell
end run
