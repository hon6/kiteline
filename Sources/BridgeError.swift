import Foundation

/// 带描述的失败原因：SSH 调用、watcher 请求等都用它包成标准 Result
struct RemoteError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

