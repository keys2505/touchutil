cask "touchutil" do
  version "1.2.5"
  sha256 "6d59ebcf892918a9cc183eb44d0911ae569539a83bdce4c4bda6aa13d5e90ef3"

  url "https://github.com/keys2505/touchutil/releases/download/v#{version}/touchutil-#{version}.zip"
  name "touchutil"
  desc "Map an external USB touchscreen to its display on macOS"
  homepage "https://github.com/keys2505/touchutil"

  # No app/binary directives — avoids Homebrew's app-location tracking which
  # causes upgrade failures when the app has been moved or deleted.

  preflight do
    # Gracefully stop any existing instance — must_succeed: false so we never
    # fail if the agent isn't loaded or the app doesn't exist yet.
    system_command "/bin/launchctl",
      args:         ["bootout", "gui/#{Process.uid}/com.touchutil.agent"],
      sudo:         false,
      must_succeed: false
    system_command "/usr/bin/pkill",
      args:         ["-x", "touchutil"],
      must_succeed: false
    # Reset permissions so the new binary can request them fresh on first launch.
    system_command "/usr/bin/tccutil",
      args:         ["reset", "Accessibility", "com.eriproject.touchutil"],
      must_succeed: false
    system_command "/usr/bin/tccutil",
      args:         ["reset", "ListenEvent", "com.eriproject.touchutil"],
      must_succeed: false
    system_command "/bin/rm",
      args:         ["-rf", "/Applications/touchutil.app"],
      sudo:         true,
      must_succeed: false
    system_command "/bin/rm",
      args:         ["-f", "/usr/local/bin/touchutil"],
      sudo:         true,
      must_succeed: false
    system_command "/bin/rm",
      args:         ["-f", "/opt/homebrew/bin/touchutil"],
      sudo:         true,
      must_succeed: false
    plist = "#{Dir.home}/Library/LaunchAgents/com.touchutil.agent.plist"
    File.delete(plist) if File.exist?(plist)
  end

  postflight do
    # Install app bundle.
    system_command "/bin/cp",
      args: ["-R", "#{staged_path}/touchutil.app", "/Applications/touchutil.app"],
      sudo: true

    exec_path = "/Applications/touchutil.app/Contents/MacOS/touchutil"

    # CLI symlink — detect Homebrew prefix.
    brew_bin = File.exist?("/opt/homebrew/bin") ? "/opt/homebrew/bin" : "/usr/local/bin"
    system_command "/bin/mkdir", args: ["-p", brew_bin], sudo: true
    system_command "/bin/ln",    args: ["-sf", exec_path, "#{brew_bin}/touchutil"], sudo: true

    # Write and load LaunchAgent.
    plist_path = "#{Dir.home}/Library/LaunchAgents/com.touchutil.agent.plist"
    plist_content = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>com.touchutil.agent</string>
          <key>ProgramArguments</key>
          <array>
              <string>#{exec_path}</string>
              <string>--agent</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/tmp/touchutil.out.log</string>
          <key>StandardErrorPath</key>
          <string>/tmp/touchutil.err.log</string>
      </dict>
      </plist>
    XML

    FileUtils.mkdir_p "#{Dir.home}/Library/LaunchAgents"
    File.write(plist_path, plist_content)

    system_command "/bin/launchctl",
      args:         ["bootstrap", "gui/#{Process.uid}", plist_path],
      sudo:         false,
      must_succeed: false
  end

  caveats <<~EOS
    touchutil is now running in the background.

    Before your touchscreen works, grant two permissions in:
      System Settings → Privacy & Security

      • Input Monitoring → enable touchutil
      • Accessibility    → enable touchutil

    The app retries automatically once permissions are granted.

    If your touch lands on the wrong display, run:
      touchutil --setup

    Logs: /tmp/touchutil.err.log
  EOS

  uninstall launchctl: "com.touchutil.agent",
            delete:    [
              "/Applications/touchutil.app",
              "/usr/local/bin/touchutil",
              "/opt/homebrew/bin/touchutil",
              "#{Dir.home}/Library/LaunchAgents/com.touchutil.agent.plist",
            ]

  zap trash: "#{Dir.home}/.config/touchutil"
end
