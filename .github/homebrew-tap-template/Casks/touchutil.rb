cask "touchutil" do
  version "1.2.2"
  sha256 "b341098b24fc6d394a830d1568d5024af5eb731e065173d436bfff6a6ee74d12"

  url "https://github.com/keys2505/touchutil/releases/download/v#{version}/touchutil-#{version}.zip"
  name "touchutil"
  desc "Map an external USB touchscreen to its display on macOS"
  homepage "https://github.com/keys2505/touchutil"

  # No app/binary directives — Homebrew tracks app location when these are used
  # and fails during upgrade if the app was previously moved or deleted.
  # We handle installation entirely in preflight/postflight/uninstall instead.

  preflight do
    # Stop and clean up any existing installation before installing.
    system_command "/bin/launchctl",
      args: ["bootout", "gui/#{Process.uid}/com.touchutil.agent"],
      sudo: false
    system_command "/bin/rm", args: ["-rf", "/Applications/touchutil.app"], sudo: true
    system_command "/bin/rm", args: ["-f",  "/usr/local/bin/touchutil"],    sudo: true
    system_command "/bin/rm", args: ["-f",  "/opt/homebrew/bin/touchutil"], sudo: true
    plist = "#{Dir.home}/Library/LaunchAgents/com.touchutil.agent.plist"
    File.delete(plist) if File.exist?(plist)
  end

  postflight do
    # Copy app bundle to /Applications.
    system_command "/bin/cp",
      args: ["-R", "#{staged_path}/touchutil.app", "/Applications/touchutil.app"],
      sudo: true

    exec_path = "/Applications/touchutil.app/Contents/MacOS/touchutil"

    # Create CLI symlink in Homebrew's bin directory.
    brew_bin = File.exist?("/opt/homebrew/bin") ? "/opt/homebrew/bin" : "/usr/local/bin"
    system_command "/bin/mkdir", args: ["-p", brew_bin], sudo: true
    system_command "/bin/ln",    args: ["-sf", exec_path, "#{brew_bin}/touchutil"], sudo: true

    # Write LaunchAgent plist.
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
      args: ["bootstrap", "gui/#{Process.uid}", plist_path],
      sudo: false
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
