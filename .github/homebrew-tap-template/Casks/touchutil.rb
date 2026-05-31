cask "touchutil" do
  version "1.1.0"
  sha256 "7a611060296498e4262163e29408cc7981b476295218eacd5a7a2b2694671a15"

  url "https://github.com/keys2505/touchutil/releases/download/v#{version}/touchutil-#{version}.zip"
  name "touchutil"
  desc "Map an external USB touchscreen to its display on macOS"
  homepage "https://github.com/keys2505/touchutil"

  app "touchutil.app"
  binary "#{appdir}/touchutil.app/Contents/MacOS/touchutil"

  postflight do
    exec_path = "#{appdir}/touchutil.app/Contents/MacOS/touchutil"
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
            delete:    "#{Dir.home}/Library/LaunchAgents/com.touchutil.agent.plist"

  zap trash: "#{Dir.home}/.config/touchutil"
end
