-- YouTube Downloader: the app teammates open. The installer compiles this with osacompile.
-- Keep this file plain ASCII so osacompile reads it the same on every Mac.

property appTitle : "YouTube Downloader"

on run
	set helper to quoted form of ((POSIX path of (path to home folder)) & "Library/Application Support/TeamYTDownloader/ytdl.sh")
	set choices to {"Best quality (original file, up to 4K/8K)", "Premiere-ready MP4, fast (up to 1080p)", "Premiere-ready MP4, full quality (up to 4K, slower)", "Audio only (MP3)"}
	set modes to {"best", "premiere", "premiere4k", "audio"}

	repeat
		-- 1. Ask for the link, pre-filled from the clipboard when it holds one.
		set defaultURL to ""
		try
			set clip to (the clipboard as text)
			if clip starts with "http" and (length of clip) < 500 then set defaultURL to clip
		end try
		try
			set dlg to display dialog "Paste a YouTube link:" & return & return & "Only download videos your team has the rights to use." default answer defaultURL with title appTitle buttons {"Cancel", "Next"} default button "Next" cancel button "Cancel" with icon note
		on error number -128
			return
		end try
		set theURL to do shell script "printf %s " & quoted form of (text returned of dlg) & " | tr -d '[:space:]'"
		if theURL does not start with "http" then
			display dialog "That doesn't look like a link. Copy the address from your browser and try again." with title appTitle buttons {"OK"} default button "OK" with icon caution
		else
			-- 2. Pick a format.
			set picked to choose from list choices with title appTitle with prompt "How do you want it saved? Files go to your Downloads folder." default items {item 2 of choices} OK button name "Download" cancel button name "Cancel"
			if picked is false then return
			set mode to "best"
			repeat with i from 1 to count of choices
				if (item i of choices) is (item 1 of picked) then set mode to item i of modes
			end repeat

			-- 3. Download, showing progress until the helper reports done or error.
			set started to do shell script helper & " start " & mode & " " & quoted form of theURL
			if started is "busy" then
				display dialog "Another download is still running. Wait for it to finish, then try again." with title appTitle buttons {"OK"} default button "OK" with icon caution
				return
			end if
			set progress total steps to -1
			set progress completed steps to 0
			set progress description to "Starting..."
			set progress additional description to theURL
			set state to "running"
			try
				repeat while state is "running"
					delay 0.5
					set AppleScript's text item delimiters to "|"
					set parts to text items of (do shell script helper & " status")
					set AppleScript's text item delimiters to ""
					set state to item 1 of parts
					set pct to (item 2 of parts) as integer
					if pct < 0 then
						set progress total steps to -1
					else
						set progress total steps to 100
						set progress completed steps to pct
					end if
					set progress description to item 3 of parts
				end repeat
			on error number -128
				do shell script helper & " cancel"
				return
			end try
			set progress total steps to 0
			set progress description to ""
			set progress additional description to ""

			-- 4. Report the result.
			if state is "done" then
				set savedPath to do shell script helper & " result"
				set savedName to do shell script "basename " & quoted form of savedPath
				set answer to button returned of (display dialog "Saved to your Downloads folder:" & return & return & savedName with title appTitle buttons {"Show in Finder", "Download Another", "Done"} default button "Download Another" with icon note)
				if answer is "Show in Finder" then
					do shell script "open -R " & quoted form of savedPath
					return
				else if answer is "Done" then
					return
				end if
			else
				set reason to do shell script helper & " error"
				set answer to button returned of (display dialog "The download didn't work:" & return & return & reason & return & return & "Check the link and try again in a minute. If it keeps failing, send the log to whoever set this up." with title appTitle buttons {"Open Log", "Try Again", "Close"} default button "Try Again" with icon stop)
				if answer is "Open Log" then
					do shell script "open -e \"$(" & helper & " log)\""
					return
				else if answer is "Close" then
					return
				end if
			end if
		end if
	end repeat
end run
