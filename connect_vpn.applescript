tell application "System Events"
	tell process "SystemUIServer"
		-- Click the VPN menu icon (menu bar item 2)
		click menu bar item 2 of menu bar 1
		delay 1 -- Wait for menu to appear
		
		-- Click the first menu item (should be "Connect AzureVPN")
		tell menu 1 of menu bar item 2 of menu bar 1
			click menu item 1
		end tell
	end tell
end tell
