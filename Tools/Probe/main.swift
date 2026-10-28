import Foundation
import SignFlowCore

// The executable shares the exact core source with the app. Its entry is implemented
// inside the core so all model and service types can remain internal to that module.
await SignFlowProbe.run(arguments: Array(CommandLine.arguments.dropFirst()))
