import Foundation
import RocketChatSDK

let arguments = CommandLine.arguments.dropFirst()

guard let command = arguments.first else {
    print("""
    rc-cli — Rocket.Chat SDK smoke tool

    Usage: rc-cli <command>

    Commands: (implemented as SDK phases land)
      login     Authenticate against a server (supports 2FA)
      me        Show the authenticated user
      rooms     List joined rooms with unread state
      history   Show recent messages in a room
      send      Send a message to a room
      tail      Follow a room's messages live (polling)
      search    Search messages in a room
      spotlight Global search for users and channels
    """)
    exit(0)
}

print("rc-cli: command '\(command)' is not implemented yet")
exit(1)
