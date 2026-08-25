-- trolley installer.
--
-- Exists because a .pkg cannot be signed without a Developer ID *Installer*
-- certificate, and macOS refuses to open an unsigned one. An app bundle signs
-- with the Application certificate we do have, so this is the shape that
-- notarizes -- the same shape MAKi's desktop release ships.
--
-- Installs to a fixed path on purpose: Accessibility and Screen Recording
-- grants are keyed to the executable path.

on run
	set userName to short user name of (system info)
	set src to quoted form of (POSIX path of (path to resource "trolley"))

	set sh to "set -e; "
	set sh to sh & "mkdir -p /usr/local/trolley/bin /etc/paths.d; "
	-- Delete before copy: overwriting in place leaves the kernel holding a code
	-- signature that no longer matches the bytes, and the binary dies with
	-- Killed: 9 on its next run.
	set sh to sh & "rm -f /usr/local/trolley/bin/trolley; "
	set sh to sh & "cp " & src & " /usr/local/trolley/bin/trolley; "
	set sh to sh & "chmod 755 /usr/local/trolley/bin/trolley; "
	set sh to sh & "echo /usr/local/trolley/bin > /etc/paths.d/trolley; "
	-- Hands the directory to the installing user so `trolley update` can swap the
	-- binary later without an admin prompt.
	set sh to sh & "chown -R " & userName & " /usr/local/trolley"

	try
		do shell script sh with administrator privileges
	on error errMsg number errNum
		if errNum is -128 then return
		display alert "trolley 설치 실패" message errMsg as critical
		return
	end try

	display alert "trolley 설치 완료" message "새 터미널을 열고 두 단계를 마치세요.

1) trolley check-permissions --prompt
   출력된 경로를 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에 추가합니다.

2) claude mcp add trolley -- /usr/local/trolley/bin/trolley mcp

앞으로 업데이트는 trolley update 한 줄이면 됩니다."
end run
