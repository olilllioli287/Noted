#!/bin/bash
# 測試用：送指令給執行中的 Noted，例如 ./debug.sh expand 1
# 指令通道只在測試版（bundle id 以 .suite-dev 結尾）存在：NOTED_BUNDLE_ID=com.local.noted.suite-dev ./debug.sh …
NAME="${NOTED_BUNDLE_ID:-com.local.noted}.debug"
swift -e 'import Foundation; let a = Array(CommandLine.arguments.dropFirst()); DistributedNotificationCenter.default().postNotificationName(.init(a[0]), object: a.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)' "$NAME" "$@"
