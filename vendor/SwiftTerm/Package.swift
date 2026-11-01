// swift-tools-version:5.9
// SwiftTerm v1.20.0（github.com/migueldeicaza/SwiftTerm，MIT）：会话里的终端用的终端模拟器。
// 只拷了 Sources/SwiftTerm，去掉了上游的构建插件（构建信息固定写在 SwiftTermBuildInfo.swift）、GPU 渲染的着色器、测试和基准。
// iPhone App 经 Xcode 的本地包用它；Mac App 不走这个包，build.sh 直接用 swiftc 编同一份源码
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm")]
)
