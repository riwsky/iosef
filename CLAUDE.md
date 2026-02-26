# iosef

A Swift CLI for the iOS simulator (with MCP server support) that's optimized for agent usage.

# Work guidelines

*Use local checkout for researching other repositories:* You will, reasonably, often want to compare approaches against joshuayoes/ios-simulator-mcp or facebook/idb. Do NOT compare by browsing raw.githubcontent or the github web interface - instead, clone the repos locally. Another useful source of comparison is ldomaradzki/xctree.

*Test against the playground apps:* the repo also includes two playground apps (one iOS, one watchOS); changes should generally be validated against one or both of those.

*Keep references updated:* the following locations are pretty cross-cutting, and should be reviewed (especially after changes to the interface) in case they need updating:
[ ] The guidance in skills/ios-simulator-interaction
[ ] The benchmarking in scripts/benchmark.py
[ ] The documentation in the README.md
[ ] MCPTestApp Xcode project: When adding new `.swift` files to MCPTestApp, you must add them to `MCPTestApp.xcodeproj/project.pbxproj` in 4 sections: PBXBuildFile, PBXFileReference, PBXGroup children, and PBXSourcesBuildPhase files. Follow the existing `AA`/`BB` ID convention with the next available number.

*Scripts for frequent commands:* ls the `scripts` directory to see commands for building and benchmarking. Consider adding more if you find yourself running any commands pretty often.
