import AppKit

switch CommandLine.arguments.dropFirst().first {
case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
case "hook":
    HookCommand.run()
case "install":
    Installer.install()
case "uninstall":
    Installer.uninstall()
case "selfcheck":
    SelfCheck.run()
default:
    FileHandle.standardError.write(Data("usage: claude-island [hook|install|uninstall|selfcheck]\n".utf8))
    exit(2)
}
